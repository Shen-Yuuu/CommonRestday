import { PlanSaveCue, PlanSaveCueStore } from 'commons';

const cues: PlanSaveCueStore = new PlanSaveCueStore();

export function publishPlanSaved(planId: string): void {
  const serial = cues.publish(planId, Date.now());
  if (serial > 0) {
    AppStorage.setOrCreate<number>('crd_plan_saved_tick', serial);
  }
}

export function peekSavedPlan(): PlanSaveCue | undefined {
  return cues.peek(Date.now());
}

export function consumeSavedPlan(serial: number): boolean {
  return cues.consume(serial);
}
