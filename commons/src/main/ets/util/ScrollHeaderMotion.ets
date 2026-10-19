/** 页头只做视觉缩放，不改变滚动区域的占位高度。 */
export class ScrollHeaderMotion {
  static titleScale(offset: number, reduceMotion: boolean): number {
    return 1 - 0.18 * ScrollHeaderMotion.progress(offset, reduceMotion);
  }

  /** 只保存视觉变化范围内的绝对偏移；深滚动与回弹不再制造多余通知。 */
  static visualOffset(offset: number): number {
    return Number.isFinite(offset) ? Math.min(96, Math.max(0, offset)) : 0;
  }

  static subtitleOpacity(offset: number, reduceMotion: boolean): number {
    return 1 - ScrollHeaderMotion.progress(offset, reduceMotion);
  }

  static edgeOpacity(offset: number): number {
    return !Number.isFinite(offset) ? 0 : Math.min(1, Math.max(0, offset / 24));
  }

  static progress(offset: number, reduceMotion: boolean): number {
    return reduceMotion || !Number.isFinite(offset) ? 0 : Math.min(1, Math.max(0, offset / 96));
  }
}
