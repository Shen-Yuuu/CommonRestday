import { router } from '@kit.ArkUI';
import { HdsTabs, HdsTabsController, hdsMaterial } from '@kit.UIDesignKit';
import { Logger } from 'commons';
import { ScheduleUseCase } from 'feature';
import { HomeView } from '../view/HomeView';
import { CoTimeView } from '../view/CoTimeView';
import { MeView } from '../view/MeView';
import { ScheduleHub } from '../view/ScheduleHub';
import { DockFx } from '../component/DockFx';
import { NavRoutes, RouteKind, RouteTarget } from './NavRoutes';
import { navParamsFrom, routeNameFromParams, takePendingRoute } from '../util/NavUtil';
import { ownerFromParams } from '../model/RouteParams';
import { DesignTokens } from '../theme/DesignTokens';
import { Breakpoints } from '../responsive/Breakpoints';

const TAG = 'AppNavigator';
/**
 * 底栏留白带高度：实测就等于悬浮岛的高度（这一值 78 时 dumpLayout 的 TabBar 节点高 273px=78vp）。
 * 原型 02 的 .tabbar 是 52 高、左右各内缩 30、底部 10，条目 flex:1（384 屏宽下每项约 103）。
 */
const BAR_BAND = 52;
/**
 * 岛宽：HdsTabs 的悬浮玻璃底板只认数值档。给它百分比会摆错位——
 * 实测 `barWidth:'84%'` 时条目容器在 [104,2565][1203,2747]，玻璃底板却在
 * origBounds [654,2565][1753,2747]：宽度对，左沿落在父宽 50% 处，正好右移半个岛宽。
 * 所以宽度自己算：容器宽 − 两侧内缩（原型 .tabbar 的 margin 左右 30），量到之前先按
 * HdsTabs 自己的手机档 236 兜底（实测默认档就是这个数，摆位正确、只是比原型窄）。
 */
const DOCK_SIDE_MARGIN = 30;
const DOCK_BAND_FALLBACK = 236;
/** 浮岛底部留白（原型 .tabbar 的 margin:-40px 30px 10px）。 */
const DOCK_BOTTOM_MARGIN = 10;
/** 岛的圆角（原型 .tabbar/.dock-fx 都是 22）：粒子层要按同一个圆角裁，边缘才不漏光。 */
const DOCK_RADIUS = 22;
/** 单项热区：原型 .t 是 flex:1（铺满岛内宽），52 高的岛上下内衬 4/6 后内容区 42；48vp 的无障碍底线由 100vp 宽天然满足。 */
const ITEM_HEIGHT = 42;
const ITEM_WIDTH = 100;

interface NavItem {
  icon: Resource;
  selectedIcon: Resource;
  text: string;
  tab: number;
}

const NAV_ITEMS: NavItem[] = [
  { icon: $r('sys.symbol.house'), selectedIcon: $r('sys.symbol.house_fill'), text: '两人份', tab: NavRoutes.TAB_HOME },
  { icon: $r('sys.symbol.heart'), selectedIcon: $r('sys.symbol.heart_fill'), text: '共同', tab: NavRoutes.TAB_COMMON_TIME },
  { icon: $r('sys.symbol.person'), selectedIcon: $r('sys.symbol.person_fill'), text: '我的', tab: NavRoutes.TAB_ME }
];

/**
 * 应用壳层：Navigation + NavPathStack 包裹三个底部 Tab。
 *
 * - Tab 只有首页/共同时间/我的，索引固定 0/1/2；班表降级为栈目的地（原型精简版口径）。
 * - 深链与广播都经 openRoute 落地：白名单外的名字直接丢弃，绝不按参数拼页面。
 * - 录入页仍是 @Entry router 页，走 ROUTER 分支；router 栈叠在 Index 之上，
 *   返回时先回栈目的地再回 Tab，返回顺序天然正确。
 */
