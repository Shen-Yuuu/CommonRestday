/**
 * 灰度开关与回退口径（阶段 6 Task 6.2）。三条规则不因排期压力让步：
 *
 * 1) 只有本文件的源码常量能改档位：改一行 + 重新出包。禁止远端动态下发——本项目没有可用的
 *    云端配置通道（云配对仍受 Task 0.4 门禁关闭），"能远程改"本身就是一条未验证的能力。
 * 2) 每个开关必须有读取方，且关闭分支必须真的能跑。没有读取方的开关是假的安全感
 *    （docs/testing-checklist.md §11.14）：阶段 1 的 newShell 就因旧四 Tab 壳层已退场、
 *    关不回任何链路而删掉，壳层的回退方式改成"回退整包"。
 * 3) 开关只关"能力"，不关"数据"。任一档关闭时本机已落库的事实仍可读、可改、可删。
 *
 * 各档的启用条件、监控指标、关闭影响与数据兼容性见 docs/release/rollout-and-rollback.md。
 */
export class FeatureFlags {
  /**
   * 系统日历链路（阶段 2 起，阶段 6R.1 换成应用专属「同休日」日历的受管写入）。读取方两处：
   * `PlanUseCase` 的日历编排（关掉时一条日历调用都不发，状态归一成 `NOT_REQUESTED`），
   * 以及 `PlanFlow` 的写入口判断（`canRetryCalendarSync` 与 `canExportToCalendar` 同时关档）——
   * 入口与链路必须一起退场，否则回退档会留下点了不会有任何反应的按钮。
   * 清理路径**不受本档控制**：开档时写进去的日程，关档后照样删得掉，不留没人认领的孤儿。
   */
  static readonly calendarFlow: boolean = true;
  /**
   * 云端配对与加密快照（阶段 3）。Task 0.4 门禁结论是 CLOUD_BLOCKED，HUKS 托管长期密钥
   * 未验证前不得开启，也不允许退回"短码派生长期密钥"。
   */
  static readonly cloudPairing: boolean = false;
  /** 扫码配对（阶段 4）。以 cloudPairing 为前提，门禁未过前保持 false。 */
  static readonly scanPairing: boolean = false;
  /**
   * 桌面 2×2 卡片内容（阶段 4）。读取方：FormAbility。关闭时卡片照常存在（添加动作在系统侧），
   * 但下发「桌面卡片已停用」而不是空白，也不是昨天的旧结论。
   */
  static readonly newCard: boolean = true;
  /**
   * 容器级响应式断点（阶段 5）。读取方：Breakpoints.ofWidth，全站断点唯一入口。
   * 关闭即一律 compact：宽屏居中封顶、分档留白、共同时间双栏一起退到阶段 4 的单列形态。
   * 适老化（Senior Mode 低密度）不在本档里，那是用户设置项，不是灰度能力。
   */
  static readonly responsiveV2: boolean = true;

  /**
   * 生效档位的一行摘要，按 rollout 顺序排列，只用于启动日志（entry 的 Index.aboutToAppear）。
   * 本项目没有远端遥测：出包时把这一行留在 hilog 里，是用户反馈截图之外唯一能证明
   * "这个包到底开了哪几档"的现场证据，所以五个开关一个都不能漏。
   */
  static summary(): string {
    return 'calendarFlow=' + FeatureFlags.of(FeatureFlags.calendarFlow)
      + ' cloudPairing=' + FeatureFlags.of(FeatureFlags.cloudPairing)
      + ' scanPairing=' + FeatureFlags.of(FeatureFlags.scanPairing)
      + ' newCard=' + FeatureFlags.of(FeatureFlags.newCard)
      + ' responsiveV2=' + FeatureFlags.of(FeatureFlags.responsiveV2);
  }

  /** 布尔 → on/off：不让 true/false 混进日志，也避开 ArkTS 的隐式字符串拼接。 */
  private static of(value: boolean): string {
    return value ? 'on' : 'off';
  }
}
