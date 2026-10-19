import { SharedPlanContent, SharedPlanRecord, SharedPlanState, sharedPlanAad,
  validSharedPlanRecord } from '../model/SharedPlanFlow';
import { SharedPlanContext, SharedPlanDraftCommand, SharedPlanGatewayPort, SharedPlanReply, SharedPlanPage, SharedPlanArchiveCandidate,
  SharedPlanSessionIdentity as PlanTransportSession } from './SharedPlanUseCase';
import { SharedPlanDiagnostic, sharedPlanDiagnostic } from '../model/SharedPlanDiagnostic';
export { SharedPlanSessionIdentity as PlanTransportSession } from './SharedPlanUseCase';

export interface PlanIdentity { uid: string; accessToken: string; }
export interface PlanIdentityPort {
  credential(allowCreate: boolean): Promise<PlanIdentity>;
  currentUid?(): Promise<string>;
}
export interface PlanCloudPort { invoke(method: string, token: string, params: Object[]): Promise<string>; }
export interface PlanCipherPort {
  verifyPartner?(publicKey: string, envelope: string): Promise<boolean>;
  available(pairId: string): Promise<boolean>;
  seal(pairId: string, aad: string, plain: string, revision: number): Promise<string>;
  open(pairId: string, aad: string, envelope: string, revision: number): Promise<string | null>;
}
export interface PlanTransportStore {
  session(): Promise<PlanTransportSession | null>;
  current(session: PlanTransportSession): Promise<boolean>;
  cached(context: SharedPlanContext, planId: string): Promise<SharedPlanRecord | null>;
  wire(session: PlanTransportSession, requestId: string, draft: string): Promise<string>;
  saveWire(session: PlanTransportSession, requestId: string, draft: string, wire: string): Promise<string>;
}
export interface PlanBindingReply {
  code: string; pairId: string; status: string; myUid: string; peerUid: string;
  peerPublicKey: string; protocolVersion: number; projectionVersion: number; sharedPlanReady: boolean;
  peerLink?: string;
  syncVersion?: number;
}
export interface PlanWireRecord {
  pairId: string; planId: string; proposerUid: string; recipientUid: string; state: string;
  stateVersion: number; contentRevision: number; acceptedRevision: number; protocolVersion: number;
  pendingAuthorUid: string; pendingEnvelope: string; acceptedEnvelope: string;
}
interface PlanWireReply { code: string; plan?: PlanWireRecord; plans?: PlanWireRecord[]; diagnosticId?: string; }
interface PlanChangeReply extends PlanBindingReply { cursor: number; more: boolean; plans: PlanWireRecord[]; }
function failedPage(code: string = 'READ_FAILED'): SharedPlanPage {
  return { code: code, records: [], context: null, cursor: 0, more: false, incremental: false };
}
interface PlanWireCommand {
  pairId: string; planId: string; requestId: string; action: string; expectedVersion: number; envelope: string;
}
function id(value: string): boolean { return typeof value === 'string' && /^[A-Za-z0-9_-]{1,128}$/.test(value); }
function member(value: string): boolean { return typeof value === 'string' && /^m-[a-f0-9]{64}$/.test(value); }
function same(a: PlanTransportSession, b: PlanTransportSession | null): boolean {
  return b !== null && a.pairId === b.pairId && a.actorId === b.actorId && a.generation === b.generation;
}
function draftOf(command: SharedPlanDraftCommand): string {
  return JSON.stringify(command);
}
export function validPlanBinding(reply: PlanBindingReply, session: PlanTransportSession): boolean {
  return reply !== null && reply !== undefined && reply.code === 'OK' && reply.status === 'ACTIVE'
    && reply.pairId === session.pairId && reply.myUid === session.actorId && member(reply.myUid)
    && member(reply.peerUid) && reply.myUid !== reply.peerUid && typeof reply.peerPublicKey === 'string'
    && reply.peerPublicKey.length > 0 && reply.protocolVersion === 1 && reply.projectionVersion === 1
    && reply.sharedPlanReady === true;
}

