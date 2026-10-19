export interface DockSparkCycle {
  left: number;
  drift: number;
  delayMs: number;
  periodMs: number;
}

/** 随机化只改变路径和等待，不改变上升周期。纯参数可离线验证。 */
export class DockSparkMotion {
  static next(random: number, periodMs: number): DockSparkCycle {
    const value = Number.isFinite(random) ? random - Math.floor(random) : 0.5;
    const drift = (value * 13.37 + 0.17) % 1;
    const pause = (value * 7.13 + 0.31) % 1;
    return {
      left: 5 + value * 90,
      drift: -12 + drift * 24,
      delayMs: Math.round(300 + pause * 3000),
      periodMs: Number.isFinite(periodMs) && periodMs > 0 ? periodMs : 6200
    };
  }

  static opacity(progress: number, peak: number): number {
    if (progress <= 0 || progress >= 1) {
      return 0;
    }
    if (progress < 0.14) {
      return peak * progress / 0.14;
    }
    if (progress <= 0.6) {
      return peak;
    }
    return peak * (1 - progress) / 0.4;
  }
}
