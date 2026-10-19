import { dayOfStart, nowEpochMin, todayEpochDay } from 'domain';
import { DateLabel, Logger } from 'commons';
import {
  AnswerAction,
  AnswerState,
  CommonTimeQueryService,
  ExperienceMode,
  greetingOf,
  HomeSummary,
  QuickAnswer,
  ScheduleUseCase,
  ScheduleOverviewQueryService,
  TodayAgendaItem,
  WindowSummary
} from 'feature';
import { NavRoutes } from '../navigation/NavRoutes';
import { COTIME_SEG_PLANS, navToCoTime } from '../util/NavUtil';
import { syncOnPull } from '../util/PullRefresh';
import { LatestLanding } from '../util/LatestLanding';
import { LatestReadQueue } from '../util/LatestReadQueue';
import { homeContentKey } from '../util/VisualMotionMath';
import { appToast } from '../util/AppToast';
import { displayTagLine } from '../util/WindowTagUtil';
import { DesignTokens } from '../theme/DesignTokens';
import { EditorialCard } from '../component/EditorialCard';
import { NoticeBar, NoticeTone } from '../component/NoticeBar';
import { SkeletonBar } from '../component/Skeleton';
import { StatePanel, StatePanelKind } from '../component/StatePanel';
import { ConflictNotice } from '../component/ConflictNotice';
import { HeroVariant, NextWindowHero } from '../component/NextWindowHero';
import { QuickAnswerRow } from '../component/QuickAnswerRow';
import { TodayOverview } from '../component/TodayOverview';
import { ScheduleEntrySheet } from '../component/ScheduleEntrySheet';
import { WindowDetailSheet } from '../component/WindowDetailSheet';
import { Breakpoint, Breakpoints } from '../responsive/Breakpoints';
import { ResponsiveContainer } from '../responsive/ResponsiveContainer';
import { FadingScrollViewport, ScrollHeaderState, StickyPageHeader, HeaderDateBadge } from '../component/FadingHeader';

const TAG = 'HomeView';
/** 首次读取的重试次数与间隔：冷启动时 Db 可能还没 init 完。 */
const LOAD_ATTEMPTS = 3;
const RETRY_DELAY_MS = 250;
/** 撞到另一路重算正在写缓存时的等待时长。 */
const SETTLE_DELAY_MS = 300;

/**
 * 首页（答案优先）：一屏内按"下一段共同时间 → 冲突 → 三个答案 → 今天"给结论，
 * 所有结论文本来自 CommonTimeQueryService 的读模型，页面不查仓储、不自行筛选窗口。
 *
 * 刷新口径：首次进入若缓存为空或跨天过期才补一次本机重算；此后的手动刷新只有下拉一种，
 * 下拉会带着本机游标去云上要对方最新的快照（见 syncOnPull）。
 */
@Component
export struct HomeView {
  @Prop @Watch('onActiveChanged') active: boolean = true;
  /** 打开栈内路由（班表 / 配对），由 AppNavigator 注入：页面不持有 NavPathStack，也不解析路由种类。 */
  onOpenRoute: (name: string) => void = (name: string) => {
  };
  @State private home: HomeSummary | null = null;
  @State private agenda: TodayAgendaItem[] = [];
  @State private agendaFailed: boolean = false;
  /** 读模型加载失败：无内容时给整页错误面板，有内容时只挂一条提示，不清空旧结果。 */
  @State private failed: boolean = false;
  @State private refreshing: boolean = false;
  @State private refreshCue: number = 0;
  private pullInFlight: boolean = false;
  private mounted: boolean = false;
  @State private sheetVisible: boolean = false;
  @State private scheduleVisible: boolean = false;
  private sheetOpening: boolean = false;
  @State private sheetStart: number = 0;
  @State private sheetEnd: number = 0;
  @State private sheetTags: string = '';
  /** 本页容器宽度档位：只影响留白与正文封顶，不改答案层级。 */
  @State private bp: Breakpoint = Breakpoint.COMPACT;
  private pageScroller: Scroller = new Scroller();
  @State private headerVisual: ScrollHeaderState = new ScrollHeaderState();
  // 保存动作 / 伴侣档案变更 / 日切重算都会广播重算计数，这里只重读读模型
  @StorageProp('recomputeCount') @Watch('onRecomputeChanged') recomputeCount: number = 0;
  /**
   * 并发读数闸门（D-51）：首帧那次 load(true) 里最坏要走"读→重算→读→等 300ms→读"，
   * 期间任何一次重算广播都会再起一读；先起的那读晚落地就把首页整体念回改前的答案。
   */
  private landing: LatestLanding = new LatestLanding();
  private reads: LatestReadQueue = new LatestReadQueue();
  private needsRecompute: boolean = false;

