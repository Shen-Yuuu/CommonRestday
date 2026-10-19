/** API 23+ offset() 明确返回可空值；未绑定控制器时保留上次的位置。 */
export function readScrollY(scroller: Scroller, fallback: number = 0): number {
  const last = Number.isFinite(fallback) ? Math.max(0, fallback) : 0;
  try {
    const offset = scroller.offset();
    return offset != null && Number.isFinite(offset.yOffset) ? Math.max(0, offset.yOffset) : last;
  } catch {
    return last;
  }
}