/** Authenticated, encrypted channel. No legacy UID fallback and no optimistic state. */
export class SecureSharedPlanGateway implements SharedPlanGatewayPort {
  private lastDiagnostic: SharedPlanDiagnostic | null = null;
  diagnostic(): SharedPlanDiagnostic | null { return this.lastDiagnostic; }
  private verdict(stage: string, code: string, error: Object | null = null, diagnosticId: string = ''): void {
    this.lastDiagnostic = code === 'OK' ? null : sharedPlanDiagnostic(stage, code, error, diagnosticId);
  }
  private identity: PlanIdentityPort;
  private cloud: PlanCloudPort;
  private cipher: PlanCipherPort;
  private store: PlanTransportStore;
  private enabled: () => boolean;
  private verified: SharedPlanContext | null = null;
  private verifiedUid: string = '';
  /** Exact context object, consumed once; never a cross-operation/TTL binding cache. */
  private preparedContext: SharedPlanContext | null = null;
  /** Protocol support hint only, scoped to local generation; never used to authorize writes. */
  private incrementalSession: PlanTransportSession | null = null;
  constructor(identity: PlanIdentityPort, cloud: PlanCloudPort, cipher: PlanCipherPort,
    store: PlanTransportStore, enabled: () => boolean) {
    this.identity = identity; this.cloud = cloud; this.cipher = cipher; this.store = store; this.enabled = enabled;
  }

  async context(): Promise<SharedPlanContext | null> {
    this.lastDiagnostic = null;
    let stage = 'context.session';
    this.verified = null; this.verifiedUid = '';
    this.preparedContext = null;
    if (!this.enabled()) return null;
    try {
      const session = await this.store.session();
      if (session === null || !id(session.pairId) || !member(session.actorId) || !id(session.generation)) {
        this.verdict(stage, 'SECURE_SESSION_REQUIRED'); return null;
      }
      stage = 'context.key';
      if (!await this.cipher.available(session.pairId)) {
        this.verdict(stage, 'SECURE_SESSION_REQUIRED'); return null;
      }
      stage = 'context.identity';
      const identity = await this.identity.credential(false);
      stage = 'context.capabilities';
      const reply = JSON.parse(await this.cloud.invoke('capabilities', identity.accessToken, [session.pairId])) as PlanBindingReply;
      if (!validPlanBinding(reply, session) || !await this.stillCurrent(session, identity.uid)) {
        this.verdict('context.binding', typeof reply?.code === 'string' && reply.code !== 'OK' ? reply.code : 'BAD_RECORD'); return null;
      }
      stage = 'context.proof';
      if (this.cipher.verifyPartner !== undefined
        && !await this.cipher.verifyPartner(reply.peerPublicKey, reply.peerLink ?? '')) {
        this.verdict(stage, 'BAD_RECORD'); return null;
      }
      const ctx: SharedPlanContext = { pairId: session.pairId, actorId: reply.myUid, peerId: reply.peerUid, generation: session.generation,
        protocolVersion: reply.protocolVersion, projectionVersion: reply.projectionVersion };
      if (!await this.stillCurrent(ctx, identity.uid)) return null;
      this.verified = { pairId: ctx.pairId, actorId: ctx.actorId, peerId: ctx.peerId, generation: ctx.generation,
        protocolVersion: ctx.protocolVersion, projectionVersion: ctx.projectionVersion };
      this.verifiedUid = identity.uid;
      this.preparedContext = ctx;
      this.incrementalSession = reply.syncVersion === 2 ? session : null;
      return ctx;
    } catch (error) { this.verdict(stage, 'RESULT_UNKNOWN', error as Object); return null; }
  }

  async current(ctx: SharedPlanContext): Promise<boolean> {
    const verified = this.verified;
    return verified !== null && same(ctx, verified) && ctx.peerId === verified.peerId
      && ctx.protocolVersion === 1 && ctx.projectionVersion === 1
      && await this.stillCurrent(ctx, this.verifiedUid);
  }