  aboutToAppear(): void {
    this.mounted = true;
    this.load(true);
  }

  aboutToDisappear(): void {
    this.mounted = false;
    this.landing.begin();
    this.reads.cancel();
  }

  onRecomputeChanged(): void {
    if (!this.pullInFlight) { this.load(false); }
  }
  onActiveChanged(): void {
    if (!this.active) { this.landing.invalidate(); this.reads.cancel(); return; }
    if (this.mounted) this.load(this.home === null);
  }

  // ---------- 数据 ----------

  /**
   * 读首页读模型。allowRecompute=true（首次进入 / 用户点重试或重新计算）时，
   * 缓存为空或跨天过期才补一次本机重算；手动刷新传 false，只重读读模型，
   * 不触发重算、通知注册与云端推送。
   */
  private async load(allowRecompute: boolean): Promise<boolean> {
    if (!this.mounted || !this.active) return false;
    const token = this.landing.begin();
    this.needsRecompute = this.needsRecompute || allowRecompute;
    await this.reads.run(async (): Promise<void> => {
      if (!this.mounted || !this.active) return;
      const recompute = this.needsRecompute; this.needsRecompute = false;
      await this.readHome(recompute, token);
    });
    return this.mounted && this.active && this.home !== null && !this.failed;
  }
  private async readHome(allowRecompute: boolean, token: number): Promise<boolean> {
    // 一次加载只读一次表：三次读数各算各的"现在"，跨午夜那瞬能把同一次渲染劈成两天
    const now = nowEpochMin();
    for (let attempt = 1; attempt <= LOAD_ATTEMPTS; attempt++) {
      try {
        let summary = await CommonTimeQueryService.getHomeSummary(now);
        if (allowRecompute && (summary.computedAt <= 0 || summary.stale)) {
          // 冷启动重算可能还在路上：此时缓存为空或属于昨天，补算一次再渲染，
          // 否则首页会先告诉用户"没有窗口"，等到下一次广播才纠正
          await ScheduleUseCase.ensureSeeded();
          await ScheduleUseCase.recompute(todayEpochDay(), true);
          summary = await CommonTimeQueryService.getHomeSummary(now);
          if (summary.computedAt <= 0) {
            // 自己刚写完就读到空表，只能是另一路重算正在 DELETE/INSERT：等它落盘再读一次
            await this.delay(SETTLE_DELAY_MS);
            summary = await CommonTimeQueryService.getHomeSummary(now);
          }
        }
        let agenda: TodayAgendaItem[] = [];
        let agendaFailed = false;
        try {
          agenda = await ScheduleOverviewQueryService.getTodayAgenda(dayOfStart(now));
        } catch (e) {
          agendaFailed = true;
          Logger.warn(TAG, 'today agenda unavailable: ' + (e as Error).message);
        }
        if (!this.landing.isCurrent(token)) {
          return false;
        }
        this.home = summary;
        this.agenda = agenda;
        this.agendaFailed = agendaFailed;
        this.failed = false;
        return true;
      } catch (e) {
        if (attempt >= LOAD_ATTEMPTS) {
          if (!this.landing.isCurrent(token)) {
            return false;
          }
          // 有旧结果就不清空，只把状态标成可恢复错误（提示条在内容上方）
          this.failed = true;
          Logger.error(TAG, 'load home summary failed: ' + (e as Error).message);
          return false;
        }
        await this.delay(RETRY_DELAY_MS);
      }
    }
    return false;
  }

