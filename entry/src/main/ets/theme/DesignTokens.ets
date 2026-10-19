import { ColorMetrics, LengthMetrics } from '@kit.ArkUI';
import { SwatchInk } from 'commons';

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
  /** 页面竖向渐变的三档（原型 #screen）：浅色是暖白的一口回甘，深色是顶部亮紫、底部沉黑。 */
  static readonly pageGradTop: Resource = $r('app.color.page_grad_top');
  /** 保留页头底色的 RGB，只把 alpha 归零，避免透明黑参与渐变插值。 */
  static readonly pageGradClear: Resource = $r('app.color.page_grad_clear');
  static readonly pageGradMid: Resource = $r('app.color.page_grad_mid');
  static readonly pageGradBottom: Resource = $r('app.color.page_grad_bottom');
  static readonly card: Resource = $r('app.color.card_bg');
  static readonly primary: Resource = $r('app.color.brand_pink');
  /** 厚底色：果冻按钮/芯片下沿那 3vp 硬边，永远比 primary 深一档。 */
  static readonly primaryDeep: Resource = $r('app.color.brand_pink_deep');
  /** 进度条填充的浅端：从这档走到 primary，条子才有"糖砂"的渐变。 */
  static readonly primaryLight: Resource = $r('app.color.brand_pink_light');
  static readonly primaryBg: Resource = $r('app.color.brand_pink_bg');
  static readonly shareSelectedBg: Resource = $r('app.color.share_selected_bg');
  static readonly primaryBorder: Resource = $r('app.color.brand_pink_border');
  static readonly hero: Resource = $r('app.color.hero_bg');
  static readonly heroText: Resource = $r('app.color.hero_fg');
  static readonly heroGlow: Resource = $r('app.color.hero_glow');
  /**
   * 卡片顶沿那条 1vp 内高光（原型 .card 的 `inset 0 1px 0 rgba(255,255,255,.65)`，
   * 深色覆盖 `:226` 是 .045；ArkUI 没有 inset box-shadow，走描边的上边一段）。
   */
  static readonly cardSheen: Resource = $r('app.color.card_sheen');
  /** Hero 的同一条高光，原型 `.hero` 是 .35 且深色档没有覆盖规则，所以两档同值。 */
  static readonly heroSheen: Resource = $r('app.color.hero_sheen');
  /** Hero 斜向渐变的两个端点（粉→珊瑚），中间一档用 primary。 */
  static readonly sunsetFrom: Resource = $r('app.color.sunset_from');
  static readonly sunsetTo: Resource = $r('app.color.sunset_to');
  static readonly shadowSoft: Resource = $r('app.color.shadow_soft');
  /** 品牌粉 20% 光：Hero 投影与底栏选中图标的落影（原型 --glow）。 */
  static readonly glow: Resource = $r('app.color.glow_pink');
  static readonly focusRing: Resource = $r('app.color.focus_ring');


  // ---- 交互玻璃层：strong=悬浮底栏与 Sheet，soft=首页唯一主结果（深莓底） ----
  static readonly glassStrong: Resource = $r('app.color.glass_strong');
  static readonly glassSoft: Resource = $r('app.color.glass_soft');
  static readonly glassBorder: Resource = $r('app.color.glass_border');
  static readonly glassHighlight: Resource = $r('app.color.glass_highlight');
  /** 实色回退底：系统材质不可用或算力不足时的近实色（92%–96% 暖白）。 */
  static readonly glassFallback: Resource = $r('app.color.glass_fallback');
  static readonly glassShadow: Resource = $r('app.color.glass_shadow');
  /**
   * 半模态背后那层暗化（原型 .scrim，rgba(74,36,54,.42)）：接 SheetOptions.maskColor。
   * 深浅两档同值——原型 02 的 .scrim 就是一条不带主题前缀的规则，本来也不分档。
   */
  static readonly scrim: Resource = $r('app.color.scrim');
  /**
   * 确认框背后那层暗化（原型 .dlgwrap，rgba(74,36,54,.48)）：接 BaseDialogOptions.maskColor。
   * 比 .scrim 深一档、且不分深浅档，理由同 scrim——02 里它也是一条不带主题前缀的规则。
   * 这层只有换成 openCustomDialog(ComponentContent) 才接得上：showAlertDialog 的
   * AlertDialogParam 只有 maskRect（遮罩范围）没有 maskColor（遮罩颜色），
   * 所以全仓十处确认框走 util/AppConfirm.ets 的 askConfirm()。
   */
  static readonly dlgScrim: Resource = $r('app.color.dlg_scrim');

  // ---- Dock 光感粒子（原型 .dock-fx）----
  /** 光池：原型只在深色主题画（`.dock-glow` 浅色被 `display:none`），所以浅色档做成全透明。 */
  static readonly dockGlowPool: Resource = $r('app.color.dock_glow_pool');
  static readonly sparkBlush: Resource = $r('app.color.spark_blush');
  static readonly sparkAmber: Resource = $r('app.color.spark_amber');
  static readonly sparkLilac: Resource = $r('app.color.spark_lilac');
  static readonly sparkPink: Resource = $r('app.color.spark_pink');
  static readonly sparkWhite: Resource = $r('app.color.spark_white');
  static readonly sparkHeart: Resource = $r('app.color.spark_heart');

  // ---- 文本 ----
  static readonly textPrimary: Resource = $r('app.color.text_primary');
  static readonly textSecondary: Resource = $r('app.color.text_secondary');
  static readonly textTertiary: Resource = $r('app.color.text_tertiary');
  static readonly textHint: Resource = $r('app.color.text_hint');
  /** 浅色卡片上的强调小字改用深墨；深色底保留品牌粉。不要改变背景/装饰用的 primary。 */
  static readonly textAccent: Resource = $r('app.color.text_accent');
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
  /** 仅用于创建成功按钮，保持绿色确认且让暖白小字达到 4.5:1。 */
  static readonly successAction: Resource = $r('app.color.plan_success_action');
  static readonly planSurface: Resource = $r('app.color.plan_surface');
  static readonly planAccent: Resource = $r('app.color.plan_accent');
  static readonly planInk: Resource = $r('app.color.plan_ink');
  static readonly planMuted: Resource = $r('app.color.plan_muted');
  static readonly drawerCalendarBg: Resource = $r('app.color.drawer_calendar_bg');
  static readonly drawerCalendarInk: Resource = $r('app.color.drawer_calendar_ink');
  static readonly drawerCancelBg: Resource = $r('app.color.drawer_cancel_bg');
  static readonly drawerCancelInk: Resource = $r('app.color.drawer_cancel_ink');
  /** 双方忙碌标识色：我=淡蓝 #A9C4F5，TA=琥珀 #FFC970（今日概览的圆点，与周视图同一套色）。
   *  深色档故意不另写值：02 的深色块没有覆盖这两个，原型里它们是从 01 深色块漏下来的
   *  #91A7A8/#C7A777（getComputedStyle 实测），跟 02 的紫调深色不是一套语言。 */
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

  /**
   * 用户自选色块（班次的底色）那一族。
   *
   * `swatchFg` 是压在**亮**色块上的深墨，base 与 dark 两套 color.json 里同值（`#5C4750`，取自浅色档
   * `text_primary`，不是新发明的色）——刻意不做深浅色覆盖，因为底色是用户挑的、不会随模式翻面；
   * 用会翻面的 `text_secondary` 反而在深色档把浅紫压到浅灰上，实测只有 1.11:1。
   * `swatchRest`／`swatchUnknown` 是"休"与"这个班次 id 认不出来"两块的底色，只在这里写一次：
   * 先前 `CycleEditor` 与 `PaintMonth` 各抄了一份同样的十六进制串，改一处忘另一处就靠字符串相等来判"是不是休"。
   */
  static readonly swatchFg: Resource = $r('app.color.swatch_fg');
  static readonly swatchRest: string = '#B8C4CE';
  static readonly swatchUnknown: string = '#CCCCCC';

  /**
   * 色块上该用哪个前景：暖白还是深墨。判据是这块色本身的 WCAG 对比度（`commons` 的 `SwatchInk`），
   * 不是深浅色模式——数学式与两条边界（相等留暖白、认不出的串留暖白）都在 SwatchInk 里，
   * 离线用例逐色钉住，改八色或改阈值时会先在那里红。
   *
   * 只给**用户选的颜色**用。品牌粉那一族不许走这里：原型 `.chip.on` 写的是 `background:brand_pink;color:#fff`，
   * 由对比度自动判会把品牌粉上的白字翻成深墨，那是改外观不是修可读性。
   * 形参收 `ResourceColor` 是因为班次色在页面上常以 `ResourceColor` 流动（如 `DayShiftSheet.chipBg`）：
   * 传进来的是 `$r(...)` 而非十六进制串时判不出，按边界落回暖白——token 底本就不归这里管。
   */
  static foregroundOn(color: ResourceColor): Resource {
    return (typeof color === 'string' && SwatchInk.prefersInk(color))
      ? DesignTokens.swatchFg : DesignTokens.heroText;
  }

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
  /** 语气符号徽标（! / ↻）：原型 .conflict-mark 收成 10vp 小糖块，比卡片切角还小一档。 */
  static readonly markRadius: number = 10;
  /** 冲突提示条比正文卡收一档、且不留切角：原型 .conflict-card 的 22px。 */
  static readonly conflictRadius: number = 22;
  /**
   * 悬浮底栏的滚动净空：岛高 52 + 底部留白 10 = 62，末屏内容要能整体升到岛上面。
   * 导航指示器那 28vp 不用算：Navigation 的内容区本身就止于指示器之上（实测内容 Stack 底边 2782 = 屏底 - 28vp）。
   */
  static readonly dockClearance: number = 72;

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
  /**
   * 自制芯片／胶囊／格子的按压回弹，交给系统的 `clickEffect`（按下抬起时缩一下再弹回）。
   *
   * 为什么不用 `stateStyles`：它只覆盖通用属性里的少数几个，而且**在 `@Builder` 里不生效**
   * （官方文档原话："因Builder不具备独立的自定义父节点"），本仓多数芯片恰恰画在 builder 里。
   * 系统 `Button` 也不归这里管——它自带按压态（`stateEffect` 默认 true）。
   *
   * 两档幅度都取现成的规格，不新发明数字：
   * - 芯片 0.94 ← 原型 02 第 454 行 `.chip:active{transform:scale(.94)}`
   * - 自制按钮／整行／整卡 0.98 ← 原型 02 第 279 行 `.btn:active{transform:scale(.98)}`，
   *   与本仓 `pressScale`（`EditorialCard`／`ConfirmDialog` 自绘按压态用的幅度）同一档
   *
   * 这一族**接不进「减少动效」开关**，不是漏接：`ClickEffect` 只有 `level` 与 `scale` 两个旋钮，
   * 没有时长/曲线可调，要"关掉"只能整体传 `null`——那等于把反馈删了，不是把动效放轻。
   * 自绘的那几档（`motionPress`、心跳）仍然跟开关走。
   */
  static tapChip(): ClickEffect {
    return { level: ClickEffectLevel.LIGHT, scale: 0.94 };
  }

  static tapButton(): ClickEffect {
    return { level: ClickEffectLevel.LIGHT, scale: DesignTokens.pressScale };
  }
  /** 果冻厚底：常态 3vp 硬边，按下塌到 1vp 并整体下沉 2vp（对应原型 .btn:active）。 */
  static readonly jellyDepth: number = 3;
  /** 芯片比主按钮小一档：CSS `0 2px 0 深色`。 */
  static readonly jellyDepthChip: number = 2;
  static readonly jellyDepthPressed: number = 1;
  static readonly jellySink: number = 2;
  /**
   * 倒计时心跳：原型 `.hb` 是 1.6s 一轮的双跳，ArkUI 用 Alternate 往复表达，
   * 所以半程取 800ms、幅度取第一跳的 1.18。这是全 App 唯一的常驻动效。
   */
  static readonly beatMs: number = 800;
  static readonly beatScale: number = 1.18;
  /** 正文卡与 hero 卡的柔光投影：CSS `0 12px 26px` / `0 16px 32px` 的 ArkUI 写法。 */
  static readonly cardShadowRadius: number = 26;
  static readonly cardShadowOffsetY: number = 12;
  static readonly heroShadowRadius: number = 32;
  static readonly heroShadowOffsetY: number = 16;

  /**
   * 入场位移（vp）：EditorialCard / ConflictNotice 的淡入起点，接在 reduce-motion 开关下。
   * staggerStep 是原型 .screen-enter 的错峰步进（55/100/145ms），**故意没有接上页面**：
   * 错峰只在整页首次挂载时看得见，而 dumpLayout 与截图都拍不到时间轴，
   * 无法验收就无法断言它没有把首屏拖慢——等有了逐帧取证的手段再接。
   */
  static readonly enterOffset: number = 14;
  static readonly staggerStep: number = 45;

  /**
   * 卡片切角两档：默认 28/28/28/14 把尖收在左下（原型 .card），
   * cutTopLeft 给出 14/28/28/28 的镜像档，让相邻卡片一左一右错开（.card:nth-of-type(even)）。
   */
  static cardRadius(cutTopLeft: boolean): BorderRadiuses {
    const cut: Resource = DesignTokens.radiusCardCut;
    const round: Resource = DesignTokens.radiusCard;
    if (cutTopLeft) {
      return { topLeft: cut, topRight: round, bottomLeft: round, bottomRight: round };
    }
    return { topLeft: round, topRight: round, bottomLeft: cut, bottomRight: round };
  }

  /** 周历糖块：10/10/10/4，右下角收成尖，一列块叠起来才有节奏（原型 .cblk）。 */
  static blockRadius(): BorderRadiuses {
    return { topLeft: 10, topRight: 10, bottomLeft: 10, bottomRight: 4 };
  }

  /** 主结果卡（hero）比正文卡大一档，切角同样落在左下：30/30/16/30。 */
  static heroRadius(): BorderRadiuses {
    return {
      topLeft: DesignTokens.radiusHero,
      topRight: DesignTokens.radiusHero,
      bottomLeft: DesignTokens.radiusHeroCut,
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

  /**
   * 页面底：原型 #screen 的那条竖向渐变（浅色 暖白→页色，深色 亮紫→沉黑）。
   * 两档的档位在原型里本来就不重合：深色是 0/45%/100%，浅色是 0/34%/66%（末段持平）。
   * 这里按深色那一组写死，因为浅色三个端点本身重合在页色上，改用 0/45%/100% 后最大偏差
   * 落在 66% 那一屏的 G 通道上，约 4/255；深色则逐点命中。铺在页面根节点上，
   * 滚动时它不动——原型也是画在 #screen，不是画在滚动内容上。
   */
  static pageGradient(): LinearGradientOptions {
    return {
      angle: 180,
      colors: [[DesignTokens.pageGradTop, 0], [DesignTokens.pageGradMid, 0.45],
        [DesignTokens.pageGradBottom, 1]]
    };
  }

  /** 开启减少动效时时长归零：位移动画退化为直接呈现。 */
  static motion(reduceMotion: boolean, ms: number): number {
    return reduceMotion ? 0 : ms;
  }

  /** 开启减少动效时位移归零（只保留透明度也不做，见 motion）。当前零调用点：位移一律写在 transition 里。 */
  static offset(reduceMotion: boolean, vp: number): number {
    return reduceMotion ? 0 : vp;
  }

  /** 列表错峰延迟：减少动效时不错峰（Task 5.2 规则，须与 offset 同时关闭）。当前零调用点，理由见 staggerStep。 */
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
