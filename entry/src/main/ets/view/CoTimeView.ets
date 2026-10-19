import { HORIZON_DEFAULT_DAYS, nowEpochMin, todayEpochDay } from 'domain';
import { DateLabel, Logger } from 'commons';
import {
  CommonTimePageData, CommonTimeQueryService, ExperienceMode,
  ScheduleUseCase, WindowFilter, WindowFilterKey, WindowSummary, horizonLabel, SharedPlanViewService
} from 'feature';
import { ChipV2, ChipV2AccessibilitySelectedType, ChipV2Label, ChipV2Options, SegmentButtonV2Items } from '@kit.ArkUI';
import { DirectionalContent } from '../component/DirectionalContent';
import { NavRoutes } from '../navigation/NavRoutes';
import { COTIME_SEG_PLANS, COTIME_SEG_WINDOW, takeCoTimeSegment } from '../util/NavUtil';
import { syncOnPull } from '../util/PullRefresh';
import { LatestLanding } from '../util/LatestLanding';
import { LatestReadQueue } from '../util/LatestReadQueue';
import { displayTagLine } from '../util/WindowTagUtil';
import { DesignTokens } from '../theme/DesignTokens';
import { AccessibilityPolicy } from '../accessibility/AccessibilityPolicy';
import { EditorialCard } from '../component/EditorialCard';
import { CapsuleSegment } from '../component/CapsuleSegment';
import { NoticeBar, NoticeTone } from '../component/NoticeBar';
import { SkeletonBar } from '../component/Skeleton';
import { StatePanel, StatePanelKind } from '../component/StatePanel';
import { WindowCard } from '../component/WindowCard';
import { currentWeekStart, WEEK_MODE_COMMON, WeekScheduleView } from '../component/WeekScheduleView';
import { WindowDetailSheet } from '../component/WindowDetailSheet';
import { DayDetailSheet } from '../component/DayDetailSheet';
import { Breakpoint, Breakpoints } from '../responsive/Breakpoints';
import { ResponsiveContainer } from '../responsive/ResponsiveContainer';
import { PlansView } from './PlansView';
import { FadingScrollViewport, ScrollHeaderState } from '../component/FadingHeader';
import { readScrollY } from '../util/ScrollOffset';
import { CompanionsDuo } from '../component/CompanionsDuo';

const TAG = 'CoTimeView';
/** 首次读取的重试次数与间隔：冷启动时 Db 可能还没 init 完（与首页同一口径）。 */
const LOAD_ATTEMPTS = 3;
const RETRY_DELAY_MS = 250;
/** 撞到另一路重算正在写缓存时的等待时长。 */
const SETTLE_DELAY_MS = 300;
/** 日详情转创建计划：先收一个 sheet 再开另一个，避免同帧开关冲突。 */
const SHEET_HANDOFF_MS = 180;

const VIEW_LIST = 'list';
const VIEW_WEEK = 'week';

/** 精简筛选档（与 WindowFilterKey 一一对应，不多不少）。 */
interface FilterChip {
  key: WindowFilterKey;
  label: string;
}

const FILTERS: FilterChip[] = [
  { key: WindowFilterKey.ALL, label: '全部' },
  { key: WindowFilterKey.GTE_2H, label: '≥2小时' },
  { key: WindowFilterKey.FULL_DAY, label: '完整同休' },
  { key: WindowFilterKey.WEEKEND, label: '周末' },
  { key: WindowFilterKey.TRIP, label: '可出行' }
];

