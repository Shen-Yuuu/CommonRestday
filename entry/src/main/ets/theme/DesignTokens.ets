/** 减少动效开关的 AppStorage 键：设置页写入，组件用 @StorageProp 订阅。 */
export const MOTION_REDUCE_KEY: string = 'crd_reduce_motion';

/**
 * 温暖编辑感（视觉方向 01）设计令牌。
 * 颜色/尺寸只在此处集中引用资源：深浅色由 base 与 dark 两套 color.json 自动切换，
 * 字号走 fp 资源随系统大字体缩放，页面不得再写十六进制或裸尺寸字面量。
 */
export class DesignTokens {
  // ---- 表面与品牌色 ----
  static readonly page: Resource = $r('app.color.page_bg_warm');
  static readonly pageSoft: Resource = $r('app.color.page_bg_soft');
  static readonly pageGlow: Resource = $r('app.color.page_glow');
  static readonly card: Resource = $r('app.color.card_bg');
  static readonly primary: Resource = $r('app.color.brand_pink');
  static readonly primaryBg: Resource = $r('app.color.brand_pink_bg');
  static readonly primaryBorder: Resource = $r('app.color.brand_pink_border');
  static readonly hero: Resource = $r('app.color.hero_bg');
  static readonly heroText: Resource = $r('app.color.hero_fg');
  static readonly heroGlow: Resource = $r('app.color.hero_glow');
  static readonly shadowSoft: Resource = $r('app.color.shadow_soft');
  static readonly focusRing: Resource = $r('app.color.focus_ring');

  // ---- 文本 ----
  static readonly textPrimary: Resource = $r('app.color.text_primary');
  static readonly textSecondary: Resource = $r('app.color.text_secondary');
  static readonly textTertiary: Resource = $r('app.color.text_tertiary');
  static readonly textHint: Resource = $r('app.color.text_hint');
  static readonly textDisabled: Resource = $r('app.color.text_disabled');

  // ---- 分隔与填充 ----
  static readonly divider: Resource = $r('app.color.divider');
  static readonly borderWeak: Resource = $r('app.color.border_weak');
  static readonly fillWeak: Resource = $r('app.color.fill_weak');
  static readonly fillSoft: Resource = $r('app.color.fill_soft');
  static readonly fillWeakest: Resource = $r('app.color.fill_weakest');
  static readonly sheetHandle: Resource = $r('app.color.sheet_handle');

  // ---- 语义色 ----
  static readonly success: Resource = $r('app.color.success_green');
  static readonly successBg: Resource = $r('app.color.success_bg');
  /** 双方忙碌标识色：我=青灰，TA=驼色（今日概览的圆点，与周视图同一套色）。 */
  static readonly busyMine: Resource = $r('app.color.my_busy');
  static readonly busyPartner: Resource = $r('app.color.partner_busy');
  static readonly danger: Resource = $r('app.color.danger_red');
  static readonly dangerBg: Resource = $r('app.color.danger_bg');
  static readonly dangerBorder: Resource = $r('app.color.danger_border');
  static readonly warn: Resource = $r('app.color.warn_orange');

  // ---- 共同空闲分级色：周历色块按当日共同空闲时长分三档（≥6h 用 primary） ----
  static readonly freeMid: Resource = $r('app.color.month_free_mid_bg');
  static readonly freeLow: Resource = $r('app.color.month_free_low_bg');
  /** 分级色块上的文字：深色块用暖白，浅色块用配套前景，不写死 #FFFFFF。 */
  static readonly freeOnStrong: Resource = $r('app.color.hero_fg');
  static readonly freeOnLow: Resource = $r('app.color.month_free_low_fg');

  // ---- 间距：4/8/12/16/24/32 ----
  static readonly space1: Resource = $r('app.float.space_1');
  static readonly space2: Resource = $r('app.float.space_2');
  static readonly space3: Resource = $r('app.float.space_3');
  static readonly space4: Resource = $r('app.float.space_4');
  static readonly space5: Resource = $r('app.float.space_5');
  static readonly space6: Resource = $r('app.float.space_6');

  // ---- 字号：说明/正文/小标题/展示标题 ----
  static readonly fontCaption: Resource = $r('app.float.font_caption');
  static readonly fontBody: Resource = $r('app.float.font_body');
  static readonly fontTitle: Resource = $r('app.float.font_title');
  static readonly fontDisplay: Resource = $r('app.float.font_display');

  // ---- 圆角与热区 ----
  static readonly radiusCard: Resource = $r('app.float.radius_card');
  static readonly radiusCardCut: Resource = $r('app.float.radius_card_cut');
  static readonly radiusSheet: Resource = $r('app.float.radius_sheet');
  static readonly radiusPill: Resource = $r('app.float.radius_pill');
  static readonly hitMin: Resource = $r('app.float.hit_min');

  // ---- 字体族：标题走衬线回退链，正文走系统无衬线 ----
  static readonly fontSerif: string = 'Iowan Old Style, Songti SC, STSong, serif';
  static readonly fontSans: string = 'HarmonyOS Sans SC, PingFang SC, sans-serif';

  // ---- 动效：easing 固定，时长分标准与减少动效两档 ----
  // 本 SDK 的 curves.cubicBezier 已 deprecated 且返回字符串，直接用 CSS 形式描述同一条曲线。
  static readonly curve: string = 'cubic-bezier(0.22, 1, 0.36, 1)';
  static readonly motionPage: number = 700;
  static readonly motionItem: number = 550;
  static readonly motionFade: number = 350;
  static readonly motionPress: number = 150;
  static readonly pressScale: number = 0.98;
  /** 入场位移（vp）与列表错峰步进（ms）。 */
  static readonly enterOffset: number = 14;
  static readonly staggerStep: number = 45;

  /** 卡片默认错角 8/21/21/21；偶数卡把切角换到右上，形成 21/8/21/21。 */
  static cardRadius(cutTopLeft: boolean): BorderRadiuses {
    const cut: Resource = DesignTokens.radiusCardCut;
    const round: Resource = DesignTokens.radiusCard;
    if (cutTopLeft) {
      return { topLeft: cut, topRight: round, bottomLeft: round, bottomRight: round };
    }
    return { topLeft: round, topRight: cut, bottomLeft: round, bottomRight: round };
  }

  /** 开启减少动效时时长归零：位移动画退化为直接呈现。 */
  static motion(reduceMotion: boolean, ms: number): number {
    return reduceMotion ? 0 : ms;
  }

  /** 开启减少动效时位移归零（只保留透明度也不做，见 motion）。 */
  static offset(reduceMotion: boolean, vp: number): number {
    return reduceMotion ? 0 : vp;
  }

  /** 列表错峰延迟：减少动效时不错峰。 */
  static stagger(reduceMotion: boolean, index: number): number {
    return reduceMotion ? 0 : DesignTokens.staggerStep * index;
  }
}
