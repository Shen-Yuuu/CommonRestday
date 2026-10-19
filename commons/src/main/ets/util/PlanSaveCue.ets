export interface PlanSaveCue {
  id: string;
  serial: number;
  createdAt: number;
}

/** 仅限本次进程的保存反馈，既不是计划数据，也不进入备份或云端。 */
export class PlanSaveCueStore {
  private serial: number = 0;
  private cue: PlanSaveCue | undefined = undefined;

  publish(id: string, now: number): number {
    if (id.trim() === '' || !Number.isFinite(now)) {
      return 0;
    }
    this.serial++;
    this.cue = { id: id, serial: this.serial, createdAt: now };
    return this.serial;
  }

  peek(now: number): PlanSaveCue | undefined {
    if (this.cue === undefined || !Number.isFinite(now)) {
      return undefined;
    }
    const age = now - this.cue.createdAt;
    return age >= 0 && age <= 30000 ? this.cue : undefined;
  }

  consume(serial: number): boolean {
    if (this.cue === undefined || this.cue.serial !== serial) {
      return false;
    }
    this.cue = undefined;
    return true;
  }
}
