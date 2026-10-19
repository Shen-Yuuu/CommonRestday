import { buildAvailability, dayOfStart, daySpan, EngineParams, MIN_PER_DAY, MySchedule, PlanBlock } from 'domain';
import { SharedPlanContent } from '../model/SharedPlanFlow';
import { SharedPlanLocalPort } from './SharedPlanUseCase';

export interface IdentifiedPlan extends PlanBlock { id: string; }
export interface SharedLocalInputs { my: MySchedule; plans: IdentifiedPlan[]; excludingLocalId: string; }
export interface SharedLocalReader {
  nowMin(): number;
  newId(): string;
  params(): EngineParams;
  load(startDay: number, days: number, excludingPlanId: string): Promise<SharedLocalInputs | null>;
  current(): Promise<boolean>;
  recompute(): Promise<void>;
  changed?(): void;
}

/** Rebuild before merging: dropping a merged interval can hide a different shift/course/plan. */
export class SharedPlanLocalCheck implements SharedPlanLocalPort {
  private reader: SharedLocalReader;
  constructor(reader: SharedLocalReader) { this.reader = reader; }
  nowMin(): number { return this.reader.nowMin(); }
  newId(): string { return this.reader.newId(); }
  recompute(): Promise<void> { return this.reader.recompute(); }
  changed(): void { if (this.reader.changed !== undefined) this.reader.changed(); }
  async canArrange(content: SharedPlanContent, excludingPlanId: string): Promise<boolean> {
    try {
      const now = this.nowMin(); const params = this.reader.params();
      const horizonEnd = (dayOfStart(now) + params.horizonDays) * MIN_PER_DAY;
      if (!Number.isSafeInteger(content.start) || !Number.isSafeInteger(content.end)
        || content.start < now || content.end - content.start < 15 || content.end > horizonEnd) return false;
      // Include the preceding day: its late shift/recovery may occupy the candidate's morning.
      const startDay = dayOfStart(content.start) - 1; const days = daySpan(content.start, content.end) + 2;
      const inputs = await this.reader.load(startDay, days, excludingPlanId);
      if (inputs === null || !await this.reader.current()) return false;
      const plans: PlanBlock[] = [];
      for (const row of inputs.plans) {
        if (excludingPlanId !== '' && inputs.excludingLocalId !== '' && row.id === inputs.excludingLocalId) continue;
        plans.push({ start: row.start, end: row.end });
      }
      const my = inputs.my;
      const schedule: MySchedule = { shiftTypes: my.shiftTypes, template: my.template, overrides: my.overrides,
        courses: my.courses, sectionTimes: my.sectionTimes, termStartEpochDay: my.termStartEpochDay,
        plans, wakeMin: my.wakeMin, bedMin: my.bedMin, windDownMin: my.windDownMin,
        datedDays: my.datedDays, personalEntries: my.personalEntries, weeklyMode: my.weeklyMode };
      const busy = buildAvailability(schedule, params, startDay, days).notAvailable;
      const overlaps = busy.some(iv => iv.start < content.end && content.start < iv.end);
      return !overlaps && await this.reader.current();
    } catch { return false; }
  }
}