/** 共同时间页：列表、周历、计划三个视图。 */
@Component
export struct CoTimeView {
  @Prop @Watch('onActiveChanged') active: boolean = true;
  /** 打开栈内路由（班表 / 配对），由 AppNavigator 注入：页面不持有 NavPathStack。 */
  onOpenRoute: (name: string) => void = (name: string) => {
  };
  @State private page: CommonTimePageData | null = null;
  /** 读模型加载失败：无内容时给整页错误面板，有内容时只挂一条提示，不清空旧结果。 */
  @State private failed: boolean = false;
  @State private segment: string = COTIME_SEG_WINDOW;
  /** 时间视图默认列表，切换计划时保留之前的筛选。 */
  @State private viewMode: string = VIEW_LIST;
  @State private targetView: number = 0;
  @State private filterKey: WindowFilterKey = WindowFilterKey.ALL;
  @State private refreshing: boolean = false;
  @State private sharedPending: boolean = false;
  private sharedRead: number = 0;
  /** 下拉刷新时递增，驱动周历重新装配（周历自己按周取数）。 */
  @State private weekTick: number = 0;
  @State private visibleWeek: number = currentWeekStart();
  // 窗口详情半模态（点窗口 → 创建共同计划）
  @State private sheetVisible: boolean = false;
  @State private sheetStart: number = 0;
  @State private sheetEnd: number = 0;
  @State private sheetTags: string = '';
  // 日详情半模态（周历点某一天 → 当日窗口 + 双方忙碌时间轴）
  @State private dayVisible: boolean = false;
  @State private dayEpoch: number = -1;
  /** 容器宽度档位：expanded 时窗口详情常驻右侧详情栏，不再弹半模态。 */
  @State @Watch('onBreakpointChanged') private bp: Breakpoint = Breakpoint.COMPACT;
  /** 详情栏是否已选中一个窗口（离开 expanded 时清掉，回到窄屏不残留半开状态）。 */
  @State private detailOpen: boolean = false;
  segItems: SegmentButtonV2Items = new SegmentButtonV2Items([{ text: '列表' }, { text: '周历' }, { text: '计划' }]);
  /** 筛选 Chip 的配置对象：ChipV2 是 @ComponentV2，选中态靠 @Trace activated 驱动， */
  private chips: ChipV2Options[] = [];
  // 装饰器实参必须是字面量，取值与 ThemeModeSignal.COLOR_MODE_KEY 一致。
  @StorageProp('crd_color_mode') @Watch('onColorModeChanged') private colorMode: number = -1;
  // 保存动作 / 伴侣档案变更 / 日切重算都会广播重算计数，这里只重读读模型
  @StorageProp('recomputeCount') @Watch('onRecomputeChanged') recomputeCount: number = 0;
  @StorageProp('crdSharedPlanTick') @Watch('loadSharedBadge') private sharedPlanTick: number = 0;
  /** 只接受最后一次查询的结果。 */
  private landing: LatestLanding = new LatestLanding();
  private reads: LatestReadQueue = new LatestReadQueue();
  private badgeReads: LatestReadQueue = new LatestReadQueue();
  private mounted: boolean = false;
  private needsRecompute: boolean = false;
  private windowScroller: Scroller = new Scroller();
  private weekScroller: Scroller = new Scroller();
  private listScrollY: number = 0;
  private weekScrollY: number = 0;
  private restoringView: boolean = false;
  private handoffTimer: number = -1;
  @State private listVisual: ScrollHeaderState = new ScrollHeaderState();
  @State private weekVisual: ScrollHeaderState = new ScrollHeaderState();
  @State private headerWidth: number = 0;
  // 跨 Tab 导航广播（首页冲突条、计划页空态引导）：切 Tab 由壳层做，分段由本页认领
  @StorageProp('navToCoTimeCount') @Watch('onNavRequest') navToCoTimeCount: number = 0;
  // 装饰器实参必须是字面量，取值与 SENIOR_MODE_KEY 保持一致。
  @StorageProp('crd_senior_mode') senior: boolean = false;

  aboutToAppear(): void {
    this.mounted = true;
    this.loadSharedBadge();
    this.buildChips();
    // Tab 内容可能在广播之后才创建，此时 @Watch 不会触发，进页面时补消费一次
    this.applySegmentRequest();
    this.load(true);
  }

  aboutToDisappear(): void {
    this.mounted = false;
    this.sharedRead++;
    this.landing.begin();
    this.reads.cancel(); this.badgeReads.cancel();
    if (this.handoffTimer >= 0) { clearTimeout(this.handoffTimer); this.handoffTimer = -1; }
  }

  private chooseView(idx: number): void {
    this.loadSharedBadge();
    if (idx === 2) {
      this.segment = COTIME_SEG_PLANS;
      return;
    }
    // 从计划返回时直接给正确初态，不播放一个不存在的旧视图。
    if (this.segment === COTIME_SEG_PLANS) {
      this.restoringView = true;
      this.viewMode = idx === 1 ? VIEW_WEEK : VIEW_LIST;
    }
    this.targetView = idx;
    this.segment = COTIME_SEG_WINDOW;
  }

  private commitView(idx: number): void {
    const next = idx === 1 ? VIEW_WEEK : VIEW_LIST;
    if (next === this.viewMode) { return; }
    if (this.viewMode === VIEW_LIST) {
      this.listScrollY = readScrollY(this.windowScroller, this.listScrollY);
    } else {
      this.weekScrollY = readScrollY(this.weekScroller, this.weekScrollY);
    }
    this.restoringView = true;
    this.viewMode = next;
  }

