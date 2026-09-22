/**
 * 响应式断点（Task 5.1）：容器宽度 → 三档，全站唯一判定口径，页面不参与换算。
 * compact `<600vp`、medium `600–839vp`、expanded `>=840vp`。
 *
 * 为什么按数值分档而不读 WidthBreakpoint：SDK 的 WidthBreakpoint 边界是
 * 320/600/840/1440（component/enums.d.ts），与本档的 600/840 恰好重合，
 * 但「自定义阈值 → 枚举值」的映射在 SDK 声明里查不到依据，
 * 所以只取容器自己的 width 做数值分类，语义由本页兜住。
 */
import { FeatureFlags } from 'feature';

export enum Breakpoint {
  COMPACT = 'compact',
  MEDIUM = 'medium',
  EXPANDED = 'expanded'
}

export class Breakpoints {
  static readonly MEDIUM_MIN: number = 600;
  static readonly EXPANDED_MIN: number = 840;
  /** 正文可读宽度上限：再宽就靠留白和分栏，不把一段文字拉到整屏。 */
  static readonly READABLE_MAX: number = 720;
  /** 共同时间「列表—详情」双栏里详情栏的固定宽度：够放窗口摘要 + 计划表单。 */
  static readonly DETAIL_PANE: number = 380;

  /**
   * 宽度 → 档位。FeatureFlags.responsiveV2 的回退点就掐在这里：
   * 全站断点只有这一个入口，返回 COMPACT 等于封顶、分档留白、双栏一起退到阶段 4 的单列形态，
   * 不会出现"外壳收成了两栏、里面还在按窄屏排版"的半开状态。
   */
  static ofWidth(vp: number): Breakpoint {
    if (!FeatureFlags.responsiveV2) {
      return Breakpoint.COMPACT;
    }
    if (vp >= Breakpoints.EXPANDED_MIN) {
      return Breakpoint.EXPANDED;
    }
    if (vp >= Breakpoints.MEDIUM_MIN) {
      return Breakpoint.MEDIUM;
    }
    return Breakpoint.COMPACT;
  }

  /** expanded 才并排/开详情栏：medium 放不下列表 + 380vp 详情，宁可继续用半模态。 */
  static isExpanded(bp: Breakpoint): boolean {
    return bp === Breakpoint.EXPANDED;
  }

  /** 页面左右留白：窄屏维持原样，宽屏按 editorial 的呼吸感放大。 */
  static hPadding(bp: Breakpoint): number {
    if (bp === Breakpoint.EXPANDED) {
      return 32;
    }
    return bp === Breakpoint.MEDIUM ? 24 : 18;
  }

  /** 正文列上限：compact 不封顶（与改造前完全一致），其余档收拢到可读宽度。 */
  static contentMaxWidth(bp: Breakpoint): Length {
    if (bp === Breakpoint.EXPANDED) {
      return Breakpoints.READABLE_MAX;
    }
    return bp === Breakpoint.MEDIUM ? 600 : '100%';
  }

  /** onAreaChange 的 width 是 Length：只有数值带 vp 语义，字符串/资源一律当"没量到"。 */
  static widthOf(area: Area): number {
    const w: Length = area.width;
    if (typeof w === 'number') {
      return w;
    }
    return 0;
  }
}
