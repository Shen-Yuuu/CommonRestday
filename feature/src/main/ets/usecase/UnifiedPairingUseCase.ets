import { SecurePairingResult } from './SecurePairingUseCase';

export interface UnifiedPairingContext { pairId: string; uid: string; peerUid: string; epoch: string; }
export interface UnifiedPairingResult { code: string; phase: string; }
export interface UnifiedPairingOffer { pairId: string; publicKey: string; inviteCode: string; expiresAt: number; }
export interface UnifiedSetupState { result: SecurePairingResult; creator: boolean; anchor: string; }
export interface UnifiedDiscovery { code: string; offers: UnifiedPairingOffer[]; }
export interface UnifiedPairingPort {
  enabled(): boolean;
  context(): Promise<UnifiedPairingContext | null>;
  consented(pairId: string): boolean;
  paused(pairId: string): boolean;
  pause(pairId: string): Promise<void>;
  consent(pairId: string): Promise<void>;
  state(): Promise<UnifiedSetupState>;
  ready(): Promise<boolean>;
  create(): Promise<SecurePairingResult>;
  resume(): Promise<SecurePairingResult>;
  confirm(): Promise<SecurePairingResult>;
  join(offer: UnifiedPairingOffer): Promise<SecurePairingResult>;
  discover(ctx: UnifiedPairingContext): Promise<UnifiedDiscovery>;
  publish(ctx: UnifiedPairingContext): Promise<SecurePairingResult>;
}
function result(phase: string, code: string = 'OK'): UnifiedPairingResult { return { phase: phase, code: code }; }
function same(a: UnifiedPairingContext, b: UnifiedPairingContext | null): boolean {
  return b !== null && a.pairId === b.pairId && a.uid === b.uid && a.peerUid === b.peerUid && a.epoch === b.epoch;
}
/** Setup only: no plan mutation, notification permission or destructive connection replacement. */
export class UnifiedPairingUseCase {
  private pending: Promise<UnifiedPairingResult> | null = null;
  private port: UnifiedPairingPort;
  constructor(port: UnifiedPairingPort) { this.port = port; }
  async local(): Promise<UnifiedPairingResult> {
    try {
      const ctx = await this.port.context();
      if (ctx === null) return result('NOT_PAIRED');
      const ready = await this.port.ready();
      if (!same(ctx, await this.port.context())) return result('FAILED', 'SESSION_CHANGED');
      if (ready) return result('READY');
      if (ctx !== null && this.port.paused(ctx.pairId)) return result('FAILED', 'RETRY_REQUIRED');
      return ctx !== null && this.port.consented(ctx.pairId) ? result('CONNECTING') : result('UPGRADE');
    } catch { return result('FAILED', 'STATE_INVALID'); }
  }
  advance(consent: boolean = false): Promise<UnifiedPairingResult> {
    if (this.pending !== null) return this.pending;
    const work = this.perform(consent)
      .finally(() => { if (this.pending === work) this.pending = null; });
    this.pending = work; return work;
  }
  private async perform(consent: boolean): Promise<UnifiedPairingResult> {
    let ctx: UnifiedPairingContext | null = null;
    try {
      ctx = await this.port.context();
      const next = await this.run(consent);
      if (next.phase === 'FAILED' && !['SESSION_CHANGED', 'FEATURE_DISABLED', 'BUSY'].includes(next.code)
        && ctx !== null && this.port.consented(ctx.pairId)
        && same(ctx, await this.port.context())) await this.port.pause(ctx.pairId);
      return next;
    } catch {
      if (ctx !== null) {
        try { if (same(ctx, await this.port.context()) && this.port.consented(ctx.pairId)) await this.port.pause(ctx.pairId); }
        catch { /* Never replace the original failure with a storage error. */ }
      }
      return result('FAILED', 'RESULT_UNKNOWN');
    }
  }
  private async current(ctx: UnifiedPairingContext): Promise<boolean> {
    return this.port.enabled() && this.port.consented(ctx.pairId) && same(ctx, await this.port.context());
  }
  private async finish(ctx: UnifiedPairingContext, state: SecurePairingResult): Promise<UnifiedPairingResult> {
    if (!await this.current(ctx)) return result('FAILED', 'SESSION_CHANGED');
    if (state.code !== 'OK') return result('FAILED', state.code);
    if (await this.port.ready()) return await this.current(ctx) ? result('READY') : result('FAILED', 'SESSION_CHANGED');
    if (!await this.current(ctx)) return result('FAILED', 'SESSION_CHANGED');
    return result('WAITING');
  }
  private async run(consent: boolean): Promise<UnifiedPairingResult> {
    if (!this.port.enabled()) return result('FAILED', 'FEATURE_DISABLED');
    const ctx = await this.port.context();
    if (ctx === null) return result('NOT_PAIRED');
    if (await this.port.ready()) return same(ctx, await this.port.context()) ? result('READY') : result('FAILED', 'SESSION_CHANGED');
    if (this.port.paused(ctx.pairId) && !consent) return result('FAILED', 'RETRY_REQUIRED');
    if (consent) await this.port.consent(ctx.pairId);
    if (!this.port.consented(ctx.pairId)) return result('UPGRADE');
    if (!await this.current(ctx)) return result('FAILED', 'SESSION_CHANGED');
    const local = await this.port.state();
    if (!await this.current(ctx)) return result('FAILED', 'SESSION_CHANGED');
    if (local.result.code !== 'OK') return result('FAILED', local.result.code);
    const phase = local.result.phase;
    if (phase === 'REVOKED' && local.anchor === 'PAIRED|' + ctx.pairId) return result('FAILED', 'SESSION_REVOKED');
    if (phase !== 'EMPTY' && phase !== 'REVOKED') {
      let state = await this.port.resume();
      if (!await this.current(ctx)) return result('FAILED', 'SESSION_CHANGED');
      if (state.code !== 'OK') return result('FAILED', state.code);
      // resume validates the existing schedule-key proof before this creator-only confirmation.
      if (state.canConfirm) state = await this.port.confirm();
      if (!await this.current(ctx)) return result('FAILED', 'SESSION_CHANGED');
      if (state.code !== 'OK') return result('FAILED', state.code);
      if (local.creator && state.phase === 'WAITING') {
        const other = await this.port.discover(ctx);
        if (!await this.current(ctx)) return result('FAILED', 'SESSION_CHANGED');
        if (other.code !== 'OK') return result('FAILED', other.code);
        // Old partially configured creators must not silently replace one another or wait forever.
        if (other.offers.length > 0) return result('FAILED', 'CODE_COLLISION');
        state = await this.port.publish(ctx);
      }
      return this.finish(ctx, state);
    }
    const discovered = await this.port.discover(ctx);
    if (!await this.current(ctx)) return result('FAILED', 'SESSION_CHANGED');
    if (discovered.code !== 'OK') return result('FAILED', discovered.code);
    if (discovered.offers.length > 1) return result('FAILED', 'CODE_COLLISION');
    if (discovered.offers.length === 1) return this.finish(ctx, await this.port.join(discovered.offers[0]));
    // Deterministic election avoids two new creators. The locator itself grants no authority.
    if (ctx.uid > ctx.peerUid) return result('WAITING');
    const created = await this.port.create();
    if (!await this.current(ctx)) return result('FAILED', 'SESSION_CHANGED');
    if (created.code !== 'OK') return result('FAILED', created.code);
    return this.finish(ctx, await this.port.publish(ctx));
  }
}