  private delay(ms: number): Promise<void> {
    return new Promise<void>((resolve) => {
      setTimeout(() => {
        resolve();
      }, ms);
    });
  }

  /**
   * 下拉刷新：重算一遍视界，已配对时这一步就把对方最新的快照拉下来。
   * 等本次读模型落地才收转圈；反馈仅说明首页变化，不冒充云同步成功。
   */
  private async onRefresh(): Promise<void> {
    if (this.pullInFlight) { return; }
    this.pullInFlight = true;
    const before = homeContentKey(this.home, this.agenda, this.agendaFailed);
    try {
      const recomputed = await syncOnPull();
      if (!this.mounted) { return; }
      const loaded = await this.load(false);
      if (!this.mounted) { return; }
      if (!recomputed || !loaded) {
        appToast('首页暂未更新，请再试一次');
      } else if (this.agendaFailed) {
        appToast('今日安排暂未读到，请再试一次');
      } else if (before === homeContentKey(this.home, this.agenda, this.agendaFailed)) {
        appToast('首页内容没有变化');
      } else {
        this.refreshCue++;
        appToast('首页已更新');
      }
    } finally {
      this.pullInFlight = false;
      if (this.mounted) { this.refreshing = false; }
    }
  }

  // ---------- 读模型取值（集中处理空值，build 里不做可空判断） ----------

  private isSolo(): boolean {
    const h = this.home;
    return h != null && h.mode === ExperienceMode.SOLO;
  }

  private isStale(): boolean {
    const h = this.home;
    return h != null && h.stale;
  }

  private next(): WindowSummary | null {
    const h = this.home;
    return h == null ? null : h.nextWindow;
  }

  private winStart(): number {
    const w = this.next();
    return w == null ? 0 : w.start;
  }

  private winEnd(): number {
    const w = this.next();
    return w == null ? 0 : w.end;
  }

  private winDuration(): number {
    const w = this.next();
    return w == null ? 0 : w.durationMin;
  }

  /**
   * Hero 末行念**分类结论**（完整同休日 / 含周末 / 可出行），与窗口卡、详情半模态同一份收敛口径：
   * 原型那一行是「完整同休日」，而读模型的副标题把分类和特征标签（含餐点 · 半天以上）串在一起，
   * 完整同休日会被盖在后面（D-17 定稿）。三条分类都不沾时退回副标题——末行空着比少一项更糟。
   */
  private winSubtitle(): string {
    const w = this.next();
    if (w == null) {
      return '';
    }
    const cls = displayTagLine(w.tags);
    return cls === '' ? w.subtitle : cls.split('|').join(' · ');
  }

  private conflictCount(): number {
    const h = this.home;
    return h == null ? 0 : h.conflictCount;
  }

  private conflictReason(): string {
    const h = this.home;
    return h == null ? '' : h.conflictReason;
  }

  private partnerName(): string {
    const h = this.home;
    if (h == null || h.partnerName === '') {
      return '';
    }
    return h.partnerName;
  }

  private todayMy(): string {
    const h = this.home;
    return h == null ? '' : h.today.myText;
  }

  private todayPartner(): string {
    const h = this.home;
    return h == null ? '' : h.today.partnerText;
  }

  private todayCommon(): string {
    const h = this.home;
    return h == null ? '' : h.today.commonText;
  }