  private selectedWindow(w: WindowSummary): boolean {
    return (this.sheetVisible || this.paneShown()) && w.start === this.sheetStart && w.end === this.sheetEnd;
  }

  /** 一次性建好筛选 Chip。ChipV2Options/ChipV2Label 都是 @ObservedV2， */
  private buildChips(): void {
    const chips: ChipV2Options[] = [];
    for (let i = 0; i < FILTERS.length; i++) {
      const f: FilterChip = FILTERS[i];
      chips.push(new ChipV2Options({
        label: new ChipV2Label({
          text: f.label,
          fontSize: DesignTokens.chipFontSize(),
          fontColor: DesignTokens.chipText(),
          activatedFontColor: DesignTokens.chipTextOn()
        }),
        activated: this.filterKey === f.key,
        // ChipV2 的 allowClose 默认 true，会在标签右侧画一颗 ✕；筛选档没有"清除这一档"的语义，必须显式关掉
        allowClose: false,
        backgroundColor: DesignTokens.chipBg(),
        activatedBackgroundColor: DesignTokens.chipBgOn(),
        borderRadius: DesignTokens.chipRadius(),
        // 选中档只有底色一种表达；声明为"已选中"语义，读屏才知道这颗是当前筛选
        accessibilitySelectedType: ChipV2AccessibilitySelectedType.SELECTED,
        accessibilityDescription: '按这个条件筛选共同时间',
        onClicked: () => {
          this.selectFilter(f.key);
        }
      }));
    }
    this.chips = chips;
  }

  /** 只更新 @Trace 颜色字段；不重建 Chip、不断开筛选状态与横向 Scroll。 */
  onColorModeChanged(): void {
    for (let i = 0; i < this.chips.length; i++) {
      const chip: ChipV2Options = this.chips[i];
      chip.label.fontColor = DesignTokens.chipText();
      chip.label.activatedFontColor = DesignTokens.chipTextOn();
      chip.backgroundColor = DesignTokens.chipBg();
      chip.activatedBackgroundColor = DesignTokens.chipBgOn();
    }
  }

  onRecomputeChanged(): void {
    this.loadSharedBadge();
    this.load(false);
  }
  onActiveChanged(): void {
    if (!this.active) {
      this.sharedRead++; this.landing.invalidate(); this.reads.cancel(); this.badgeReads.cancel(); return;
    }
    if (this.mounted) { this.loadSharedBadge(); this.load(this.page === null); }
  }
  private loadSharedBadge(): void {
    if (!this.mounted || !this.active) return;
    const turn = ++this.sharedRead;
    this.badgeReads.run(async (): Promise<void> => {
      try {
        const data = await SharedPlanViewService.read();
        if (this.mounted && this.active && turn === this.sharedRead) this.sharedPending = data.pendingCount > 0;
      } catch { /* Keep badge on storage failure. */ }
    });
  }

  onNavRequest(): void {
    this.applySegmentRequest();
  }

  private applySegmentRequest(): void {
    const seg = takeCoTimeSegment();
    if (seg === COTIME_SEG_PLANS || seg === COTIME_SEG_WINDOW) {
      this.segment = seg;
      if (seg === COTIME_SEG_WINDOW) {
        this.viewMode = VIEW_LIST;
      this.targetView = 0;
      }
    }
  }

  // ---------- 数据 ----------

  /** 读页面读模型。allowRecompute=true（首次进入 / 用户点重试或重新计算）时， */
  private async load(allowRecompute: boolean): Promise<void> {
    if (!this.mounted || !this.active) return;
    const token = this.landing.begin();
    this.needsRecompute = this.needsRecompute || allowRecompute;
    await this.reads.run(async (): Promise<void> => {
      if (!this.mounted || !this.active) return;
      const recompute = this.needsRecompute; this.needsRecompute = false;
      await this.readPage(recompute, token);
    });
  }
  private async readPage(allowRecompute: boolean, token: number): Promise<void> {
    // 一次加载只读一次表：筛选下界与查询用的"现在"分两次读数时，跨午夜那瞬会劈成两天
    const now = nowEpochMin();
    const filter: WindowFilter = { key: this.filterKey, fromEpochMin: now };
    for (let attempt = 1; attempt <= LOAD_ATTEMPTS; attempt++) {
      try {
        let page = await CommonTimeQueryService.getCommonTimePage(filter, now);
        if (allowRecompute && (page.computedAt <= 0 || page.stale)) {
          await ScheduleUseCase.ensureSeeded();
          await ScheduleUseCase.recompute(todayEpochDay(), true);
          page = await CommonTimeQueryService.getCommonTimePage(filter, now);
          if (page.computedAt <= 0) {
            // 自己刚写完就读到空表，只能是另一路重算正在 DELETE/INSERT：等它落盘再读一次
            await this.delay(SETTLE_DELAY_MS);
            page = await CommonTimeQueryService.getCommonTimePage(filter, now);
          }
        }
        if (!this.landing.isCurrent(token)) {
          return;
        }
        this.page = page;
        this.failed = false;
        this.refreshing = false;
        return;
      } catch (e) {
        if (attempt >= LOAD_ATTEMPTS) {
          if (!this.landing.isCurrent(token)) {
            return;
          }
          // 有旧结果就不清空，只把状态标成可恢复错误（提示条在内容上方）
          this.failed = true;
          this.refreshing = false;
          Logger.error(TAG, 'load common time page failed: ' + (e as Error).message);
          return;
        }
        await this.delay(RETRY_DELAY_MS);
      }
    }
  }

