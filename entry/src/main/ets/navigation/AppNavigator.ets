import { router } from '@kit.ArkUI';
import { Logger } from 'commons';
import { PairingShareGateway } from 'feature';
import { HomeView } from '../view/HomeView';
import { CoTimeView } from '../view/CoTimeView';
import { MeView } from '../view/MeView';
import { ScheduleHub } from '../view/ScheduleHub';
import { NavRoutes, RouteKind, RouteTarget } from './NavRoutes';
import { navParamsFrom, routeNameFromParams, takePendingRoute } from '../util/NavUtil';
import { ownerFromParams } from '../model/RouteParams';
import { DesignTokens } from '../theme/DesignTokens';
import { GlassStrength } from '../theme/MaterialPolicy';
import { GlassSurface } from '../component/GlassSurface';

const TAG = 'AppNavigator';
/**
 * 底栏留白带高度：系统条收成透明后仍占这一段，浮岛画在它里面。
 * 用留白带而不是让浮岛盖住内容，三个 Tab 页面就不必各自补底部内边距。
 */
const BAR_BAND = 78;
/** 浮岛高度与单项热区：热区不小于 48vp，不用视觉胶囊大小代替真实热区。 */
const ISLAND_HEIGHT = 58;
const ITEM_HEIGHT = 50;
const ITEM_WIDTH = 74;

interface NavItem {
  icon: Resource;
  text: string;
  tab: number;
}