  async registerPush(enabled: boolean, token: string): Promise<string> {
    if (token.length > 4096 || (enabled && token.trim() === '')) return 'BAD_REQUEST';
    try {
      const ctx = await this.context(); if (ctx === null) return 'SECURE_SESSION_REQUIRED';
      const identity = await this.identityFor(ctx); if (identity === null) return 'SECURE_SESSION_REQUIRED';
      const raw = await this.cloud.invoke('registerPush', identity.accessToken, [ctx.pairId, token, enabled]);
      if (!await this.stillCurrent(ctx, identity.uid)) return 'SESSION_CHANGED';
      const reply = JSON.parse(raw) as PlanWireReply;
      return typeof reply.code === 'string' ? reply.code : 'RESULT_UNKNOWN';
    } catch { return 'RESULT_UNKNOWN'; }
  }

  private async identityFor(ctx: SharedPlanContext): Promise<PlanIdentity | null> {
    const prepared = this.preparedContext === ctx;
    this.preparedContext = null;
    if (!this.enabled() || !await this.store.current(ctx) || !await this.cipher.available(ctx.pairId)) return null;
    const identity = await this.identity.credential(false);
    if (prepared) {
      // The following RPC authenticates and checks ACTIVE membership on the server too.
      // Keep fresh credentials and the local UID/generation fence; reuse only this operation's proof.
      return identity.uid === this.verifiedUid && await this.current(ctx) ? identity : null;
    }
    const binding = JSON.parse(await this.cloud.invoke('capabilities', identity.accessToken, [ctx.pairId])) as PlanBindingReply;
    if (!validPlanBinding(binding, ctx) || binding.peerUid !== ctx.peerId
      || !await this.stillCurrent(ctx, identity.uid)) return null;
    if (this.cipher.verifyPartner !== undefined
      && !await this.cipher.verifyPartner(binding.peerPublicKey, binding.peerLink ?? '')) return null;
    return identity;
  }

  private async stillCurrent(ctx: PlanTransportSession, uid: string): Promise<boolean> {
    if (!this.enabled() || !same(ctx, await this.store.session()) || !await this.store.current(ctx)) return false;
    try {
      const currentUid = this.identity.currentUid !== undefined ? await this.identity.currentUid()
        : (await this.identity.credential(false)).uid;
      // SDK lookup may yield; recheck generation after it, not only before it.
      return uid !== '' && currentUid === uid && this.enabled()
        && same(ctx, await this.store.session()) && await this.store.current(ctx);
    } catch { return false; }
  }

  async read(ctx: SharedPlanContext): Promise<SharedPlanReply> {
    try {
      const identity = await this.identityFor(ctx);
      if (identity === null) return { code: 'SECURE_SESSION_REQUIRED', records: [] };
      const raw = await this.cloud.invoke('read', identity.accessToken, [ctx.pairId]);
      if (!await this.stillCurrent(ctx, identity.uid)) return { code: 'SESSION_CHANGED', records: [] };
      const decoded = await this.decodeReply(ctx, raw, true);
      return await this.stillCurrent(ctx, identity.uid) ? decoded : { code: 'SESSION_CHANGED', records: [] };
    } catch { return { code: 'READ_FAILED', records: [] }; }
  }