  private delay(ms: number): Promise<void> {
    return new Promise<void>((resolve) => {
      setTimeout(() => {
        resolve();
      }, ms);
    });
  }

  private async onRefresh(): Promise<void> {
    await syncOnPull();
    this.refreshing = false;
  }

  private selectFilter(key: WindowFilterKey): void {
    if (this.filterKey === key) {
      return;
    }
    this.filterKey = key;
    // ChipV2 不自带互斥：选中态由调用方写回 activated（@Trace 会直接刷那一颗）。
    for (let i = 0; i < this.chips.length; i++) {
      this.chips[i].activated = FILTERS[i].key === key;
    }
    this.load(false);
  }

  // ---------- 读模型取值（集中处理空值，build 里不做可空判断） ----------

  private rows(): WindowSummary[] {
    const p = this.page;
    return p == null ? [] : p.rows;
  }

  private isSolo(): boolean {
    const p = this.page;
    return p != null && p.mode === ExperienceMode.SOLO;
  }

  private partnerKnown(): boolean {
    const p = this.page;
    return p == null || p.partnerKnown;
  }

  private isStale(): boolean {
    const p = this.page;
    return p != null && p.stale;
  }

  private subtitle(): string {
    const p = this.page;
    let who = '单人模式';
    if (p != null && p.mode !== ExperienceMode.SOLO) {
      // 主体必须和下面列表的真实口径一致：配对了却没拿到 TA 的数据时，这些只是我的一侧。
      // 那件事页内那条 NoticeBar 已经在解释，副标题只换主体，不再重复整句。
      who = p.partnerKnown ? (p.partnerName === '' ? '伴侣' : p.partnerName) : '我的空闲';
    }
    return who + ' · ' + horizonLabel(p == null ? HORIZON_DEFAULT_DAYS : p.horizonDays);
  }

  private subtitleColor(): Resource {
    const p = this.page;
    return p != null && p.mode === ExperienceMode.SOLO
      ? DesignTokens.textTertiary : DesignTokens.textAccent;
  }

  private staleTitle(): string {
    const p = this.page;
    const day = p == null ? todayEpochDay() : todayEpochDay(p.computedAt);
    return '结果基于 ' + DateLabel.mdw(day) + ' 的计算';
  }

  private emptyTitle(): ResourceStr {
    if (this.filterKey !== WindowFilterKey.ALL) {
      return '该筛选下暂无窗口';
    }
    return this.isSolo() ? $r('app.string.cotime_empty_partner_title') : $r('app.string.cotime_empty_with_partner');
  }

  private emptyDesc(): ResourceStr {
    if (this.filterKey !== WindowFilterKey.ALL) {
      return '试试换成「全部」，或者到「我的」里放宽作息。';
    }
    return this.isSolo() ? $r('app.string.cotime_empty_partner_desc') : '检查一下两人的班表和作息，或者把窗口放长一点。';
  }

  private emptyAction(): ResourceStr {
    if (this.filterKey !== WindowFilterKey.ALL) {
      return '看全部';
    }
    return this.isSolo() ? '去添加伴侣' : '去改班表';
  }

  private onEmptyAction(): void {
    if (this.filterKey !== WindowFilterKey.ALL) {
      this.selectFilter(WindowFilterKey.ALL);
      return;
    }
    if (this.isSolo()) {
      this.onOpenRoute(NavRoutes.PAIRING);
      return;
    }
    this.onOpenRoute(NavRoutes.SCHEDULE_HUB);
  }

