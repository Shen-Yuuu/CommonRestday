import { util } from '@kit.ArkTS';
import { AnonymousIdentity, DatePlanCloudApi, SecurePlanKeyStore, PlanPartnerLink } from 'cloud';
import { SecurePairingRepo, SettingsStore, SharedPlanSession, PAIRED } from 'data';
import { FeatureFlags } from '../config/FeatureFlags';
import { SecureLifecycle } from './SecureLifecycle';
import { ScheduleUseCase, RECOMPUTE_COUNT_KEY } from './ScheduleUseCase';
import { todayEpochDay } from 'domain';
import { PlanIdentity, PlanIdentityPort, PlanCloudPort } from './SecureSharedPlanGateway';
import { SecurePairingEnvironment, SecurePairingKeys, SecurePairingSession, SecurePairingStore,
  SecurePairingUseCase } from './SecurePairingUseCase';

class SetupIdentity implements PlanIdentityPort {
  credential(create: boolean): Promise<PlanIdentity> { return AnonymousIdentity.credential(create); }
}
class SetupCloud implements PlanCloudPort {
  invoke(method: string, token: string, params: Object[]): Promise<string> {
    return DatePlanCloudApi.invoke(method, token, params);
  }
}
class SetupKeys implements SecurePairingKeys {
  linkProof(publicKey: string, flow: string): Promise<string> {
    return PlanPartnerLink.create(SettingsStore.getPairId(), publicKey, flow);
  }
  verifyLink(peer: string, raw: string): Promise<boolean> {
    return PlanPartnerLink.verify(SettingsStore.getPairId(), peer, raw);
  }
  publicKey(uid: string, create: boolean): Promise<string> { return SecurePlanKeyStore.publicKey(uid, create); }
  sealProof(uid: string, flow: string, proof: string): Promise<string> { return SecurePlanKeyStore.sealProof(uid, flow, proof); }
  openProof(uid: string, flow: string, raw: string): Promise<string | null> { return SecurePlanKeyStore.openProof(uid, flow, raw); }
  agree(uid: string, pair: string, peer: string): Promise<void> { return SecurePlanKeyStore.agree(uid, pair, peer); }
  available(pair: string): Promise<boolean> { return SecurePlanKeyStore.available(pair); }
  dropProof(uid: string, flow: string): Promise<void> { return SecurePlanKeyStore.dropProof(uid, flow); }
  drop(pair: string): Promise<void> { return SecurePlanKeyStore.drop(pair); }
}
class SetupStore implements SecurePairingStore {
  load(): Promise<string> { return SecurePairingRepo.load(); }
  async hasCleanup(): Promise<boolean> { return (await SecurePairingRepo.cleanupRecords()).length > 0; }
  save(expected: string, next: string): Promise<boolean> { return SecurePairingRepo.save(expected, next); }
  activate(expected: string, next: string, session: SecurePairingSession): Promise<boolean> {
    const mapped: SharedPlanSession = { pairId: session.pairId, actorId: session.actorId, generation: session.generation };
    return SecurePairingRepo.activate(expected, next, mapped);
  }
  async revoke(expected: string, next: string): Promise<boolean> {
    const saved = await SecurePairingRepo.revoke(expected, next);
    if (saved) {
      try {
        await ScheduleUseCase.recompute(todayEpochDay(), true);
        AppStorage.setOrCreate<number>(RECOMPUTE_COUNT_KEY, (AppStorage.get<number>(RECOMPUTE_COUNT_KEY) ?? 0) + 1);
      }
      catch { /* Revocation is durable; startup recomputation will finish updating cached windows. */ }
    }
    return saved;
  }
}
class SetupEnvironment implements SecurePairingEnvironment {
  enabled(): boolean { return FeatureFlags.securePairing && FeatureFlags.cloudPairing
    && SettingsStore.getPairState() === PAIRED && !SecureLifecycle.blocked(); }
  cleanupEnabled(): boolean { return FeatureFlags.cloudPairing && !SecureLifecycle.blocked(); }
  anchor(): string { return SettingsStore.getPairState() + '|' + SettingsStore.getPairId(); }
  epoch(): string { return SecureLifecycle.anchor(); }
  nextId(): string { return util.generateRandomUUID(); }
}
let instance: SecurePairingUseCase | null = null;
/** Construction does not log in, create keys or call cloud. Shared instance owns the submission latch. */
export function securePairingSetup(): SecurePairingUseCase {
  if (instance === null) instance = new SecurePairingUseCase(new SetupIdentity(), new SetupCloud(), new SetupKeys(),
    new SetupStore(), new SetupEnvironment());
  return instance;
}