@Component
export struct AppNavigator {
  @State private activeTab: number = NavRoutes.TAB_HOME;
  /** 当前按下的底栏单项，-1 = 没有；只影响缩放。 */
  @State private pressedTab: number = -1;
  @State private dockVisible: boolean = true;
  @StorageProp('crd_root_page_visible') private rootVisible: boolean = true;
  // 装饰器实参必须是字面量，取值与 MOTION_REDUCE_KEY 保持一致。
  @StorageProp('crd_reduce_motion') reduceMotion: boolean = false;
  // 跨 Tab 导航广播（计划页空态引导「去共同时间页」）：NavUtil.navToCoTime() 触发
  @StorageProp('navToCoTimeCount') @Watch('onNavToCoTime') navToCoTimeCount: number = 0;
  // 服务卡片点击深链广播：EntryAbility 过白名单后登记，壳层取走并落地
  @StorageProp('crdPendingRouteCount') @Watch('onPendingRoute') pendingRouteCount: number = 0;
  private pathStack: NavPathStack = new NavPathStack();
  /** 悬浮底栏由 HdsTabs 自持控制器；切页仍走 activeTab，控制器只用于组件挂载。 */
  private tabsController: HdsTabsController = new HdsTabsController();
  /** 岛宽（vp）：onAreaChange 量到容器宽之前先用兜底值，量到后一起改岛与粒子层的宽。 */
  @State private bandVp: number = DOCK_BAND_FALLBACK;
  /** 冷启动深链：aboutToAppear 时 Navigation 尚未挂载，先记下，挂载后再消费。 */
  private pendingRoute: string = '';
  private pendingRaw: Object | undefined = undefined;

  aboutToAppear(): void {
    // 卡片/Want 无参数或参数不在白名单 → pendingRoute 为空 → 停在首页
    const raw: Object | undefined = router.getParams();
    this.pendingRaw = raw;
    this.pendingRoute = routeNameFromParams(raw);
  }

  /** 应用已在运行时点卡片/页内引导：登记的请求取走即落地，名字一律按白名单解析。 */
  onPendingRoute(): void {
    const name = takePendingRoute();
    if (name !== '') {
      this.openRoute(name, undefined);
    }
  }

  onNavToCoTime(): void {
    this.goTab(NavRoutes.TAB_COMMON_TIME);
  }

  /** 挂载完成后消费冷启动深链：页内参数优先，卡片登记的那条一并清空，一次拉起只跳一次。 */
  private consumePending(): void {    const stored = takePendingRoute();
    const name = this.pendingRoute !== '' ? this.pendingRoute : stored;
    this.pendingRoute = '';
    if (name === '') {
      return;
    }
    this.openRoute(name, this.pendingRaw);
  }

  /** 唯一导航入口：白名单查表后按落地方式分发。 */
  openRoute(name: string, raw: Object | undefined): void {
    const target: RouteTarget | null = NavRoutes.resolve(name);
    if (target == null) {
      Logger.warn(TAG, 'unknown route ignored: ' + name);
      return;
    }
    if (target.kind === RouteKind.TAB) {
      this.goTab(target.tab);
      return;
    }
    if (target.kind === RouteKind.NOT_READY) {
      // 页面还没建（配对页在阶段 3，隐私页在其后）：先落到承载它们的「我的」Tab
      Logger.warn(TAG, 'route not built yet, fall back to me: ' + name);
      this.goTab(target.tab);
      return;
    }
    const params = navParamsFrom(raw);
    if (target.kind === RouteKind.ROUTER) {
      router.pushUrl({ url: target.url, params: params });
      return;
    }
    this.pathStack.pushPathByName(name, params);
  }

  private goTab(tab: number): void {
    // 先回到根再切索引：栈顶还盖着班表页时，只切 Tab 用户看不到任何变化
    if (this.pathStack.size() > 0) {
      this.pathStack.clear();
    }
    this.activeTab = tab;
  }

  /** 内容切换直接落地，动画只留在被按下的条目上。 */
  private selectTab(tab: number): void {
    if (this.activeTab === tab) {
      return;
    }
    this.goTab(tab);
  }

  /** 单项按压反馈：只画 0.92 缩放，抬起即回弹，不参与切换与导航逻辑。 */
  private pressTab(tab: number, down: boolean): void {
    this.pressedTab = down ? tab : -1;
  }

  /**
   * 量宽：容器宽减去原型那 30vp 的两侧内缩就是岛宽。写回前先比一次，同宽不写状态，
   * 免得「写入→重排→再写入」转成布局回环（与 ResponsiveContainer 的幂等口径同一个写法）。
   */
  private measureBand(area: Area): void {
    const w: number = Breakpoints.widthOf(area) - DOCK_SIDE_MARGIN * 2;
    if (w > 0 && Math.abs(w - this.bandVp) > 0.5) {
      this.bandVp = w;
    }
  }