  // ---------- 交互 ----------

  /** 详情栏只在 expanded + 列表视图占位；其余组合一律回到半模态。 */
  private paneShown(): boolean {
    return Breakpoints.isExpanded(this.bp) && this.viewMode === VIEW_LIST && this.detailOpen;
  }

  /** 选中窗口的落地方式：宽屏留在列表右侧的详情栏（列表上下文不丢）， */
  private presentWindow(): void {
    if (Breakpoints.isExpanded(this.bp) && this.viewMode === VIEW_LIST) {
      this.detailOpen = true;
      return;
    }
    this.sheetVisible = true;
  }

  onBreakpointChanged(): void {
    if (!Breakpoints.isExpanded(this.bp)) {
      this.detailOpen = false;
    }
  }

  /** 列表点卡片：读模型已带标签，直接开创建计划详情，不再查一次详情。 */
  private openSummary(w: WindowSummary): void {
    this.sheetStart = w.start;
    this.sheetEnd = w.end;
    this.sheetTags = displayTagLine(w.tags);
    this.presentWindow();
  }

  /** 计划页头部行的出口：切回窗口分段，并把当前筛选下的第一段空闲直接开成建计划入口。 */
  private gotoNextWindow(): void {
    this.segment = COTIME_SEG_WINDOW;
    this.viewMode = VIEW_LIST;
    this.targetView = 0;
    const rows = this.rows();
    if (rows.length > 0) {
      this.openSummary(rows[0]);
    }
  }

  /** 周历点色块：只有起止（该窗口可能不在当前筛选结果里），标签向详情读模型要。 */
  private async openWindow(start: number, end: number): Promise<void> {
    if (start <= 0 || end <= start) {
      return;
    }
    let tags = '';
    try {
      const detail = await CommonTimeQueryService.getWindowDetail(start, end);
      tags = displayTagLine(detail.window.tags);
    } catch (e) {
      // 详情读不到不阻断建计划：标签只用于展示
      Logger.warn(TAG, 'window detail unavailable, open sheet without tags');
    }
    this.sheetStart = start;
    this.sheetEnd = end;
    this.sheetTags = tags;
    this.presentWindow();
  }

  private onSheetClose(): void {
    this.sheetVisible = false;
    // 创建成功路径另有重算广播，这里只兜底重读一次
    this.load(false);
  }

  /** 详情栏「收起」：关掉面板并重读一次，刚创建的计划要落到列表里。 */
  private onDetailClose(): void {
    this.detailOpen = false;
    this.load(false);
  }

  private openDay(epochDay: number): void {
    this.dayEpoch = epochDay;
    this.dayVisible = true;
  }

  /** 日详情里点某个共同窗口 → 收回日详情，转开创建计划详情。回调给的是全量领域标签，这里收敛。 */
  private pickWindow(start: number, end: number, tags: string[]): void {
    this.dayVisible = false;
    this.sheetStart = start;
    this.sheetEnd = end;
    this.sheetTags = displayTagLine(tags);
    if (this.handoffTimer >= 0) { clearTimeout(this.handoffTimer); }
    this.handoffTimer = setTimeout(() => {
      this.handoffTimer = -1;
      this.presentWindow();
    }, SHEET_HANDOFF_MS);
  }

  // ---------- 构建 ----------