  private heroVariant(): HeroVariant {
    const h = this.home;
    if (h == null) {
      return HeroVariant.NO_WINDOW;
    }
    // 单人形态与"已录入但今天拿不到 TA 的数据"都走引导 Hero（与精简原型一致）
    if (h.mode === ExperienceMode.SOLO || h.tonight.state === AnswerState.UNKNOWN) {
      return HeroVariant.NEED_PARTNER;
    }
    return h.nextWindow == null ? HeroVariant.NO_WINDOW : HeroVariant.WINDOW;
  }

  /** 分档规则在 feature/model/RhythmRules（entry/src/main 不在离线编译树里，留在本地就测不到）。 */
  private greeting(): string {
    return greetingOf(new Date().getHours());
  }

  private subtitle(): string {
    const h = this.home;
    if (h == null) {
      return '正在读取本机日程';
    }
    if (h.mode === ExperienceMode.SOLO) {
      return '单人模式 · 只算我的空闲';
    }
    const name = h.partnerName === '' ? 'TA' : h.partnerName;
    if (h.tonight.state === AnswerState.UNKNOWN) {
      return '还不知道 ' + name + ' 今天的日程';
    }
    return '和 ' + name + ' 的时间 · ' + (h.mode === ExperienceMode.PAIRED ? '已配对' : '本机代录');
  }

  private sealDay(): string {
    return '' + DateLabel.ymd(todayEpochDay()).d;
  }

  private sealMonth(): string {
    return DateLabel.ymd(todayEpochDay()).m + '月';
  }

  /** 过期那一格的标题：读的是上一次计算落在哪天（失败态另有节点，不共用这一句）。 */
  private staleTitle(): string {
    const h = this.home;
    const day = h == null ? todayEpochDay() : todayEpochDay(h.computedAt);
    return '结果基于 ' + DateLabel.mdw(day) + ' 的计算';
  }

  private tonightQuestion(): string {
    return this.isSolo() ? '今晚我有空吗' : '今晚能一起吗';
  }

  private fullDayQuestion(): string {
    // D-14：单人态不另起一个名字——窗口标签（WindowTagUtil）在同一屏就念「完整同休日」。
    return '下个完整同休日';
  }

  // ---------- 交互 ----------

  /** 答案行点击：跳转意图由读模型给出，页面不自行推断目标。 */
  private follow(answer: QuickAnswer | null): void {
    if (answer == null) {
      return;
    }
    if (answer.action === AnswerAction.OPEN_WINDOW) {
      this.openWindow(answer.windowStart, answer.windowEnd);
      return;
    }
    if (answer.action === AnswerAction.OPEN_PARTNER) {
      this.onOpenRoute(NavRoutes.PAIRING);
      return;
    }
    this.onOpenRoute(NavRoutes.SCHEDULE_HUB);
  }

  private openTonight(): void {
    const h = this.home;
    this.follow(h == null ? null : h.tonight);
  }

  private openFullRestDay(): void {
    const h = this.home;
    this.follow(h == null ? null : h.fullRestDay);
  }

  private openTrip(): void {
    const h = this.home;
    this.follow(h == null ? null : h.trip);
  }

  private openHero(): void {
    const variant = this.heroVariant();
    if (variant === HeroVariant.WINDOW) {
      this.openWindow(this.winStart(), this.winEnd());
      return;
    }
    if (variant === HeroVariant.NEED_PARTNER) {
      this.onOpenRoute(NavRoutes.PAIRING);
    }
  }

  /** 「＋ 计划」：有下一段窗口就地建计划，没有就去补日程。 */
  private openPlan(): void {
    const w = this.next();
    if (w != null) {
      this.openWindow(w.start, w.end);
      return;
    }
    this.onOpenRoute(NavRoutes.SCHEDULE_HUB);
  }

  /** 冲突详情在共同时间的计划分段里处理（含改期建议），首页只报数量并指名分段。 */
  private openConflicts(): void {
    navToCoTime(COTIME_SEG_PLANS);
  }