  build() {
    Navigation(this.pathStack) {
      // 光感粒子层要精确压在悬浮岛上，所以岛和它放进同一个 Stack：Stack 是 Navigation 的内容，
      // push 班表页时整块内容一起被 NavDestination 盖掉，粒子不会浮到子页上。
      Stack({ alignContent: Alignment.BottomStart }) {
        HdsTabs({ controller: this.tabsController, index: this.activeTab }) {
          TabContent() {
            // 首页要打开班表/配对：路由种类只有壳层知道，页面只报名字
            HomeView({
              active: this.activeTab === NavRoutes.TAB_HOME && this.dockVisible && this.rootVisible,
              onOpenRoute: (name: string): void => {
                this.openRoute(name, undefined);
              }
            })
          }
          .tabBar(this.tabBarItem(NavRoutes.TAB_HOME))

          TabContent() {
            // 空态引导要去班表/配对：同首页，页面只报名字，路由种类只有壳层知道
            CoTimeView({
              active: this.activeTab === NavRoutes.TAB_COMMON_TIME && this.dockVisible && this.rootVisible,
              onOpenRoute: (name: string): void => {
                this.openRoute(name, undefined);
              }
            })
          }
          .tabBar(this.tabBarItem(NavRoutes.TAB_COMMON_TIME))

          TabContent() {
            // 「我的日程」要开班表页并指定录哪一侧：路由种类只有壳层知道，页面只报名字与 owner
            MeView({
              active: this.activeTab === NavRoutes.TAB_ME && this.dockVisible && this.rootVisible,
              onOpenRoute: (name: string, params?: Object): void => {
                this.openRoute(name, params);
              }
            })
          }
          .tabBar(this.tabBarItem(NavRoutes.TAB_ME))
        }
        .width('100%')
        .height('100%')
        .vertical(false)
        .barPosition(BarPosition.End)
        // 悬浮样式的第一条约束：页签栏要叠在内容之上，系统才会画那层悬浮背板；
        // 不打开时只有整条 band 的底色，岛本身什么都不画（官方「设置页签栏的悬浮样式」约束条件）。
        .barOverlap(true)
        .scrollable(false)
        .animationDuration(0)
        .barHeight(BAR_BAND)
        // 悬浮底栏 + 沉浸光感材质（API 23 起）：岛的面与模糊交给系统，应用侧不再自绘玻璃
        .barFloatingStyle({
          barWidth: { smallWidth: this.bandVp, mediumWidth: this.bandVp, largeWidth: this.bandVp },
          barBottomMargin: DOCK_BOTTOM_MARGIN,
          // 背板蒙层必须留着并显式给全透明色：删掉这行会回落系统默认 #66F1F3F5（深色 #33000000），
          // 而它按整条页签栏宽铺开、高度约 96vp，四周都比悬浮岛（52vp 高、两侧各内缩 30vp）大一圈。
          gradientMask: { maskColor: $r('app.color.dock_mask') },
          systemMaterialEffect: {
            materialType: hdsMaterial.MaterialType.IMMERSIVE,
            materialLevel: hdsMaterial.MaterialLevel.ADAPTIVE
          }
        })
        .onChange((idx: number) => {
          this.activeTab = idx;
          // 切页就是一次「重进」：看不见的那几分钟钟是不走的，切回来要重取值（K-4③）
          ScheduleUseCase.notifyClockTick();
        })

        DockFx({
          bandWidth: this.bandVp,
          active: this.dockVisible,
          bottom: DOCK_BOTTOM_MARGIN,
          bandHeight: BAR_BAND,
          radius: DOCK_RADIUS
        })
      }
      .width('100%')
      .height('100%')
      .onAreaChange((_oldValue: Area, newValue: Area) => {
        this.measureBand(newValue);
      })
    }
    .hideTitleBar(true)
    .mode(NavigationMode.Stack)
    .navDestination(this.destinationBuilder)
    .onNavBarStateChange((shown: boolean) => {
      this.dockVisible = shown;
    })
    .onAppear(() => {
      this.consumePending();
    })
    .width('100%')
    .height('100%')
    .linearGradient(DesignTokens.pageGradient())
    .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP, SafeAreaEdge.BOTTOM])
  }

  /**
   * 栈目的地映射。班表页自带标题与滚动，用系统标题栏会重复，因此隐藏标题栏；
   * 出口由页首那颗可见返回键承担（pop 只有握着 NavPathStack 的壳层能调，故注入下去）。
   * owner 由 pushPathByName 的参数带下来：入口只落「我」这侧，TA 侧在页内分段上切。
   */
  @Builder
  destinationBuilder(name: string, param: Object) {
    if (name === NavRoutes.SCHEDULE_HUB) {
      NavDestination() {
        ScheduleHub({
          initialOwner: ownerFromParams(param),
          onBack: (): void => {
            this.pathStack.pop();
          }
        })
      }
      .hideTitleBar(true)
      .linearGradient(DesignTokens.pageGradient())
      .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP, SafeAreaEdge.BOTTOM])
      // 进出班表页各看一次钟：被它盖住的 Tab 页（以及从录入页返回后的自己）都没有别的重进信号（K-4③）
      .onShown(() => {
        ScheduleUseCase.notifyClockTick();
      })
      .onHidden(() => {
        ScheduleUseCase.notifyClockTick();
      })
    }
  }

  /**
   * 底栏单项：岛的面（材质/描边/阴影）由系统悬浮条画，这里只给图标 + 文字 + 选中底色。
   * tab 就是 NAV_ITEMS 的下标，也是 TabContent 的索引，三处口径同一个数。
   */
  @Builder
  tabBarItem(tab: number) {
    this.navItem(NAV_ITEMS[tab])
  }

  @Builder
  navItem(item: NavItem) {
    Column({ space: 2 }) {
      SymbolGlyph(this.activeTab === item.tab ? item.selectedIcon : item.icon)
        .fontSize(22)
        .fontColor([this.activeTab === item.tab ? $r('app.color.brand_pink') : $r('app.color.text_secondary')])
        // 选中那颗图标浮起来一点（原型 .t.on svg 的 drop-shadow），未选中的不画
        .shadow(this.activeTab === item.tab
          ? { radius: 6, color: DesignTokens.glow, offsetX: 0, offsetY: 3 }
          : undefined)
        // 图标下面就是文字标签，读屏念两遍反而挡路
        .accessibilityLevel('no')
      Text(item.text)
        .fontSize(11)
        .fontColor(this.activeTab === item.tab ? $r('app.color.text_accent') : $r('app.color.text_secondary'))
        .fontWeight(this.activeTab === item.tab ? FontWeight.Bolder : FontWeight.Bold)
    }
    // 选中态用浅莓实心底标出，不只靠玻璃色差：状态要有底色/字重双重提示
    .width(ITEM_WIDTH)
    .height(ITEM_HEIGHT)
    .justifyContent(FlexAlign.Center)
    .alignItems(HorizontalAlign.Center)
    .borderRadius(DesignTokens.radiusPill)
    .scale(this.pressedTab === item.tab
      ? { x: DesignTokens.dockPressScale, y: DesignTokens.dockPressScale }
      : { x: 1, y: 1 })
    .animation({ duration: DesignTokens.motion(this.reduceMotion, DesignTokens.motionPress), curve: DesignTokens.curve })
    .backgroundColor(this.activeTab === item.tab ? $r('app.color.brand_pink_bg') : Color.Transparent)
    .hoverEffect(HoverEffect.None)
    .focusable(true)
    .accessibilityGroup(true)
    // 底色/字重是视觉信号，读屏要把"你在哪一页、按了会去哪一页"念出来
    .accessibilityText(this.activeTab === item.tab
      ? item.text + '，当前所在页'
      : '切换到' + item.text + '页')
    .onTouch((e: TouchEvent) => {
      // 条目自己承担按压，防止父级系统页签再叠一次反馈。
      e.stopPropagation();
      if (e.type === TouchType.Down) {
        this.pressTab(item.tab, true);
      } else if (e.type === TouchType.Up || e.type === TouchType.Cancel) {
        this.pressTab(item.tab, false);
      }
    })
    .onClick(() => {
      this.selectTab(item.tab);
    })
  }
}
