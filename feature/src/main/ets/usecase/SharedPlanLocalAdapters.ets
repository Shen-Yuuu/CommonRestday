import { util } from '@kit.ArkTS';
import { EngineParams, OWNER_ME, todayEpochDay, nowEpochMin } from 'domain';
import { ScheduleRepo, PlanRow, SharedPlanRepo, SharedPlanSession } from 'data';
import { IdentifiedPlan, SharedLocalInputs, SharedLocalReader, SharedPlanLocalCheck } from './SharedPlanLocalCheck';
import { ScheduleUseCase, SettingsStoreParams, RECOMPUTE_COUNT_KEY } from './ScheduleUseCase';
import { SharedPlanUseCase } from './SharedPlanUseCase';
import { SharedPlanPersistence } from './SharedPlanPersistence';
import { createSecureSharedPlanGateway } from './SecurePlanAdapters';

class RdbLocalReader implements SharedLocalReader {
  private readSession: SharedPlanSession | null = null;
  nowMin(): number { return nowEpochMin(); }
  newId(): string { return util.generateRandomUUID(); }
  params(): EngineParams { return SettingsStoreParams(); }
  async load(startDay: number, days: number, excludingPlanId: string): Promise<SharedLocalInputs | null> {
    const session = await SharedPlanRepo.session();
    if (session === null) return null;
    this.readSession = session;
    const params = ScheduleUseCase.dayParamsOf(this.params(), days);
    const my = await ScheduleUseCase.loadMySchedule(startDay, params, OWNER_ME);
    const rows = await ScheduleRepo.listActivePlans();
    const plans: IdentifiedPlan[] = rows.map((row: PlanRow): IdentifiedPlan => {
      const plan: IdentifiedPlan = { id: row.id, start: row.start, end: row.end }; return plan;
    });
    const localId = excludingPlanId === '' ? '' : await SharedPlanRepo.localActivityId(session, excludingPlanId);
    return { my, plans, excludingLocalId: localId };
  }
  current(): Promise<boolean> {
    return this.readSession === null ? Promise.resolve(false) : SharedPlanRepo.isCurrent(this.readSession);
  }
  changed(): void {
    AppStorage.setOrCreate<number>('crdSharedPlanTick', (AppStorage.get<number>('crdSharedPlanTick') ?? 0) + 1);
  }
  async recompute(): Promise<void> {
    await ScheduleUseCase.recompute(todayEpochDay(), true);
    AppStorage.setOrCreate<number>(RECOMPUTE_COUNT_KEY, (AppStorage.get<number>(RECOMPUTE_COUNT_KEY) ?? 0) + 1);
  }
}
let instance: SharedPlanUseCase | null = null;
/** Construction does not sign in or call cloud. */
export function secureSharedPlans(): SharedPlanUseCase {
  if (instance === null) instance = new SharedPlanUseCase(createSecureSharedPlanGateway(),
    new SharedPlanPersistence(), new SharedPlanLocalCheck(new RdbLocalReader()));
  return instance;
}