  async sync(cursorOf: (context: SharedPlanContext) => Promise<number>): Promise<SharedPlanPage> {
    const failed = failedPage();
    if (!this.enabled()) return failedPage('SECURE_SESSION_REQUIRED');
    try {
      const session = await this.store.session();
      if (session === null) return failedPage('SECURE_SESSION_REQUIRED');
      let known: SharedPlanContext | null = null;
      if (!same(session, this.incrementalSession)) {
        known = await this.context();
        if (known === null) return failedPage('SECURE_SESSION_REQUIRED');
        if (!same(session, this.incrementalSession)) {
          const reply = await this.read(known);
          return { code: reply.code, records: reply.records, context: known, cursor: 0, more: false, incremental: false };
        }
      }
      if (!await this.cipher.available(session.pairId) || !await this.store.current(session)) return failed;
      const identity = await this.identity.credential(false);
      const local: SharedPlanContext = known ?? { pairId: session.pairId, actorId: session.actorId, peerId: '',
        generation: session.generation, protocolVersion: 1, projectionVersion: 1 };
      const cursor = await cursorOf(local);
      if (!Number.isSafeInteger(cursor) || cursor < 0 || !await this.stillCurrent(session, identity.uid)) return failed;
      const raw = await this.cloud.invoke('readChanges', identity.accessToken, [session.pairId, cursor]);
      const reply = JSON.parse(raw) as PlanChangeReply;
      if (reply?.code === 'FEATURE_DISABLED') {
        this.incrementalSession = null;
        const ctx = await this.context();
        if (ctx === null) return failedPage('SECURE_SESSION_REQUIRED');
        const legacy = await this.read(ctx);
        return { code: legacy.code, records: legacy.records, context: ctx, cursor: 0, more: false, incremental: false };
      }
      if (reply?.code !== 'OK') return failedPage(typeof reply?.code === 'string' ? reply.code : 'BAD_RECORD');
      if (!validPlanBinding(reply, session) || reply.syncVersion !== 2 || !Number.isSafeInteger(reply.cursor)
        || reply.cursor < cursor || typeof reply.more !== 'boolean' || (reply.more && reply.cursor === cursor)
        || !await this.stillCurrent(session, identity.uid)) return failedPage('BAD_RECORD');
      if (this.cipher.verifyPartner !== undefined
        && !await this.cipher.verifyPartner(reply.peerPublicKey, reply.peerLink ?? '')) return failedPage('BAD_RECORD');
      const ctx: SharedPlanContext = { pairId: session.pairId, actorId: reply.myUid, peerId: reply.peerUid,
        generation: session.generation, protocolVersion: 1, projectionVersion: 1 };
      const decoded = await this.decodeReply(ctx, raw, true);
      if (!await this.stillCurrent(ctx, identity.uid)) return failedPage('SESSION_CHANGED');
      this.verified = ctx; this.verifiedUid = identity.uid; this.preparedContext = null;
      return { code: decoded.code, records: decoded.records, context: ctx, cursor: reply.cursor, more: reply.more, incremental: true };
    } catch { return failed; }
  }

  async acknowledge(ctx: SharedPlanContext, cursor: number, candidates: SharedPlanArchiveCandidate[]): Promise<string> {
    if (!await this.current(ctx) || candidates.length > 10) return 'SESSION_CHANGED';
    const identity = await this.identity.credential(false);
    if (!await this.stillCurrent(ctx, identity.uid) || identity.uid !== this.verifiedUid) return 'SESSION_CHANGED';
    const raw = await this.cloud.invoke('acknowledge', identity.accessToken, [ctx.pairId, cursor, JSON.stringify(candidates)]);
    if (!await this.stillCurrent(ctx, identity.uid)) return 'SESSION_CHANGED';
    const reply = JSON.parse(raw) as PlanWireReply;
    return typeof reply?.code === 'string' ? reply.code : 'BAD_RECORD';
  }

