import { DEBUG } from '../../../../BuildProfile';

/**
 * 灰度开关：仅由编译期 BuildProfile 映射，禁止远端动态下发。
 * 阶段 0/1 只默认在 debug 构建开启 newShell；其余能力在各自阶段门禁前保持 false，
 * 关闭时必须能退回旧链路而不是让页面空白。
 */
export class FeatureFlags {
  /** 三 Tab + Navigation 新壳层（阶段 1）。 */
  static readonly newShell: boolean = DEBUG;
  /** 云端配对与加密快照（阶段 3，受 Task 0.4 门禁约束）。 */
  static readonly cloudPairing: boolean = false;
  /** 扫码配对（阶段 4，需真机验证 Scan Kit）。 */
  static readonly scanPairing: boolean = false;
  /** 新版桌面卡片（阶段 4）。 */
  static readonly newCard: boolean = false;
  /** API 26 响应式与适老化增强（阶段 5）。 */
  static readonly responsiveV2: boolean = false;
}
