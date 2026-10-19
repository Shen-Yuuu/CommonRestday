/** Share only work still in flight. A write boundary invalidates sharing, not the old work. */
export class SingleFlight<T> {
  private active: Promise<T> | null = null;
  invalidate(): void { this.active = null; }
  run(work: () => Promise<T>): Promise<T> {
    if (this.active !== null) return this.active;
    const active = work().then((value: T): T => {
      if (this.active === active) this.active = null;
      return value;
    }, (error: Error): T => {
      if (this.active === active) this.active = null;
      throw error;
    });
    this.active = active;
    return active;
  }
}
