import { ColorMetrics, LengthMetrics } from '@kit.ArkUI';

/** 减少动效开关的 AppStorage 键：系统「减少动态效果」由 AccessibilityPolicy 写入，组件用 @StorageProp 订阅。 */
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

  // ---- 气氛背景层：低饱和日光/莓粉/冷蓝，只用于首页顶部一条，正文不压在它上面 ----
  static readonly sceneWarm: Resource = $r('app.color.scene_warm');
  static readonly sceneRose: Resource = $r('app.color.scene_rose');
  static readonly sceneBlue: Resource = $r('app.color.scene_blue');
  /** 暖白雾层：压在气氛层与内容之间，保证合成后文字底下总有可预测底色。 */
  static readonly sceneVeilStrong: Resource = $r('app.color.scene_veil_strong');
  static readonly sceneVeilSoft: Resource = $r('app.color.scene_veil_soft');

  // ---- 交互玻璃层：strong=悬浮底栏与 Sheet，soft=首页唯一主结果（深莓底） ----
  static readonly glassStrong: Resource = $r('app.color.glass_strong');
  static readonly glassSoft: Resource = $r('app.color.glass_soft');
  static readonly glassBorder: Resource = $r('app.color.glass_border');
  static readonly glassHighlight: Resource = $r('app.color.glass_highlight');
  /** 实色回退底：系统材质不可用或算力不足时的近实色（92%–96% 暖白）。 */
  static readonly glassFallback: Resource = $r('app.color.glass_fallback');
  static readonly glassShadow: Resource = $r('app.color.glass_shadow');

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
  /**
   * 周历双泳道的玻璃层：底色是同一条忙碌色的半透明版，描边用高一档的 alpha。
   * 泳道只表示"这段时间不能安排"，不承载文字，所以 alpha 可以压得比正文卡低。
   */
  static readonly busyMineGlass: Resource = $r('app.color.busy_mine_glass');
  static readonly busyMineEdge: Resource = $r('app.color.busy_mine_edge');
  static readonly busyPartnerGlass: Resource = $r('app.color.busy_partner_glass');
  static readonly busyPartnerEdge: Resource = $r('app.color.busy_partner_edge');
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
  /**
   * 基准四档。长辈模式不另立一套字号，而是整条阶梯向上挪一档：caption 的 senior 值就是 body 的基准值。
   * 复用而不是复制，"提高一级"才是定义本身——调 font_body 会同时调到 senior 的 caption。
   * 只有最高档没有现成的上一档可用，单独给它一档 38fp。
   */
  static readonly fontCaptionBase: Resource = $r('app.float.font_caption');
  static readonly fontBodyBase: Resource = $r('app.float.font_body');
  static readonly fontTitleBase: Resource = $r('app.float.font_title');
  static readonly fontDisplayBase: Resource = $r('app.float.font_display');
  static readonly fontDisplaySenior: Resource = $r('app.float.font_display_senior');
  /**
   * 密集标注两档：周历/时间轴刻度、色块里的字数、图例这一类，整档跳会把网格顶散，
   * 所以 senior 只加 2fp，并守住 10fp 地板（历史上散在页面上的 8fp、9fp 裸数字一律并进 micro）。
   */
  static readonly fontMicroBase: Resource = $r('app.float.font_micro');
  static readonly fontMicroSenior: Resource = $r('app.float.font_micro_senior');
  static readonly fontTickBase: Resource = $r('app.float.font_tick');
  static readonly fontTickSenior: Resource = $r('app.float.font_tick_senior');

  /**
   * 字号取值。senior 由调用方在自己的 @StorageProp('crd_senior_mode') 成员上读，写在属性表达式里，
   * 这样关怀模式切换会走状态驱动的重新布局，不需要重启应用。
   * 做成方法而不是静态字段：字段拿不到状态；而漏传参的写法（把方法本身当字号值用）会编译失败，
   * 所以覆盖面由编译器保证，不靠人工数"改了多少处"。
   */
  static fontCaption(senior: boolean): Resource {
    return senior ? DesignTokens.fontBodyBase : DesignTokens.fontCaptionBase;
  }

  static fontBody(senior: boolean): Resource {
    return senior ? DesignTokens.fontTitleBase : DesignTokens.fontBodyBase;
  }

  static fontTitle(senior: boolean): Resource {
    return senior ? DesignTokens.fontDisplayBase : DesignTokens.fontTitleBase;
  }

  static fontDisplay(senior: boolean): Resource {
    return senior ? DesignTokens.fontDisplaySenior : DesignTokens.fontDisplayBase;
  }

  static fontMicro(senior: boolean): Resource {
    return senior ? DesignTokens.fontMicroSenior : DesignTokens.fontMicroBase;
  }

  static fontTick(senior: boolean): Resource {
    return senior ? DesignTokens.fontTickSenior : DesignTokens.fontTickBase;
  }


  // ---- 圆角与热区 ----
  static readonly radiusCard: Resource = $r('app.float.radius_card');
  static readonly radiusCardCut: Resource = $r('app.float.radius_card_cut');
  static readonly radiusSheet: Resource = $r('app.float.radius_sheet');
  static readonly radiusPill: Resource = $r('app.float.radius_pill');
  static readonly hitMin: Resource = $r('app.float.hit_min');

  // ---- 玻璃层几何：1vp 描边 + 大半径低透明环境阴影，圆角仍复用 radius* ----
  static readonly glassBorderWidth: number = 1;
  static readonly glassShadowRadius: number = 34;
  static readonly glassShadowOffsetY: number = 14;

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
  /** 玻璃层进入/选中态迁移：150–220ms，只做透明度与轻微位移。 */
  static readonly motionGlassEnter: number = 200;
  static readonly pressScale: number = 0.98;
  /**
   * 气氛背景漂移周期（ms）与幅度（vp）：规范只允许 8–16 秒、2–6vp 的极轻漂移，
   * 默认关闭，由 AmbientScene 的 drift 入参显式打开；减少动效时强制为 0。
   */
  static readonly motionSceneShift: number = 12000;
  static readonly sceneDriftVp: number = 4;
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

  /** 列表错峰延迟：减少动效时不错峰（Task 5.2 规则，须与 offset 同时关闭）。 */
  static stagger(reduceMotion: boolean, index: number): number {
    return reduceMotion ? 0 : DesignTokens.staggerStep * index;
  }

  // ---- ChipV2（API 26 筛选 Chip）：颜色与几何仍复用上面同一套令牌 ----
  // 用方法而不是静态字段：ColorMetrics/LengthMetrics 在 build 期取值，避免模块加载期解析资源。
  /** 未选中文字，与自制 Chip 时期同一份次级文本色。 */
  static chipText(): ColorMetrics {
    return ColorMetrics.resourceColor(DesignTokens.textSecondary);
  }

  /** 选中文字：压在品牌粉上的暖白前景。 */
  static chipTextOn(): ColorMetrics {
    return ColorMetrics.resourceColor(DesignTokens.heroText);
  }

  static chipBg(): ColorMetrics {
    return ColorMetrics.resourceColor(DesignTokens.fillWeak);
  }

  static chipBgOn(): ColorMetrics {
    return ColorMetrics.resourceColor(DesignTokens.primary);
  }

  static chipFontSize(senior: boolean): LengthMetrics {
    return LengthMetrics.resource(DesignTokens.fontCaption(senior));
  }

  static chipRadius(): LengthMetrics {
    return LengthMetrics.resource(DesignTokens.radiusPill);
  }
}
