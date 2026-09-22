import { router } from '@kit.ArkUI';
import { Logger } from 'commons';
import { HomeView } from '../view/HomeView';
import { CoTimeView } from '../view/CoTimeView';
import { MeView } from '../view/MeView';
import { ScheduleHub } from '../view/ScheduleHub';
import { NavRoutes, RouteKind, RouteTarget } from './NavRoutes';
import { navParamsFrom, routeNameFromParams } from '../util/NavUtil';

const TAG = 'AppNavigator';

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
  // 跨 Tab 导航广播（「去添加伴侣」等入口）：NavUtil.navToMe() 触发
  @StorageProp('navToMeCount') @Watch('onNavToMe') navToMeCount: number = 0;
  // 跨 Tab 导航广播（计划页空态引导「去共同时间页」）：NavUtil.navToCoTime() 触发
  @StorageProp('navToCoTimeCount') @Watch('onNavToCoTime') navToCoTimeCount: number = 0;
  private pathStack: NavPathStack = new NavPathStack();
  /** 冷启动深链：aboutToAppear 时 Navigation 尚未挂载，先记下，挂载后再消费。 */
  private pendingRoute: string = '';
  private pendingRaw: Object | undefined = undefined;

  aboutToAppear(): void {
    // 卡片/Want 无参数或参数不在白名单 → pendingRoute 为空 → 停在首页
    const raw: Object | undefined = router.getParams();
    this.pendingRaw = raw;
    this.pendingRoute = routeNameFromParams(raw);
  }

  onNavToMe(): void {
    this.goTab(NavRoutes.TAB_ME);
  }

  onNavToCoTime(): void {
    this.goTab(NavRoutes.TAB_COMMON_TIME);
  }

  private consumePending(): void {
    const name = this.pendingRoute;
    if (name === '') {
      return;
    }
    this.pendingRoute = '';
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

  build() {
    Navigation(this.pathStack) {
      Tabs({ barPosition: BarPosition.End, index: this.activeTab }) {
        TabContent() {
          // 首页要打开班表/配对：路由种类只有壳层知道，页面只报名字
          HomeView({
            onOpenRoute: (name: string): void => {
              this.openRoute(name, undefined);
            }
          })
        }
        .tabBar(this.tabLabel($r('sys.symbol.house'), '同休', NavRoutes.TAB_HOME))

        TabContent() {
          // 空态引导要去班表/配对：同首页，页面只报名字，路由种类只有壳层知道
          CoTimeView({
            onOpenRoute: (name: string): void => {
              this.openRoute(name, undefined);
            }
          })
        }
        .tabBar(this.tabLabel($r('sys.symbol.heart'), '共同', NavRoutes.TAB_COMMON_TIME))

        TabContent() {
          MeView()
        }
        .tabBar(this.tabLabel($r('sys.symbol.person'), '我的', NavRoutes.TAB_ME))
      }
      .scrollable(false)
      .barHeight(64)
      .onChange((idx: number) => {
        this.activeTab = idx;
      })
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
   * 栈目的地映射。班表页自带标题与滚动，用系统标题栏会重复，
   * 因此隐藏标题栏，返回交给系统返回键/手势。
   */
  @Builder
  destinationBuilder(name: string) {
    if (name === NavRoutes.SCHEDULE_HUB) {
      NavDestination() {
        ScheduleHub()
      }
      .hideTitleBar(true)
      .backgroundColor($r('app.color.page_bg_warm'))
    }
  }

  @Builder
  tabLabel(icon: Resource, text: string, idx: number) {
    Column({ space: 2 }) {
      SymbolGlyph(icon)
        .fontSize(22)
        .fontColor(this.activeTab === idx ? [$r('app.color.brand_pink')] : [$r('app.color.text_tertiary')])
      Text(text)
        .fontSize(11)
        .fontColor(this.activeTab === idx ? $r('app.color.brand_pink') : $r('app.color.text_tertiary'))
        .fontWeight(this.activeTab === idx ? FontWeight.Bold : FontWeight.Normal)
    }
    .width('100%')
    .justifyContent(FlexAlign.Center)
  }
}