  build() {
    ResponsiveContainer({ breakpoint: this.bp }) {
      // 两个 sheet 分别绑在两个节点上：同一组件只能生效一个 bindSheet，
      // 绑在同一节点时后者覆盖前者，会导致点日期无响应。
      // expanded 档下窗口详情改走列表右侧的常驻栏（windowBody 内分支），不再弹第一个 sheet。
      Column() {
        Column({ space: DesignTokens.space3 }) {
          this.header()
          this.segmentControl()

          if (this.page != null) {
            if (this.failed) {
              NoticeBar({
                tone: NoticeTone.ERROR,
                title: '刷新失败，下面是上次的结果',
                body: '数据没变，稍后再下拉一次就行',
                actionLabel: '重试',
                onAction: () => {
                  this.load(true);
                }
              })
            } else if (this.isStale()) {
              NoticeBar({
                tone: NoticeTone.WARN,
                title: this.staleTitle(),
                body: '班表可能变了，重新算一次再确认',
                actionLabel: '重新计算',
                onAction: () => {
                  this.load(true);
                }
              })
            }
            if (!this.partnerKnown() && this.segment === COTIME_SEG_WINDOW) {
              NoticeBar({
                tone: NoticeTone.WARN,
                glyph: '?',
                title: '还不知道 TA 今天的日程',
                body: '下面的窗口只算了你的空闲，拿到 TA 的数据会自动纠正',
                actionLabel: '去看看',
                onAction: () => {
                  this.onOpenRoute(NavRoutes.PAIRING);
                }
              })
            }
          }

          if (this.segment === COTIME_SEG_WINDOW) {
            Column() {
              DirectionalContent({ target: this.targetView, onCommit: (idx: number) => {
                this.commitView(idx);
              } }) { this.windowBody() }
            }.width('100%').layoutWeight(1)
          } else {
            this.plansBody()
          }
        }
        .width('100%')
        .layoutWeight(1)
        .padding({ left: Breakpoints.hPadding(this.bp), right: Breakpoints.hPadding(this.bp) })
        .bindSheet($$this.dayVisible, this.daySheet(), {
          height: SheetSize.FIT_CONTENT,
          detents: [SheetSize.FIT_CONTENT],
          preferType: SheetType.BOTTOM,
          dragBar: false,
          showClose: false,
          radius: { topLeft: DesignTokens.radiusSheet, topRight: DesignTokens.radiusSheet },
          blurStyle: BlurStyle.Thick,
          maskColor: DesignTokens.scrim
        })
      }
      .width('100%')
      .height('100%')
      .linearGradient(DesignTokens.pageGradient())
      .bindSheet($$this.sheetVisible, this.detailSheet(), {
        detents: [SheetSize.MEDIUM, SheetSize.LARGE],
        dragBar: false,
        showClose: false,
        // 表面（暖白渐变 + 顶角）由 WindowDetailSheet 自己画，
        // 系统 sheet 再铺底色/模糊就是两层不透明背景叠实时模糊（规范 §5.5）
        backgroundColor: Color.Transparent,
        blurStyle: BlurStyle.NONE,
        maskColor: DesignTokens.scrim,
        onDisappear: () => { this.sheetVisible = false; }
      })
    }
  }

  @Builder
  header() {
    Row({ space: 10 }) {
      // Keep title and subtitle together; the subtitle, not the title, meets the duo's lower edge.
      Column({ space: 2 }) {
        Text('共同休时')
          .fontSize(DesignTokens.fontTitle)
          .fontFamily(DesignTokens.fontRound)
          .fontWeight(FontWeight.Bolder)
          .fontColor(DesignTokens.textPrimary)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
        Text(this.subtitle())
          .fontSize(DesignTokens.fontCaption)
          .fontColor(this.subtitleColor())
          .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
      }.layoutWeight(1).alignItems(HorizontalAlign.Start).offset({ y: 3 })
      CompanionsDuo({
        active: this.active && !this.sheetVisible && !this.dayVisible,
        availableWidth: this.headerWidth
      })
    }
    .width('100%')
    .alignItems(VerticalAlign.Bottom)
    .padding({ top: DesignTokens.space5 })
    .onAreaChange((_oldArea: Area, newArea: Area) => {
      const width = Breakpoints.widthOf(newArea);
      if (width > 0 && width !== this.headerWidth) { this.headerWidth = width; }
    })
  }

  @Builder
  segmentControl() {
    CapsuleSegment({
      pendingBadge: this.sharedPending,
      items: this.segItems,
      selectedIndex: this.segment === COTIME_SEG_PLANS ? 2 : this.targetView,
      onPick: (idx: number) => {
        this.chooseView(idx);
      }
    })
  }

  /** 窗口分段：视图切换 + （列表专属）筛选档 + 内容。expanded 的列表走「列表—详情」双栏。 */
  @Builder
  windowBody() {
    Column({ space: DesignTokens.space3 }) {
      if (this.viewMode === VIEW_LIST) {
        if (this.paneShown()) {
          // 两列各自撑满行高：列表内的 Refresh 靠 layoutWeight 拿到确定高度，详情栏固定宽
          Row({ space: DesignTokens.space4 }) {
            Column() {
              this.listContent()
            }
            .layoutWeight(1)
            .height('100%')

            Column() {
              this.detailPane()
            }
            .width(Breakpoints.DETAIL_PANE)
            .height('100%')
          }
          .width('100%')
          .layoutWeight(1)
          .alignItems(VerticalAlign.Top)
        } else {
          this.listContent()
        }
      } else {
        this.weekContent()
      }
    }
    .width('100%')
    .layoutWeight(1)
  }