  async send(ctx: SharedPlanContext, command: SharedPlanDraftCommand): Promise<SharedPlanReply> {
    let stage = 'send.identity';
    this.lastDiagnostic = null;
    try {
      const identity = await this.identityFor(ctx);
      if (identity === null) return { code: 'SECURE_SESSION_REQUIRED', records: [] };
      if (!id(command.requestId) || !id(command.planId) || !Number.isSafeInteger(command.expectedVersion)
        || command.expectedVersion < 0 || command.expectedVersion >= 2147483647
        || ['PROPOSE', 'ACCEPT', 'DECLINE', 'WITHDRAW', 'CANCEL', 'AMEND'].indexOf(command.action) < 0) {
        return { code: 'BAD_REQUEST', records: [] };
      }
      const draft = draftOf(command);
      stage = 'send.wire.read';
      let wire = await this.store.wire(ctx, command.requestId, draft);
      if (wire === '') {
        let envelope = '';
        if (command.action === 'PROPOSE' || command.action === 'AMEND') {
          const content = command.nextContent;
          if (content === null) return { code: 'BAD_CONTENT', records: [] };
          let revision = 1;
          if (command.action === 'PROPOSE' && command.expectedVersion !== 0) return { code: 'BAD_REQUEST', records: [] };
          if (command.action === 'AMEND') {
            const current = await this.store.cached(ctx, command.planId);
            if (current === null || current.stateVersion !== command.expectedVersion) return { code: 'VERSION_CONFLICT', records: [] };
            revision = current.contentRevision + 1;
          }
          stage = 'send.encrypt';
          envelope = await this.cipher.seal(ctx.pairId, sharedPlanAad(ctx.pairId, command.planId, revision),
            JSON.stringify(content), revision);
        } else if (command.nextContent !== null) return { code: 'BAD_REQUEST', records: [] };
        const body: PlanWireCommand = { pairId: ctx.pairId, planId: command.planId, requestId: command.requestId,
          action: command.action, expectedVersion: command.expectedVersion, envelope: envelope };
        stage = 'send.wire.save';
        wire = await this.store.saveWire(ctx, command.requestId, draft, JSON.stringify(body));
      }
      if (!await this.stillCurrent(ctx, identity.uid)) return { code: 'SESSION_CHANGED', records: [] };
      // The persisted winner is used, even if another writer encrypted with a different nonce.
      stage = 'send.wire.validate';
      const persisted = JSON.parse(wire) as PlanWireCommand;
      if (persisted === null || persisted.pairId !== ctx.pairId || persisted.planId !== command.planId
        || persisted.requestId !== command.requestId || persisted.action !== command.action
        || persisted.expectedVersion !== command.expectedVersion || typeof persisted.envelope !== 'string') {
        return { code: 'BAD_RECORD', records: [] };
      }
      stage = 'send.rpc';
      const raw = await this.cloud.invoke('mutate', identity.accessToken, [wire]);
      if (!await this.stillCurrent(ctx, identity.uid)) return { code: 'SESSION_CHANGED', records: [] };
      stage = 'send.decode';
      const decoded = await this.decodeReply(ctx, raw, false);
      this.verdict(stage, decoded.code, null, this.replyDiagnosticId(raw));
      return await this.stillCurrent(ctx, identity.uid) ? decoded : { code: 'SESSION_CHANGED', records: [] };
    } catch (error) { this.verdict(stage, 'RESULT_UNKNOWN', error as Object); return { code: 'RESULT_UNKNOWN', records: [] }; }
  }

  async resolve(ctx: SharedPlanContext, command: SharedPlanDraftCommand): Promise<SharedPlanReply> {
    return this.requestReceipt(ctx, command, false);
  }
  async close(ctx: SharedPlanContext, command: SharedPlanDraftCommand): Promise<SharedPlanReply> {
    return this.requestReceipt(ctx, command, true);
  }
  private async requestReceipt(ctx: SharedPlanContext, command: SharedPlanDraftCommand, close: boolean): Promise<SharedPlanReply> {
    let stage = 'resolve.identity';
    this.lastDiagnostic = null;
    try {
      const identity = await this.identityFor(ctx);
      if (identity === null) return { code: 'SECURE_SESSION_REQUIRED', records: [] };
      stage = 'resolve.wire';
      const wire = await this.store.wire(ctx, command.requestId, draftOf(command));
      // No persisted wire means this client never reached the send step.
      if (wire === '') return { code: close ? 'REQUEST_CLOSED' : 'REQUEST_NOT_COMMITTED', records: [] };
      const body = JSON.parse(wire) as PlanWireCommand;
      if (body === null || body.pairId !== ctx.pairId || body.planId !== command.planId
        || body.requestId !== command.requestId || body.action !== command.action
        || body.expectedVersion !== command.expectedVersion) return { code: 'BAD_RECORD', records: [] };
      stage = 'resolve.rpc';
      const raw = await this.cloud.invoke(close ? 'closeRequest' : 'requestStatus', identity.accessToken, [wire]);
      if (!await this.stillCurrent(ctx, identity.uid)) return { code: 'SESSION_CHANGED', records: [] };
      stage = 'resolve.decode';
      const decoded = await this.decodeReply(ctx, raw, false);
      this.verdict(stage, decoded.code, null, this.replyDiagnosticId(raw));
      return await this.stillCurrent(ctx, identity.uid) ? decoded : { code: 'SESSION_CHANGED', records: [] };
    } catch (error) { this.verdict(stage, 'RESULT_UNKNOWN', error as Object); return { code: 'RESULT_UNKNOWN', records: [] }; }
  }

