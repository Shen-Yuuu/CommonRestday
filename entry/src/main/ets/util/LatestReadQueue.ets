/** Collapse same-turn reads; changes during a read schedule only the newest follow-up. */
export class LatestReadQueue {
  private pending: (() => Promise<void>) | null = null;
  private active: Promise<void> | null = null;
  cancel(): void { this.pending = null; }
  run(work: () => Promise<void>): Promise<void> {
    this.pending = work;
    if (this.active !== null) return this.active;
    this.active = Promise.resolve().then(() => this.drain());
    return this.active;
  }
  private async drain(): Promise<void> {
    try {
      while (this.pending !== null) {
        const work = this.pending;
        this.pending = null;
        await work();
      }
    } finally { this.active = null; }
  }
}