  /** 宽屏详情栏：复用同一份 WindowDetailSheet（inline），点列表卡片不再弹半模态。 */
  @Builder
  detailPane() {
    WindowDetailSheet({
      inline: true,
      winStart: this.sheetStart,
      winEnd: this.sheetEnd,
      winTags: this.sheetTags,
      onCreated: () => { this.segment = COTIME_SEG_PLANS; },
      onClose: () => {
        this.onDetailClose();
      }
    })
  }

  /** 精简筛选档：全部 / ≥2小时 / 完整同休 / 周末 / 可出行（只在列表视图出现）。 */
  @Builder
  filterRow() {
    Scroll() {
      Row({ space: DesignTokens.space2 }) {
        ForEach(FILTERS, (f: FilterChip, idx: number) => {
          ChipV2({ chipV2Options: this.chips[idx] })
        }, (f: FilterChip) => f.key.toString())
      }
      // 尾部留白：Scroll 贴屏幕边铺满，不留 padding 时末颗 chip 会永远缺一角
      .padding({ left: DesignTokens.space4, right: DesignTokens.space4 })
    }
    .width('100%')
    .scrollable(ScrollDirection.Horizontal)
    .scrollBar(BarState.Off)
    .align(Alignment.Start)
  }

  @Builder
  listFilters() {
    Column({ space: DesignTokens.space3 }) {
      if (this.page != null) {
        Text('共 ' + this.rows().length + ' 段')
          .fontSize(12)
          .fontColor(DesignTokens.textTertiary)
          .width('100%')
          .textAlign(TextAlign.End)
      }
      this.filterRow()
    }
    .width('100%')
  }

  @Builder
  listContent() {
    Column() {
      FadingScrollViewport({ fadeHeight: 24, visual: this.listVisual }) {
        Refresh({ refreshing: $$this.refreshing, offset: 64, friction: 10 }) {
          // List.space 只收 number/string，收不了 Resource 令牌：值与 space_3(12vp) 对齐
          List({ space: 12, scroller: this.windowScroller }) {
            // 普通列表项，不吸顶：统计和筛选与窗口卡片一起滚动。
            ListItem() {
              this.listFilters()
            }
            if (this.rows().length > 0) {
              ForEach(this.rows(), (w: WindowSummary, idx: number) => {
                ListItem() {
                  WindowCard({
                    winStart: w.start,
                    winEnd: w.end,
                    winDuration: w.durationMin,
                    displayTags: w.displayTags.join('|'),
                    todayEpoch: todayEpochDay(),
                    cutTopLeft: idx % 2 === 0,
                    selected: this.selectedWindow(w),
                    onTapCard: () => {
                      this.openSummary(w);
                    }
                  })
                }
              }, (w: WindowSummary, idx: number) => w.start + '-' + w.end + '-' + w.channel + '-'
                + w.displayTags.join('|') + '-' + todayEpochDay() + '-' + idx)
            } else {
              ListItem() {
                this.listEmptyContent()
              }
            }
          }
          .width('100%')
          .height('100%')
          .scrollBar(BarState.Off)
          .onAppear(() => {
            this.windowScroller.scrollTo({ xOffset: 0, yOffset: this.listScrollY, animation: false });
            this.restoringView = false;
            this.listVisual.update(readScrollY(this.windowScroller, this.listScrollY));
          })
          .onDidScroll(() => {
            if (!this.restoringView && this.viewMode === VIEW_LIST) {
              this.listScrollY = readScrollY(this.windowScroller, this.listScrollY);
            }
            this.listVisual.update(readScrollY(this.windowScroller, this.listScrollY));
          })
          // alwaysEnabled：只有一两张卡时列表不满一屏，默认不响应下拉手势，Refresh 就永远接不到这一次。
          .edgeEffect(EdgeEffect.Spring, { alwaysEnabled: true })
          .padding({ bottom: DesignTokens.dockClearance })
        }
        .onRefreshing(() => {
          this.onRefresh();
        })
        .width('100%')
        .height('100%')
      }
    }
    .width('100%')
    .layoutWeight(1)
  }

  @Builder
  listEmptyContent() {
    if (this.page == null) {
      if (this.failed) {
        StatePanel({
          kind: StatePanelKind.ERROR,
          title: '共同时间读取失败',
          description: '手机里的数据没有变化，再下拉一次或点重试通常就好。',
          actionLabel: '重试',
          onAction: () => { this.load(true); }
        })
      } else {
        this.skeleton()
      }
    } else {
      StatePanel({
        kind: StatePanelKind.EMPTY,
        title: this.emptyTitle(),
        description: this.emptyDesc(),
        actionLabel: this.emptyAction(),
        onAction: () => { this.onEmptyAction(); }
      })
    }
  }

