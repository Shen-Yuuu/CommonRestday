import { AnonymousIdentity, DatePlanCloudApi, PairKeyStore, PairingBridgeOffer, PlanPairingBridge, SecurePlanKeyStore } from 'cloud';
import { PAIRED, SettingsStore, SecurePairingRepo, SharedPlanRepo } from 'data';
import { FeatureFlags } from '../config/FeatureFlags';
import { SecureLifecycle } from './SecureLifecycle';
import { securePairingSetup } from './SecurePairingAdapters';
import { SecurePairingIntent, SecurePairingResult } from './SecurePairingUseCase';
import { UnifiedDiscovery, UnifiedPairingContext, UnifiedPairingOffer, UnifiedPairingPort,
  UnifiedPairingUseCase, UnifiedSetupState } from './UnifiedPairingUseCase';

interface OfferWire { pairId: string; publicKey: string; offer: string; }
interface DiscoveryReply { code: string; offers: OfferWire[]; }
class UnifiedAdapter implements UnifiedPairingPort {
  private current(ctx: UnifiedPairingContext): boolean {
    return this.enabled() && this.consented(ctx.pairId) && ctx.pairId === SettingsStore.getPairId()
      && ctx.peerUid === SettingsStore.getPartnerUid() && ctx.epoch === SecureLifecycle.anchor()
      && SettingsStore.getPairState() === PAIRED;
  }
  enabled(): boolean { return FeatureFlags.cloudPairing && FeatureFlags.securePairing && FeatureFlags.sharedPlan
    && !SecureLifecycle.blocked() && AppStorage.get<boolean>('crd_app_foreground') !== false; }
  async context(): Promise<UnifiedPairingContext | null> {
    if (SecureLifecycle.blocked() || SettingsStore.getPairState() !== PAIRED || SettingsStore.getPairId() === '') return null;
    const pair = SettingsStore.getPairId(), peer = SettingsStore.getPartnerUid(), epoch = SecureLifecycle.anchor();
    const uid = await SettingsStore.getOrCreateUid();
    if (peer === '' || uid === peer || SettingsStore.getPairState() !== PAIRED || pair !== SettingsStore.getPairId()
      || peer !== SettingsStore.getPartnerUid() || epoch !== SecureLifecycle.anchor()) return null;
    return { pairId: pair, uid: uid, peerUid: peer, epoch: epoch };
  }
  consented(pairId: string): boolean { return SettingsStore.getUnifiedPairConsent() === pairId; }
  paused(pairId: string): boolean { return SettingsStore.getUnifiedPairPaused() === pairId; }
  async pause(pairId: string): Promise<void> {
    if (SettingsStore.getPairId() === pairId) await SettingsStore.setUnifiedPairPaused(pairId);
  }
  async consent(pairId: string): Promise<void> {
    if (SettingsStore.getPairState() !== PAIRED || SettingsStore.getPairId() !== pairId || SecureLifecycle.blocked()) throw new Error('SESSION_CHANGED');
    await SettingsStore.setUnifiedPairConsent(pairId);
    if (SettingsStore.getPairId() === pairId) await SettingsStore.setUnifiedPairPaused('');
  }
  async state(): Promise<UnifiedSetupState> {
    const local = await securePairingSetup().local();
    const raw = await SecurePairingRepo.load();
    const state: SecurePairingIntent | null = raw === '' ? null : JSON.parse(raw) as SecurePairingIntent;
    return { result: local, creator: state !== null && state.role === 'CREATOR', anchor: state === null ? '' : state.anchor };
  }
  async ready(): Promise<boolean> {
    const raw = await SecurePairingRepo.load(); if (raw === '') return false;
    const intent = JSON.parse(raw) as SecurePairingIntent;
    const session = await SharedPlanRepo.session();
    return intent !== null && intent.phase === 'ACTIVE' && intent.anchor === PAIRED + '|' + SettingsStore.getPairId()
      && typeof intent.linkEnvelope === 'string' && intent.linkEnvelope.length > 0
      && session !== null && session.pairId === intent.pairId && session.actorId === intent.actorId
      && session.generation === intent.flowId && await SecurePlanKeyStore.available(intent.pairId);
  }
  create(): Promise<SecurePairingResult> { return securePairingSetup().create(); }
  resume(): Promise<SecurePairingResult> { return securePairingSetup().resume(); }
  confirm(): Promise<SecurePairingResult> { return securePairingSetup().confirm(); }
  join(offer: UnifiedPairingOffer): Promise<SecurePairingResult> {
    return securePairingSetup().joinLinked(offer.inviteCode, offer.pairId, offer.publicKey);
  }
  async discover(ctx: UnifiedPairingContext): Promise<UnifiedDiscovery> {
    if (!await PairKeyStore.hasPairKey(ctx.pairId)) return { code: 'KEY_UNAVAILABLE', offers: [] };
    const route = await PlanPairingBridge.route(ctx.pairId);
    if (!this.current(ctx)) return { code: 'SESSION_CHANGED', offers: [] };
    const auth = await AnonymousIdentity.credential(true);
    if (!this.current(ctx)) return { code: 'SESSION_CHANGED', offers: [] };
    const reply = JSON.parse(await DatePlanCloudApi.invoke('discoverLink', auth.accessToken, [route])) as DiscoveryReply;
    if (!this.current(ctx) || await AnonymousIdentity.currentUid() !== auth.uid) return { code: 'SESSION_CHANGED', offers: [] };
    if (reply === null || typeof reply.code !== 'string') return { code: 'INVALID_REPLY', offers: [] };
    if (reply.code !== 'OK') return { code: reply.code, offers: [] };
    if (!Array.isArray(reply.offers) || reply.offers.length > 5) return { code: 'INVALID_REPLY', offers: [] };
    const offers: UnifiedPairingOffer[] = [];
    for (const wire of reply.offers) {
      if (wire === null || typeof wire.offer !== 'string') return { code: 'INVALID_REPLY', offers: [] };
      const opened = await PlanPairingBridge.open(ctx.pairId, ctx.peerUid, ctx.uid, wire.offer);
      if (opened !== null && opened.pairId === wire.pairId && opened.publicKey === wire.publicKey) {
        offers.push({ pairId: opened.pairId, publicKey: opened.publicKey, inviteCode: opened.inviteCode, expiresAt: opened.expiresAt });
      }
    }
    return { code: 'OK', offers: offers };
  }
  async publish(ctx: UnifiedPairingContext): Promise<SecurePairingResult> {
    const route = await PlanPairingBridge.route(ctx.pairId);
    if (!this.current(ctx)) return { code: 'SESSION_CHANGED', phase: 'WAITING', inviteCode: '', canConfirm: false };
    return securePairingSetup().publishLink(route, (state: SecurePairingIntent): Promise<string> => {
      const offer: PairingBridgeOffer = { pairId: state.pairId, publicKey: state.publicKey,
        inviteCode: state.inviteCode, expiresAt: state.expiresAt };
      return PlanPairingBridge.seal(ctx.pairId, ctx.uid, ctx.peerUid, offer);
    });
  }
}
let instance: UnifiedPairingUseCase | null = null;
export function unifiedPairing(): UnifiedPairingUseCase {
  if (instance === null) instance = new UnifiedPairingUseCase(new UnifiedAdapter());
  return instance;
}
