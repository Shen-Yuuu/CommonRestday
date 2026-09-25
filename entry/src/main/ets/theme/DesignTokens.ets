import { ColorMetrics, LengthMetrics } from '@kit.ArkUI';

/** 减少动效开关的 AppStorage 键：系统「减少动态效果」由 AccessibilityPolicy 写入，组件用 @StorageProp 订阅。 */
export const MOTION_REDUCE_KEY: string = 'crd_reduce_motion';

/**
 * Q糖·7 分甜（视觉方向 02）设计令牌。
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
  /** 厚底色：果冻按钮/芯片下沿那 3vp 硬边，永远比 primary 深一档。 */
  static readonly primaryDeep: Resource = $r('app.color.brand_pink_deep');
  /** 进度条填充的浅端：从这档走到 primary，条子才有"糖砂"的渐变。 */
  static readonly primaryLight: Resource = $r('app.color.brand_pink_light');
  static readonly primaryBg: Resource = $r('app.color.brand_pink_bg');
  static readonly primaryBorder: Resource = $r('app.color.brand_pink_border');
  static readonly hero: Resource = $r('app.color.hero_bg');
  static readonly heroText: Resource = $r('app.color.hero_fg');
  static readonly heroGlow: Resource = $r('app.color.hero_glow');
  /** Hero 斜向渐变的两个端点（粉→珊瑚），中间一档用 primary。 */
  static readonly sunsetFrom: Resource = $r('app.color.sunset_from');
  static readonly sunsetTo: Resource = $r('app.color.sunset_to');
  static readonly shadowSoft: Resource = $r('app.color.shadow_soft');
  /** 品牌粉 20% 光：Hero 投影与底栏选中图标的落影（原型 --glow）。 */
  static readonly glow: Resource = $r('app.color.glow_pink');
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
  /** 半模态顶沿比页面亮一档的暖白（原型 .sheet 渐变起点，深色档是 #2E2545）。 */
  static readonly sheetTop: Resource = $r('app.color.sheet_top');

  // ---- 语义色 ----
  static readonly success: Resource = $r('app.color.success_green');
  static readonly successDeep: Resource = $r('app.color.success_deep');
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
  static readonly dangerDeep: Resource = $r('app.color.danger_deep');
  static readonly dangerBg: Resource = $r('app.color.danger_bg');
  static readonly dangerBorder: Resource = $r('app.color.danger_border');
  static readonly warn: Resource = $r('app.color.warn_orange');
  /** OCR/相册入口等非品牌色按钮：糖果化后要的是"同色深一档的下沿"，故各自配一条 deep。 */
  static readonly info: Resource = $r('app.color.info_blue');
  static readonly infoDeep: Resource = $r('app.color.info_deep');
  static readonly accent: Resource = $r('app.color.accent_purple');
  static readonly accentDeep: Resource = $r('app.color.accent_deep');

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
  static readonly radiusHero: Resource = $r('app.float.radius_hero');
  static readonly radiusHeroCut: Resource = $r('app.float.radius_hero_cut');
  static readonly radiusSheet: Resource = $r('app.float.radius_sheet');
  static readonly radiusInput: Resource = $r('app.float.radius_input');
  static readonly radiusPill: Resource = $r('app.float.radius_pill');
  static readonly hitMin: Resource = $r('app.float.hit_min');

  // ---- 玻璃层几何：1vp 描边 + 大半径低透明环境阴影，圆角仍复用 radius* ----
  static readonly glassBorderWidth: number = 1;
  static readonly glassShadowRadius: number = 34;
  static readonly glassShadowOffsetY: number = 14;

  // ---- 字体族：展示位与正文同一条圆体链，标题靠字重立形（视觉方向 01 的衬线角色已退役） ----
  // 两个名字分开的理由：若将来接入只覆盖数字与拉丁的圆体展示字，只改 fontRound 一处。
  static readonly fontRound: string = 'HarmonyOS Sans SC, PingFang SC, sans-serif';
  static readonly fontSans: string = 'HarmonyOS Sans SC, PingFang SC, sans-serif';

  // ---- 动效：easing 固定，时长分标准与减少动效两档 ----
  // 本 SDK 的 curves.cubicBezier 已 deprecated 且返回字符串，直接用 CSS 形式描述同一条曲线。
  // y 控制点 >1 即"过冲"，对应原型的 --spring；ArkUI 按字符串解析，时长仍由 motion* 决定。
  static readonly curve: string = 'cubic-bezier(0.34, 1.36, 0.64, 1)';

  static readonly motionPage: number = 700;
  static readonly motionItem: number = 550;
  static readonly motionFade: number = 350;
  static readonly motionPress: number = 150;
  /** 玻璃层进入/选中态迁移：150–220ms，只做透明度与轻微位移。 */
  static readonly motionGlassEnter: number = 200;
  static readonly pressScale: number = 0.98;
  /** 底栏单项按压力度比卡片大一档：小东西要按得出来。 */
  static readonly dockPressScale: number = 0.92;
  /** 果冻厚底：常态 3vp 硬边，按下塌到 1vp 并整体下沉 2vp（对应原型 .btn:active）。 */
  static readonly jellyDepth: number = 3;
  /** 芯片比主按钮小一档：CSS `0 2px 0 深色`。 */
  static readonly jellyDepthChip: number = 2;
  static readonly jellyDepthPressed: number = 1;
  static readonly jellySink: number = 2;
  /** 正文卡与 hero 卡的柔光投影：CSS `0 12px 26px` / `0 16px 32px` 的 ArkUI 写法。 */
  static readonly cardShadowRadius: number = 26;
  static readonly cardShadowOffsetY: number = 12;
  static readonly heroShadowRadius: number = 32;
  static readonly heroShadowOffsetY: number = 16;

  /**
   * 气氛背景漂移周期（ms）与幅度（vp）：规范只允许 8–16 秒、2–6vp 的极轻漂移，
   * 默认关闭，由 AmbientScene 的 drift 入参显式打开；减少动效时强制为 0。
   */
  static readonly motionSceneShift: number = 12000;
  static readonly sceneDriftVp: number = 4;
  /** 入场位移（vp）与列表错峰步进（ms）。 */
  static readonly enterOffset: number = 14;
  static readonly staggerStep: number = 45;

  /** 卡片默认错角 10/26/26/26；偶数卡把切角换到右上，形成 26/10/26/26。 */
  static cardRadius(cutTopLeft: boolean): BorderRadiuses {
    const cut: Resource = DesignTokens.radiusCardCut;
    const round: Resource = DesignTokens.radiusCard;
    if (cutTopLeft) {
      return { topLeft: cut, topRight: round, bottomLeft: round, bottomRight: round };
    }
    return { topLeft: round, topRight: cut, bottomLeft: round, bottomRight: round };
  }

  /** 周历糖块：10/10/10/4，右下角收成尖，一列块叠起来才有节奏（原型 .cblk）。 */
  static blockRadius(): BorderRadiuses {
    const round: Resource = DesignTokens.radiusCardCut;
    return { topLeft: round, topRight: round, bottomLeft: round, bottomRight: 4 };
  }

  /** 主结果卡（hero）比正文卡大一档：16/30/30/30。 */
  static heroRadius(): BorderRadiuses {
    return {
      topLeft: DesignTokens.radiusHeroCut,
      topRight: DesignTokens.radiusHero,
      bottomLeft: DesignTokens.radiusHero,
      bottomRight: DesignTokens.radiusHero
    };
  }

  /**
   * 果冻厚底：把 blur 压到 0，阴影就退化成贴在下沿的一整条硬边，对应原型的 `0 3px 0 深色`。
   * 按下态由调用方改 offsetY 实现下沉，不动几何高度。
   */
  static jelly(color: Resource, depth: number): ShadowOptions {
    return { radius: 0, type: ShadowType.COLOR, color: color, offsetX: 0, offsetY: depth };
  }

  /** 正文卡的落影：CSS `0 12px 26px var(--shadow_card)`，深色模式下 shadowSoft 自带 0 alpha。 */
  static cardShadow(): ShadowOptions {
    return {
      radius: DesignTokens.cardShadowRadius,
      color: DesignTokens.shadowSoft,
      offsetX: 0,
      offsetY: DesignTokens.cardShadowOffsetY
    };
  }

  /** 浮在页面上的小白块（日期印章、浮岛底栏）：CSS `0 8px 18px`，比卡片轻一档。 */
  static floatShadow(): ShadowOptions {
    return { radius: 18, color: DesignTokens.shadowSoft, offsetX: 0, offsetY: 8 };
  }

  /**
   * 半模态的面：顶部一档亮暖白向下并回页面色（原型 .sheet 的竖向渐变）。
   * 系统 sheet 的 backgroundColor 只吃单色，所以渐变画在 sheet 自己的根容器上。
   */
  static sheetGradient(): LinearGradientOptions {
    return { angle: 180, colors: [[DesignTokens.sheetTop, 0], [DesignTokens.page, 1]] };
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

  static chipFontSize(): LengthMetrics {
    return LengthMetrics.resource(DesignTokens.fontCaption);
  }

  static chipRadius(): LengthMetrics {
    return LengthMetrics.resource(DesignTokens.radiusPill);
  }
}