  @Builder
  weekContent() {
    Column() {
      FadingScrollViewport({ fadeHeight: 12, visual: this.weekVisual }) {
        Refresh({ refreshing: $$this.refreshing, offset: 64, friction: 10 }) {
          Scroll(this.weekScroller) {
            Column() {
              EditorialCard({ hero: false, cutTopLeft: true, tappable: false }) {
                WeekScheduleView({
                  active: this.active,
                  mode: WEEK_MODE_COMMON,
                  initialWeekStart: this.visibleWeek,
                  onWeekChange: (day: number) => { this.visibleWeek = day; },
                  refreshTick: this.weekTick,
                  onPickDay: (epochDay: number) => {
                    this.openDay(epochDay);
                  },
                  onPickWindow: (start: number, end: number) => {
                    this.openWindow(start, end);
                  }
                })
              }
            }
            .width('100%')
            .padding({ bottom: DesignTokens.dockClearance })
          }
          .width('100%')
          .height('100%')
          .scrollable(ScrollDirection.Vertical)
          .edgeEffect(EdgeEffect.Spring, { alwaysEnabled: true })
          .scrollBar(BarState.Off)
          .align(Alignment.Top)
          .onAppear(() => {
            this.weekScroller.scrollTo({ xOffset: 0, yOffset: this.weekScrollY, animation: false });
            this.restoringView = false;
            this.weekVisual.update(readScrollY(this.weekScroller, this.weekScrollY));
          })
          .onDidScroll(() => {
            if (!this.restoringView && this.viewMode === VIEW_WEEK) {
              this.weekScrollY = readScrollY(this.weekScroller, this.weekScrollY);
            }
            this.weekVisual.update(readScrollY(this.weekScroller, this.weekScrollY));
          })
        }
        .onRefreshing(() => {
          this.onRefresh();
        })
        .width('100%')
        .height('100%')
      }
    }
    .width('100%')
    .layoutWeight(1)
  }

  @Builder
  plansBody() {
    Column() {
      PlansView({
        active: this.active,
        onGoWindow: () => {
          this.segment = COTIME_SEG_WINDOW;
          this.viewMode = VIEW_LIST;
          this.targetView = 0;
        },
        onNextWindow: () => {
          this.gotoNextWindow();
        },
        onVisiblePendingChange: (pending: boolean) => {
          this.sharedRead++;
          this.sharedPending = pending;
        }
      })
    }
    .width('100%')
    .layoutWeight(1)
  }

  @Builder
  skeleton() {
    Column({ space: DesignTokens.space3 }) {
      EditorialCard({ hero: false, cutTopLeft: true, tappable: false }) {
        Column({ space: DesignTokens.space3 }) {
          SkeletonBar({ barWidth: '42%', barHeight: DesignTokens.space4 })
          SkeletonBar({ barWidth: '68%' })
          SkeletonBar({ barWidth: '30%' })
        }
        .width('100%')
        .alignItems(HorizontalAlign.Start)
      }

      EditorialCard({ hero: false, cutTopLeft: false, tappable: false }) {
        Column({ space: DesignTokens.space3 }) {
          SkeletonBar({ barWidth: '38%', barHeight: DesignTokens.space4 })
          SkeletonBar({ barWidth: '74%' })
        }
        .width('100%')
        .alignItems(HorizontalAlign.Start)
      }
    }
    .width('100%')
    // 占位灰条没有可朗读内容，只留一句"在读"，否则读屏用户面对一片静默
    .accessibilityGroup(true)
    .accessibilityText('正在读取共同时间')
  }

  /** 窗口详情半模态内容（时间轴 + 类型 + 起止调节 + 创建计划）。 */
  @Builder
  detailSheet() {
    WindowDetailSheet({
      winStart: this.sheetStart,
      winEnd: this.sheetEnd,
      winTags: this.sheetTags,
      onCreated: () => { this.segment = COTIME_SEG_PLANS; },
      onClose: () => {
        this.onSheetClose();
      }
    })
  }

  /** 日详情半模态内容（当日窗口 + 双方忙碌时间轴）。 */
  @Builder
  daySheet() {
    if (this.dayEpoch >= 0) {
      DayDetailSheet({
        day: this.dayEpoch,
        onPickWindow: (start: number, end: number, tags: string[]) => {
          this.pickWindow(start, end, tags);
        },
        onClose: () => {
          this.dayVisible = false;
        }
      })
    }
  }
}
