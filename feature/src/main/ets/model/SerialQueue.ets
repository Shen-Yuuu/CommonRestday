/**
 * 独占队列：把同名任务排成 FIFO，前一段没落地就不许后一段开跑。
 *
 * 为什么需要它（差异文档 D-52 的后半边）：重算这一段是"读输入 → 引擎 → 写回缓存表"，而它的入口有八处
 * （写命令、计划操作、作息保存、下拉刷新、日切重算、冷启动/回前台、桌面卡片）。两次重算重叠时，先起的
 * 那次读的是后一次写入**提交之前**的表，晚落地就把两代结果留在同一张表里——`ScheduleRepo.replaceWindows`
 * 只删 `computed_at` 更旧的行，旧一代晚到就删不掉新一代，界面上会出现"已经改掉的班还在"。脏的是库，
 * 页面再读也读不回来，只能等下一次重算自愈。这里排的是顺序，不是并发数：队列只允许一段在跑。
 *
 * 一条约束要记住：**排进队列的任务里不许再排同一个队列**（嵌套会自己等自己，永久卡住）。
 * 重算的关键段只读表、算引擎、写缓存，不反向触发命令层，这条约束成立；接新任务时先复核这一点。
 */
export class SerialQueue {
  private tail: Promise<void> = Promise.resolve();

  /** 排队执行：返回的 promise 与任务同结果同失败；失败也会放行下一位，不会把队列锁死。 */
  run<T>(work: () => Promise<T>): Promise<T> {
    const previous: Promise<void> = this.tail;
    let release: () => void = (): void => {
    };
    this.tail = new Promise<void>((resolve) => {
      release = resolve;
    });
    return previous.then(async (): Promise<T> => {
      try {
        return await work();
      } finally {
        release();
      }
    });
  }
}
