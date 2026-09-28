import { MIN_PER_DAY, todayEpochDay } from 'domain';
import { AppConst, DateLabel, Logger } from 'commons';
import {
  CommonTimePageData, CommonTimeQueryService, ExperienceMode, ScheduleUseCase, WindowFilter,
  WindowFilterKey, WindowSummary, horizonLabel
} from 'feature';
import { ChipV2, ChipV2AccessibilitySelectedType, ChipV2Label, ChipV2Options, SegmentButtonV2Items } from '@kit.ArkUI';
import { NavRoutes } from '../navigation/NavRoutes';
import { COTIME_SEG_PLANS, COTIME_SEG_WINDOW, takeCoTimeSegment } from '../util/NavUtil';
import { syncOnPull } from '../util/PullRefresh';
import { displayTagLine } from '../util/WindowTagUtil';
import { DesignTokens } from '../theme/DesignTokens';
import { AccessibilityPolicy } from '../accessibility/AccessibilityPolicy';
import { EditorialCard } from '../component/EditorialCard';
import { CapsuleSegment } from '../component/CapsuleSegment';
import { NoticeBar, NoticeTone } from '../component/NoticeBar';
import { StatePanel, StatePanelKind } from '../component/StatePanel';
import { WindowCard } from '../component/WindowCard';
import { WEEK_MODE_COMMON, WeekScheduleView } from '../component/WeekScheduleView';
import { WindowDetailSheet } from '../component/WindowDetailSheet';
import { DayDetailSheet } from '../component/DayDetailSheet';
import { Breakpoint, Breakpoints } from '../responsive/Breakpoints';
import { ResponsiveContainer } from '../responsive/ResponsiveContainer';
import { PlansView } from './PlansView';

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

/**
 * 共同时间页：一级分段只有「时间窗口 / 共同计划」，窗口分段下只有「列表 / 周历」两种视图。
 * - 列表：读模型给出的按日归并行（一天只留最长的一段），点卡片直接建计划；
 * - 周历：课程表式的当日空闲块（WeekScheduleView 共同模式），点色块建计划、点空白看当日明细；
 * - 本页只有「列表 / 周历」两种视图，不提供月历视图；
 * - 筛选与标签压缩口径都在 feature 读模型里，页面只渲染，不自行过滤或映射标签；
 * - 宽度档位：expanded（≥840vp）的列表视图改走「列表—详情」双栏，点卡片在右侧栏内
 *   直接开建计划表单；compact / medium 与改造前一致，仍用半模态。
 */
@Component
export struct CoTimeView {
  /** 打开栈内路由（班表 / 配对），由 AppNavigator 注入：页面不持有 NavPathStack。 */
  onOpenRoute: (name: string) => void = (name: string) => {
  };
  @State private page: CommonTimePageData | null = null;
  /** 读模型加载失败：无内容时给整页错误面板，有内容时只挂一条提示，不清空旧结果。 */
  @State private failed: boolean = false;
  @State private segment: string = COTIME_SEG_WINDOW;
  /**
   * 窗口段内的视图：默认列表。长辈模式要的低密度入口就是这个默认值——
   * 周历网格要逐格摸，列表一行一段，读屏和手指都好落点（docs/06 §D）。
   */
  @State private viewMode: string = VIEW_LIST;
  @State private filterKey: WindowFilterKey = WindowFilterKey.ALL;
  @State private refreshing: boolean = false;
  /** 下拉刷新时递增，驱动周历重新装配（周历自己按周取数）。 */
  @State private weekTick: number = 0;
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
  segItems: SegmentButtonV2Items = new SegmentButtonV2Items([{ text: '时间窗口' }, { text: '共同计划' }]);
  /**
   * 筛选 Chip 的配置对象：ChipV2 是 @ComponentV2，选中态靠 @Trace activated 驱动，
   * 所以这里刻意不进 @State —— 建一次，切档时在 selectFilter 里逐项写回。
   */
  private chips: ChipV2Options[] = [];
  // 保存动作 / 伴侣档案变更 / 日切重算都会广播重算计数，这里只重读读模型
  @StorageProp('recomputeCount') @Watch('onRecomputeChanged') recomputeCount: number = 0;
  // 跨 Tab 导航广播（首页冲突条、计划页空态引导）：切 Tab 由壳层做，分段由本页认领
  @StorageProp('navToCoTimeCount') @Watch('onNavRequest') navToCoTimeCount: number = 0;
  // 装饰器实参必须是字面量，取值与 SENIOR_MODE_KEY 保持一致。
  @StorageProp('crd_senior_mode') senior: boolean = false;