  private async openWindow(start: number, end: number): Promise<void> {
    if (this.sheetOpening || this.sheetVisible || start <= 0 || end <= start) {
      return;
    }
    this.sheetOpening = true;
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
    this.sheetVisible = true;
    this.sheetOpening = false;
  }

  @Builder
  detailSheet() {
    WindowDetailSheet({
      winStart: this.sheetStart,
      winEnd: this.sheetEnd,
      winTags: this.sheetTags,
      onCreated: () => navToCoTime(COTIME_SEG_PLANS),
      onClose: () => {
        this.sheetVisible = false;
      }
    })
  }

  // ---------- 骨架屏 ----------

  @Builder
  skeleton() {
    Column({ space: DesignTokens.space3 }) {
      EditorialCard({ hero: true, cutTopLeft: true, tappable: false }) {
        Column({ space: DesignTokens.space3 }) {
          SkeletonBar({ barWidth: '52%', barHeight: DesignTokens.space3, tint: DesignTokens.heroGlow })
          SkeletonBar({ barWidth: '70%', barHeight: DesignTokens.space6, tint: DesignTokens.heroGlow })
          SkeletonBar({ barWidth: '44%', barHeight: DesignTokens.space3, tint: DesignTokens.heroGlow })
        }
        .width('100%')
        .alignItems(HorizontalAlign.Start)
      }
      EditorialCard({ hero: false, cutTopLeft: false, tappable: false }) {
        Column({ space: DesignTokens.space4 }) {
          SkeletonBar({ barWidth: '38%' })
          SkeletonBar({ barWidth: '86%' })
          SkeletonBar({ barWidth: '72%' })
          SkeletonBar({ barWidth: '60%' })
        }
        .width('100%')
        .alignItems(HorizontalAlign.Start)
      }
    }
    // 骨架条本身没有文字，读屏用户只会听到一连串空白；合成一句进度说明
    .width('100%')
    .accessibilityGroup(true)
    .accessibilityText('正在读取本机日程')
  }

  // ---------- 页头 ----------

  @Builder
  header() {
    StickyPageHeader({
      title: '两人份', subtitle: this.greeting() + ' · ' + this.subtitle(),
      visual: this.headerVisual, horizontalPadding: Breakpoints.hPadding(this.bp),
      maxContentWidth: Breakpoints.contentMaxWidth(this.bp),
      trailing: () => { this.dateBadge(); }
    })
    .hitTestBehavior(HitTestMode.Transparent)
  }

  @Builder
  dateBadge() {
    HeaderDateBadge({ day: this.sealDay(), month: this.sealMonth(), visual: this.headerVisual,
      spokenDate: '今天 ' + DateLabel.mdw(todayEpochDay()) })
  }

