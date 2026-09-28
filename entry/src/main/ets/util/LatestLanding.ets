/**
 * 并发读数的落地闸门。
 *
 * 为什么要有它：一次读数从发起到写状态之间隔着 await，而 RDB 与云读数的**返回顺序没有保证**——
 * 先发起的那次完全可能后落地。组件的读数触发点不止一个（重算广播、下拉刷新、父页 @Prop 变化、
 * 翻页与切侧的点击），所以两次读数会重叠；后落地的若是先发起的那次，界面就停在旧结果上，
 * 而表头/选中档/侧别这些**同步改掉的** @State 已经是新的了——数据和它的说明分家。
 * 更坏的一支是旧的那次抛错：`failed = true` 会盖掉新读数的成功，把好数据念成"没读到"。
 *
 * 用法：每次读数 begin() 取一张号，落状态前 isCurrent() 问一次，不是最新发起的就整批丢弃
 * （包括 catch 里的失败态）。`loading` 只由最新那次收，被丢弃的读数不碰它。
 */
export class LatestLanding {
  private seq: number = 0;

  /** 领号：这一次读数成为"最新发起"。 */
  begin(): number {
    this.seq = this.seq + 1;
    return this.seq;
  }

  /** 手里的号还是最新的那一张吗？false = 已有更晚发起的读数，本次结果一律不落地。 */
  isCurrent(token: number): boolean {
    return token === this.seq;
  }
}
