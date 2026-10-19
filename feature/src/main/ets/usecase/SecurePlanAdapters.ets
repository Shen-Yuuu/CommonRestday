import { AnonymousIdentity, DatePlanCloudApi, SecurePlanKeyStore, PlanPartnerLink } from 'cloud';
import { SharedPlanRepo, SharedPlanSession, SecurePairingRepo, SettingsStore, PAIRED } from 'data';
import { SecurePairingIntent } from './SecurePairingUseCase';
import { SharedPlanRecord } from '../model/SharedPlanFlow';
import { FeatureFlags } from '../config/FeatureFlags';
import { SecureLifecycle } from './SecureLifecycle';
import { SharedPlanContext } from './SharedPlanUseCase';
import { SharedPlanPersistence } from './SharedPlanPersistence';
import { PlanIdentity, PlanIdentityPort, PlanCloudPort, PlanCipherPort, PlanTransportSession,
  PlanTransportStore, SecureSharedPlanGateway } from './SecureSharedPlanGateway';

class AgcPlanIdentity implements PlanIdentityPort {
  credential(allowCreate: boolean): Promise<PlanIdentity> { return AnonymousIdentity.credential(allowCreate); }
  currentUid(): Promise<string> { return AnonymousIdentity.currentUid(); }
}
class AgcPlanCloud implements PlanCloudPort {
  invoke(method: string, token: string, params: Object[]): Promise<string> {
    return DatePlanCloudApi.invoke(method, token, params);
  }
}
class HuksPlanCipher implements PlanCipherPort {
  verifyPartner(key: string, raw: string): Promise<boolean> {
    return PlanPartnerLink.verify(SettingsStore.getPairId(), key, raw);
  }
  available(pairId: string): Promise<boolean> { return SecurePlanKeyStore.available(pairId); }
  seal(pairId: string, aad: string, plain: string, revision: number): Promise<string> {
    return SecurePlanKeyStore.seal(pairId, aad, plain, revision);
  }
  open(pairId: string, aad: string, envelope: string, revision: number): Promise<string | null> {
    return SecurePlanKeyStore.open(pairId, aad, envelope, revision);
  }
}
class RdbPlanTransport implements PlanTransportStore {
  async session(): Promise<PlanTransportSession | null> {
    const session = await SharedPlanRepo.session();
    if (session === null) return null;
    const transport: PlanTransportSession = { pairId: session.pairId, actorId: session.actorId,
      generation: session.generation };
    return await this.current(transport) ? transport : null;
  }
  async current(session: PlanTransportSession): Promise<boolean> {
    if (!await SharedPlanRepo.isCurrent(rdbSession(session))) return false;
    try {
      const intent = JSON.parse(await SecurePairingRepo.load()) as SecurePairingIntent;
      return intent !== null && intent.phase === 'ACTIVE' && intent.pairId === session.pairId
        && intent.flowId === session.generation && typeof intent.linkEnvelope === 'string'
        && intent.linkEnvelope.length > 0
        && intent.anchor === SettingsStore.getPairState() + '|' + SettingsStore.getPairId();
    } catch { return false; }
  }
  async cached(ctx: SharedPlanContext, planId: string): Promise<SharedPlanRecord | null> {
    const records = await new SharedPlanPersistence().list(ctx);
    const row = records.find((item: SharedPlanRecord) => item.planId === planId);
    return row === undefined ? null : row;
  }
  wire(session: PlanTransportSession, requestId: string, draft: string): Promise<string> {
    return SharedPlanRepo.wire(rdbSession(session), requestId, draft);
  }
  saveWire(session: PlanTransportSession, requestId: string, draft: string, wire: string): Promise<string> {
    return SharedPlanRepo.saveWire(rdbSession(session), requestId, draft, wire);
  }
}
function rdbSession(session: PlanTransportSession): SharedPlanSession {
  return { pairId: session.pairId, actorId: session.actorId, generation: session.generation };
}

/** Construction is side-effect free; no SDK request or legacy pairing adoption. */
export function createSecureSharedPlanGateway(): SecureSharedPlanGateway {
  return new SecureSharedPlanGateway(new AgcPlanIdentity(), new AgcPlanCloud(), new HuksPlanCipher(),
    new RdbPlanTransport(), () => FeatureFlags.sharedPlan && FeatureFlags.cloudPairing
      && SettingsStore.getPairState() === PAIRED && !SecureLifecycle.blocked());
}