  build() {
    ResponsiveContainer({ breakpoint: this.bp }) {
      Column() {
        this.header()
        Column() {
          FadingScrollViewport({ fadeHeight: 16, visual: this.headerVisual }) {
            Refresh({ refreshing: $$this.refreshing, offset: 64, friction: 10 }) {
              Scroll(this.pageScroller) {
                Column({ space: DesignTokens.space3 }) {
                  if (this.home == null) {
                    if (this.failed) {
                      StatePanel({
                        kind: StatePanelKind.ERROR,
                        title: '首页读取失败',
                        description: '手机里的数据没有变化，再下拉一次或点重试通常就好。',
                        actionLabel: '重试',
                        onAction: () => {
                          this.load(true);
                        }
                      })
                    } else {
                      this.skeleton()
                    }
                  } else {
                    if (this.failed) {
                      // 这一串四种说法各挂一颗节点，门槛与句子一一对得上（共同页与「我的」配对卡同一口径）。
                      // 换句子这件事本身由 NoticeBar 的说法字段是 @Prop 保证（D-46）。
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

                    NextWindowHero({
                      refreshCue: this.refreshCue,
                      variant: this.heroVariant(),
                      experience: this.home.mode,
                      todayEpoch: todayEpochDay(),
                      winStart: this.winStart(),
                      winEnd: this.winEnd(),
                      winDuration: this.winDuration(),
                      winSubtitle: this.winSubtitle(),
                      onTapHero: () => {
                        this.openHero();
                      }
                    })

                    if (this.conflictCount() > 0) {
                      ConflictNotice({
                        conflictCount: this.conflictCount(),
                        reason: this.conflictReason(),
                        onTap: () => {
                          this.openConflicts();
                        }
                      })
                    }

                    EditorialCard({ hero: false, cutTopLeft: true, tappable: false }) {
                      Column() {
                        QuickAnswerRow({
                          revealDelay: 0,
                          question: this.tonightQuestion(),
                          answerState: this.home.tonight.state,
                          headline: this.home.tonight.headline,
                          supporting: this.home.tonight.supportingText,
                          onTap: () => {
                            this.openTonight();
                          }
                        })
                        QuickAnswerRow({
                          revealDelay: 45,
                          question: this.fullDayQuestion(),
                          showDivider: true,
                          answerState: this.home.fullRestDay.state,
                          headline: this.home.fullRestDay.headline,
                          supporting: this.home.fullRestDay.supportingText,
                          onTap: () => {
                            this.openFullRestDay();
                          }
                        })
                        QuickAnswerRow({
                          question: '最近能出行吗',
                          revealDelay: 90,
                          showDivider: true,
                          answerState: this.home.trip.state,
                          headline: this.home.trip.headline,
                          supporting: this.home.trip.supportingText,
                          onTap: () => {
                            this.openTrip();
                          }
                        })
                      }
                      .width('100%')
                      .alignItems(HorizontalAlign.Start)
                    }

                    TodayOverview({
                      myText: this.todayMy(),
                      partnerText: this.todayPartner(),
                      commonText: this.todayCommon(),
                      partnerVisible: !this.isSolo(),
                      partnerName: this.partnerName(),
                      weekdayText: DateLabel.mdw(todayEpochDay()),
                      agenda: this.agenda,
                      agendaFailed: this.agendaFailed,
                      onEditSchedule: () => {
                        this.scheduleVisible = true;
                      },
                      onAddPlan: () => {
                        this.openPlan();
                      }
                    })
                    .bindSheet($$this.scheduleVisible, this.scheduleEntry(), {
                      height: SheetSize.FIT_CONTENT, detents: [SheetSize.FIT_CONTENT], preferType: SheetType.BOTTOM,
                      dragBar: false, showClose: false, backgroundColor: DesignTokens.card, maskColor: DesignTokens.scrim
                    })
                  }
                }
                // 宽屏只收正文宽度和留白，答案层级不变：Scroll 的 align(Top) 会把这列居中
                .width('100%')
                .constraintSize({ maxWidth: Breakpoints.contentMaxWidth(this.bp) })
                .padding({
                  left: Breakpoints.hPadding(this.bp),
                  right: Breakpoints.hPadding(this.bp),
                  top: 8,
                  bottom: DesignTokens.dockClearance
                })
              }
              .width('100%')
              .height('100%')
              // 页面底画在最外层：渐变要像原型的 #screen 那样定住，滚动容器自己不能再铺底
              .backgroundColor(Color.Transparent)
              .align(Alignment.Top)
              .scrollBar(BarState.Off)
              .onAppear(() => { this.headerVisual.update(this.pageScroller.currentOffset().yOffset); })
              .onDidScroll(() => {
                this.headerVisual.update(this.pageScroller.currentOffset().yOffset);
              })
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
            .onRefreshing(() => {
              this.onRefresh();
            })
            .width('100%')
            .height('100%')
          }
        }
        .width('100%').layoutWeight(1)
      }
      .width('100%')
      .height('100%')
      .linearGradient(DesignTokens.pageGradient())
    }
  }
  @Builder
  scheduleEntry() { ScheduleEntrySheet({onClose:() => {this.scheduleVisible=false;}}) }
}