const NAV_ITEMS: NavItem[] = [
  { icon: $r('sys.symbol.house'), text: '同休', tab: NavRoutes.TAB_HOME },
  { icon: $r('sys.symbol.heart'), text: '共同', tab: NavRoutes.TAB_COMMON_TIME },
  { icon: $r('sys.symbol.person'), text: '我的', tab: NavRoutes.TAB_ME }
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
  // 装饰器实参必须是字面量，取值与 MOTION_REDUCE_KEY 保持一致。
  @StorageProp('crd_reduce_motion') reduceMotion: boolean = false;
  // 跨 Tab 导航广播（计划页空态引导「去共同时间页」）：NavUtil.navToCoTime() 触发
  @StorageProp('navToCoTimeCount') @Watch('onNavToCoTime') navToCoTimeCount: number = 0;
  // 配对请求到达广播：确认页在「我的 · 伴侣与同步」里，先把人带到那一页。
  // 写入方在 feature 模块（依赖方向反过来，够不到 entry 的 NavUtil），故不走 pending route
  @StorageProp('pairOfferCount') @Watch('onPairOffer') pairOfferCount: number = 0;
  // 服务卡片点击深链广播：EntryAbility 过白名单后登记，壳层取走并落地
  @StorageProp('crdPendingRouteCount') @Watch('onPendingRoute') pendingRouteCount: number = 0;
  private pathStack: NavPathStack = new NavPathStack();
  /** 冷启动深链：aboutToAppear 时 Navigation 尚未挂载，先记下，挂载后再消费。 */
  private pendingRoute: string = '';
  private pendingRaw: Object | undefined = undefined;

  aboutToAppear(): void {
    // 卡片/Want 无参数或参数不在白名单 → pendingRoute 为空 → 停在首页
    const raw: Object | undefined = router.getParams();
    this.pendingRaw = raw;
    this.pendingRoute = routeNameFromParams(raw);
    // 冷启动深链的配对请求比本页早到（EntryAbility 就收下了）：没有别的导航意图时落到「我的」
    if (this.pendingRoute === '' && PairingShareGateway.peekOffer() !== null) {
      this.activeTab = NavRoutes.TAB_ME;
    }
  }

  onPairOffer(): void {
    this.goTab(NavRoutes.TAB_ME);
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
  private consumePending(): void {
    const stored = takePendingRoute();
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

  /** 选中态只做透明度/底色迁移（150–220ms），减少动效时归零，不延迟内容切换。 */
  private selectTab(tab: number): void {
    if (this.activeTab === tab) {
      return;
    }
    this.getUIContext().animateTo({
      duration: DesignTokens.motion(this.reduceMotion, DesignTokens.motionGlassEnter),
      curve: DesignTokens.curve
    }, () => {
      this.goTab(tab);
    });
  }

  build() {
    Navigation(this.pathStack) {
      Stack({ alignContent: Alignment.Bottom }) {
        Tabs({ barPosition: BarPosition.End, index: this.activeTab }) {
          TabContent() {
            // 首页要打开班表/配对：路由种类只有壳层知道，页面只报名字
            HomeView({
              onOpenRoute: (name: string): void => {
                this.openRoute(name, undefined);
              }
            })
          }
          .tabBar(this.hiddenBar())

          TabContent() {
            // 空态引导要去班表/配对：同首页，页面只报名字，路由种类只有壳层知道
            CoTimeView({
              onOpenRoute: (name: string): void => {
                this.openRoute(name, undefined);
              }
            })
          }
          .tabBar(this.hiddenBar())

          TabContent() {
            // 「我的日程」要开班表页并指定录哪一侧：路由种类只有壳层知道，页面只报名字与 owner
            MeView({
              onOpenRoute: (name: string, params?: Object): void => {
                this.openRoute(name, params);
              }
            })
          }
          .tabBar(this.hiddenBar())
        }
        .scrollable(false)
        .barHeight(BAR_BAND)
        .barBackgroundColor(Color.Transparent)
        .onChange((idx: number) => {
          this.activeTab = idx;
        })

        this.navIsland()
      }
      .width('100%')
      .height('100%')
    }
    .hideTitleBar(true)
    .mode(NavigationMode.Stack)
    .navDestination(this.destinationBuilder)
    .onAppear(() => {
      this.consumePending();
    })
    .width('100%')
    .height('100%')
    .backgroundColor($r('app.color.page_bg_warm'))
  }

  /**
   * 栈目的地映射。班表页自带标题与滚动，用系统标题栏会重复，因此隐藏标题栏；
   * 出口由页首那颗可见返回键承担（pop 只有握着 NavPathStack 的壳层能调，故注入下去）。
   * owner 由 pushPathByName 的参数带下来：从「我的 · 代录 TA 的班表」进入时直接落在 TA 侧。
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
      .backgroundColor($r('app.color.page_bg_warm'))
    }
  }

  /** 系统条收成透明占位：真正的控件是下面的浮岛，避免两处底栏同时可点。 */
  @Builder
  hiddenBar() {
    Column()
      .width('100%')
      .height(0)
  }

  /** 悬浮底栏：与左右和底部安全区留出呼吸空间，材质不可用时退化为近实色暖白。 */
  @Builder
  navIsland() {
    // 自定义组件不吃链式属性，留白与热区由外层 Column 承担
    Column() {
      GlassSurface({ strength: GlassStrength.STRONG, radius: DesignTokens.radiusPill }) {
        Row() {
          ForEach(NAV_ITEMS, (item: NavItem) => {
            this.navItem(item)
          }, (item: NavItem) => '' + item.tab)
        }
        .height(ISLAND_HEIGHT)
        .width('100%')
        .justifyContent(FlexAlign.SpaceEvenly)
      }
    }
    .width('100%')
    .margin({
      left: DesignTokens.space4,
      right: DesignTokens.space4,
      bottom: DesignTokens.space3
    })
  }

  @Builder
  navItem(item: NavItem) {
    Column({ space: 2 }) {
      SymbolGlyph(item.icon)
        .fontSize(22)
        .fontColor([this.activeTab === item.tab ? $r('app.color.brand_pink') : $r('app.color.text_secondary')])
        // 图标下面就是文字标签，读屏念两遍反而挡路
        .accessibilityLevel('no')
      Text(item.text)
        .fontSize(11)
        .fontColor(this.activeTab === item.tab ? $r('app.color.brand_pink') : $r('app.color.text_secondary'))
        .fontWeight(this.activeTab === item.tab ? FontWeight.Bold : FontWeight.Normal)
    }
    // 选中态用浅莓实心底标出，不只靠玻璃色差：状态要有底色/字重双重提示
    .width(ITEM_WIDTH)
    .height(ITEM_HEIGHT)
    .justifyContent(FlexAlign.Center)
    .alignItems(HorizontalAlign.Center)
    .borderRadius(DesignTokens.radiusPill)
    .backgroundColor(this.activeTab === item.tab ? $r('app.color.brand_pink_bg') : Color.Transparent)
    .focusable(true)
    .accessibilityGroup(true)
    // 底色/字重是视觉信号，读屏要把"你在哪一页、按了会去哪一页"念出来
    .accessibilityText(this.activeTab === item.tab
      ? item.text + '，当前所在页'
      : '切换到' + item.text + '页')
    .onClick(() => {
      this.selectTab(item.tab);
    })
  }
}
