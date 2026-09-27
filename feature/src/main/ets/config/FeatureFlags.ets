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
   * 云端配对与加密快照（阶段 3，批次 U·U3b 开闸）。Task 0.4 的 CLOUD_BLOCKED 结论已解除：
   * 两台 API 26 设备实测 ECDH 协商出的 AES-256 密钥只落在 HUKS 的
   * `HUKS_STORAGE_ONLY_USED_IN_HUKS` 别名里、`outData` 全零取不出来，跨端 GCM 往返与 AAD
   * 篡改拒绝也已验证（docs/validation/clouddev-api26-spike.md §2 实验 #5）。
   * 仍不允许退回"短码派生长期密钥"：开闸的前提就是密钥必须由 HUKS 托管。
   * 本档与 `ohos.permission.INTERNET`、隐私政策 v1.1 同批出入包（rollout §3.3）。
   */
  static readonly cloudPairing: boolean = true;
  /**
   * 扫码配对（阶段 4）。以 cloudPairing 为前提，但**开闸不等于扫码就绪**：二维码通道至今没有
   * 设备证据（rollout §6 明令不为它开档），所以它停在 false，配对入口只走配对码/分享链接。
   */
  static readonly scanPairing: boolean = false;
  /**
   * 回退档（`cloudPairing=false`）下**唯一**允许的用户口径（阶段 6R.2，验收报告 B1）。
   * 开档的包读不到这句话，但常量必须留着：回退是"改一行 + 重新出包"，那时三个出口
   * （service 层的拒绝、网关层的拒绝、「我的」页的说明文本）要逐字一致地回到同一句上。
   * 少一处、或措辞变一点，就会出现"UI 说没开放但代码还在发请求"的那种假安全。
   */
  static readonly cloudClosedMessage: string = '云端配对暂未开放（需开通 AGC 云服务），可先用本机代录';
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