  private replyDiagnosticId(raw: string): string {
    try {
      const value = (JSON.parse(raw) as PlanWireReply).diagnosticId;
      return typeof value === 'string' ? value : '';
    } catch { return ''; }
  }

  private async decodeReply(ctx: SharedPlanContext, raw: string, list: boolean): Promise<SharedPlanReply> {
    try {
      const reply = JSON.parse(raw) as PlanWireReply;
      if (reply === null || typeof reply.code !== 'string' || !/^[A-Z_]{2,64}$/.test(reply.code)) return { code: 'BAD_RECORD', records: [] };
      if (reply.code !== 'OK') return { code: reply.code, records: [] };
      if (list && !Array.isArray(reply.plans)) return { code: 'BAD_RECORD', records: [] };
      const wireRows: PlanWireRecord[] = list && reply.plans !== undefined ? reply.plans
        : reply.plan === undefined ? [] : [reply.plan];
      if (wireRows.length > 50 || (!list && wireRows.length !== 1)) return { code: 'BAD_RECORD', records: [] };
      const rows: SharedPlanRecord[] = [];
      const seen: string[] = [];
      for (const wire of wireRows) {
        if (wire === null || wire.protocolVersion !== 1 || wire.pairId !== ctx.pairId || !id(wire.planId)
          || !((wire.proposerUid === ctx.actorId && wire.recipientUid === ctx.peerId)
            || (wire.proposerUid === ctx.peerId && wire.recipientUid === ctx.actorId))
          || !Number.isSafeInteger(wire.contentRevision) || wire.contentRevision < 1 || wire.contentRevision >= 2147483647
          || !Number.isSafeInteger(wire.acceptedRevision) || wire.acceptedRevision < 0 || wire.acceptedRevision > wire.contentRevision
          || !Number.isSafeInteger(wire.stateVersion) || wire.stateVersion < 1 || wire.stateVersion >= 2147483647
          || typeof wire.pendingEnvelope !== 'string' || typeof wire.acceptedEnvelope !== 'string'
          || seen.indexOf(wire.planId) >= 0) return { code: 'BAD_RECORD', records: [] };
        seen.push(wire.planId);
        let accepted: SharedPlanContent | null = null; let pending: SharedPlanContent | null = null;
        if (wire.acceptedRevision > 0) {
          const text = await this.cipher.open(ctx.pairId, sharedPlanAad(ctx.pairId, wire.planId, wire.acceptedRevision),
            wire.acceptedEnvelope, wire.acceptedRevision);
          if (text === null) return { code: 'BAD_RECORD', records: [] };
          accepted = JSON.parse(text) as SharedPlanContent;
        } else if (wire.acceptedEnvelope !== '') return { code: 'BAD_RECORD', records: [] };
        if (wire.pendingEnvelope !== '') {
          const text = await this.cipher.open(ctx.pairId, sharedPlanAad(ctx.pairId, wire.planId, wire.contentRevision),
            wire.pendingEnvelope, wire.contentRevision);
          if (text === null) return { code: 'BAD_RECORD', records: [] };
          pending = JSON.parse(text) as SharedPlanContent;
        }
        const row: SharedPlanRecord = { pairId: wire.pairId, planId: wire.planId, proposerUid: wire.proposerUid,
          recipientUid: wire.recipientUid, state: wire.state as SharedPlanState, stateVersion: wire.stateVersion,
          contentRevision: wire.contentRevision, acceptedRevision: wire.acceptedRevision,
          acceptedContent: accepted, pendingContent: pending, pendingAuthorUid: wire.pendingAuthorUid };
        if (!validSharedPlanRecord(row)) return { code: 'BAD_RECORD', records: [] };
        rows.push(row);
      }
      return { code: 'OK', records: rows };
    } catch { return { code: 'BAD_RECORD', records: [] }; }
  }
}