  aboutToAppear(): void {
    this.buildChips();
    // Tab 内容可能在广播之后才创建，此时 @Watch 不会触发，进页面时补消费一次
    this.applySegmentRequest();
    this.load(true);
  }

  /**
   * 一次性建好筛选 Chip。ChipV2Options/ChipV2Label 都是 @ObservedV2，
   * 之后只改 activated，不再换对象，避免整行重建。
   */
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
        accessibilityDescription: '点按按该条件筛选共同时间',
        onClicked: () => {
          this.selectFilter(f.key);
        }
      }));
    }
    this.chips = chips;
  }

  onRecomputeChanged(): void {
    this.load(false);
  }

  onNavRequest(): void {
    this.applySegmentRequest();
  }

  private applySegmentRequest(): void {
    const seg = takeCoTimeSegment();
    if (seg === COTIME_SEG_PLANS || seg === COTIME_SEG_WINDOW) {
      this.segment = seg;
    }
  }

  // ---------- 数据 ----------

  private nowEpochMin(): number {
    const d = new Date();
    return todayEpochDay() * MIN_PER_DAY + d.getHours() * 60 + d.getMinutes();
  }

  /**
   * 读页面读模型。allowRecompute=true（首次进入 / 用户点重试或重新计算）时，
   * 缓存为空或跨天过期才补一次本机重算；下拉刷新与切筛选传 false，只重读。
   * 筛选档是查询条件：换档就是换一次查询，页面不再自己过滤一遍。
   */
  private async load(allowRecompute: boolean): Promise<void> {
    const filter: WindowFilter = { key: this.filterKey, fromEpochMin: this.nowEpochMin() };
    for (let attempt = 1; attempt <= LOAD_ATTEMPTS; attempt++) {
      try {
        let page = await CommonTimeQueryService.getCommonTimePage(filter, this.nowEpochMin());
        if (allowRecompute && (page.computedAt <= 0 || page.stale)) {
          await ScheduleUseCase.ensureSeeded();
          await ScheduleUseCase.recompute(todayEpochDay());
          page = await CommonTimeQueryService.getCommonTimePage(filter, this.nowEpochMin());
          if (page.computedAt <= 0) {
            // 自己刚写完就读到空表，只能是另一路重算正在 DELETE/INSERT：等它落盘再读一次
            await this.delay(SETTLE_DELAY_MS);
            page = await CommonTimeQueryService.getCommonTimePage(filter, this.nowEpochMin());
          }
        }
        this.page = page;
        this.failed = false;
        this.refreshing = false;
        return;
      } catch (e) {
        if (attempt >= LOAD_ATTEMPTS) {
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
    this.weekTick++;
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
    return who + ' · ' + horizonLabel(p == null ? AppConst.HORIZON_DAYS : p.horizonDays);
  }

  private subtitleColor(): Resource {
    const p = this.page;
    return p != null && p.mode === ExperienceMode.SOLO
      ? DesignTokens.textTertiary : DesignTokens.primary;
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
      return '试试「全部」，或到「我的」里放宽起床/就寝时间。';
    }
    return this.isSolo() ? $r('app.string.cotime_empty_partner_desc') : '检查双方班表与作息参数，或看更长的窗口。';
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

  /**
   * 选中窗口的落地方式：宽屏留在列表右侧的详情栏（列表上下文不丢），
   * 窄屏与周历走原来的半模态。
   */
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

  /**
   * 计划页头部行的出口：切回窗口分段，并把当前筛选下的第一段空闲直接开成建计划入口。
   * 读模型按开始时间升序给行，所以第 0 行就是"下一个窗口"；一段都没有时只切分段，不假装有空档。
   */
  private gotoNextWindow(): void {
    this.segment = COTIME_SEG_WINDOW;
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
    setTimeout(() => {
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
                title: '刷新失败，展示的是上次结果',
                body: '本机数据没有变化，可以稍后再试',
                actionLabel: '重试',
                onAction: () => {
                  this.load(true);
                }
              })
            } else if (this.isStale()) {
              NoticeBar({
                tone: NoticeTone.WARN,
                title: this.staleTitle(),
                body: '班表可能已变化，重算后再确认',
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
                body: '下面的窗口只算到了我的空闲，拿到 TA 的数据后会自动纠正',
                actionLabel: '去看看',
                onAction: () => {
                  this.onOpenRoute(NavRoutes.PAIRING);
                }
              })
            }
          }

          if (this.segment === COTIME_SEG_WINDOW) {
            this.windowBody()
          } else {
            this.plansBody()
          }
        }
        .width('100%')
        .layoutWeight(1)
        .padding({ left: Breakpoints.hPadding(this.bp), right: Breakpoints.hPadding(this.bp) })
        .bindSheet($$this.dayVisible, this.daySheet(), {
          detents: [SheetSize.LARGE],
          dragBar: false,
          showClose: false,
          // 34vp 顶角：原型 .sheet 的圆角，比系统默认更贴糖果贴纸
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
        maskColor: DesignTokens.scrim
      })
    }
  }

  @Builder
  header() {
    Column({ space: 2 }) {
      Text('共同时间')
        .fontSize(DesignTokens.fontTitle)
        .fontFamily(DesignTokens.fontRound)
        .fontWeight(FontWeight.Bolder)
        .fontColor(DesignTokens.textPrimary)
      Text(this.subtitle())
        .fontSize(DesignTokens.fontCaption)
        .fontColor(this.subtitleColor())
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
    .padding({ top: DesignTokens.space5 })
  }

  @Builder
  segmentControl() {
    CapsuleSegment({
      items: this.segItems,
      selectedIndex: this.segment === COTIME_SEG_WINDOW ? 0 : 1,
      onPick: (idx: number) => {
        this.segment = idx === 0 ? COTIME_SEG_WINDOW : COTIME_SEG_PLANS;
      }
    })
  }

  /** 窗口分段：视图切换 + （列表专属）筛选档 + 内容。expanded 的列表走「列表—详情」双栏。 */
  @Builder
  windowBody() {
    Column({ space: DesignTokens.space3 }) {
      Row() {
        Row({ space: DesignTokens.space2 }) {
          this.viewPill('列表', VIEW_LIST)
          this.viewPill('周历', VIEW_WEEK)
        }

        Blank()

        if (this.viewMode === VIEW_LIST && this.page != null) {
          Text('共 ' + this.rows().length + ' 段')
            .fontSize(DesignTokens.fontCaption)
            .fontColor(DesignTokens.textTertiary)
        }
      }
      .width('100%')
      .alignItems(VerticalAlign.Center)

      if (this.viewMode === VIEW_LIST) {
        this.filterRow()
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
      onClose: () => {
        this.onDetailClose();
      }
    })
  }

  @Builder
  viewPill(label: string, mode: string) {
    Text(label)
      .fontSize(DesignTokens.fontCaption)
      // 与胶囊分段同一档糖：当前档白底粉字并浮起来，其余平贴在背板上
      .fontWeight(FontWeight.Bold)
      .fontColor(this.viewMode === mode ? DesignTokens.primary : DesignTokens.textSecondary)
      .textAlign(TextAlign.Center)
      .padding({ left: DesignTokens.space3, right: DesignTokens.space3 })
      .constraintSize({ minHeight: AccessibilityPolicy.minHit(this.senior) })
      .borderRadius(DesignTokens.radiusPill)
      .backgroundColor(this.viewMode === mode ? DesignTokens.card : DesignTokens.fillWeak)
      .shadow(this.viewMode === mode ? DesignTokens.floatShadow() : undefined)
      // 纯文字当按钮：焦点、朗读名都得补上，选中档前缀给读屏，页面上仍只靠底色区分
      .focusable(true)
      .accessibilityText((this.viewMode === mode ? '当前为' : '切换到') + label + '视图')
      .onClick(() => {
        this.viewMode = mode;
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

  /**
   * 列表分段：Refresh 始终包在最外层，四种状态（读取中 / 读取失败 / 没有窗口 / 有窗口）
   * 都能下拉。空态尤其要能下拉——已配对却还没拉到对方数据时，这一屏就是空白的，
   * 用户看到的只有一句"还没有共同时间"，没有下拉就等于只能退回后台再切回来。
   */
  @Builder
  listContent() {
    Refresh({ refreshing: $$this.refreshing, offset: 64, friction: 10 }) {
      if (this.rows().length > 0) {
        // List.space 只收 number/string，收不了 Resource 令牌：值与 space_3(12vp) 对齐
        List({ space: 12 }) {
          ForEach(this.rows(), (w: WindowSummary, idx: number) => {
            ListItem() {
              WindowCard({
                winStart: w.start,
                winEnd: w.end,
                winDuration: w.durationMin,
                displayTags: w.displayTags.join('|'),
                todayEpoch: todayEpochDay(),
                cutTopLeft: idx % 2 === 0,
                onTapCard: () => {
                  this.openSummary(w);
                }
              })
            }
          }, (w: WindowSummary) => w.start + '-' + w.end + '-' + w.channel)
        }
        .width('100%')
        .height('100%')
        .scrollBar(BarState.Off)
        // alwaysEnabled：只有一两张卡时列表不满一屏，默认不响应下拉手势，Refresh 就永远接不到这一次。
        // Scroll 分支不用加——Scroll 的 alwaysEnabled 本来就是 true。
        .edgeEffect(EdgeEffect.Spring, { alwaysEnabled: true })
        .padding({ bottom: DesignTokens.dockClearance })
      } else {
        Scroll() {
          if (this.page == null) {
            if (this.failed) {
              StatePanel({
                kind: StatePanelKind.ERROR,
                title: '共同时间读取失败',
                description: '本机日程数据没有变化，重试一次通常就能恢复。',
                actionLabel: '重试',
                onAction: () => {
                  this.load(true);
                }
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
              onAction: () => {
                this.onEmptyAction();
              }
            })
          }
        }
        .width('100%')
        .height('100%')
        .align(Alignment.Top)
        .scrollBar(BarState.Off)
        .padding({ bottom: DesignTokens.dockClearance })
      }
    }
    .onRefreshing(() => {
      this.onRefresh();
    })
    .width('100%')
    .layoutWeight(1)
  }

  @Builder
  weekContent() {
    Refresh({ refreshing: $$this.refreshing, offset: 64, friction: 10 }) {
      Scroll() {
        EditorialCard({ hero: false, cutTopLeft: true, tappable: false }) {
          WeekScheduleView({
            mode: WEEK_MODE_COMMON,
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
      .scrollBar(BarState.Off)
      .padding({ bottom: DesignTokens.dockClearance })
      .align(Alignment.Top)
    }
    .onRefreshing(() => {
      this.onRefresh();
    })
    .width('100%')
    .layoutWeight(1)
  }

  @Builder
  plansBody() {
    Column() {
      PlansView({
        onGoWindow: () => {
          this.segment = COTIME_SEG_WINDOW;
        },
        onNextWindow: () => {
          this.gotoNextWindow();
        }
      })
    }
    .width('100%')
    .layoutWeight(1)
  }

  @Builder
  skeletonBar(widthText: string, barHeight: Resource, tint: Resource) {
    Row()
      .width(widthText)
      .height(barHeight)
      .borderRadius(DesignTokens.radiusPill)
      .backgroundColor(tint)
  }

  @Builder
  skeleton() {
    Column({ space: DesignTokens.space3 }) {
      EditorialCard({ hero: false, cutTopLeft: true, tappable: false }) {
        Column({ space: DesignTokens.space3 }) {
          this.skeletonBar('42%', DesignTokens.space4, DesignTokens.fillWeak)
          this.skeletonBar('68%', DesignTokens.space3, DesignTokens.fillWeak)
          this.skeletonBar('30%', DesignTokens.space3, DesignTokens.fillWeak)
        }
        .width('100%')
        .alignItems(HorizontalAlign.Start)
      }

      EditorialCard({ hero: false, cutTopLeft: false, tappable: false }) {
        Column({ space: DesignTokens.space3 }) {
          this.skeletonBar('38%', DesignTokens.space4, DesignTokens.fillWeak)
          this.skeletonBar('74%', DesignTokens.space3, DesignTokens.fillWeak)
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
