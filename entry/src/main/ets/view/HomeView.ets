import { nowEpochMin, todayEpochDay } from 'domain';
import { DateLabel, Logger } from 'commons';
import { PAIRED } from 'data';
import {
  AnswerAction,
  AnswerState,
  CommonTimeQueryService,
  ExperienceMode,
  FeatureFlags,
  greetingOf,
  HomeSummary,
  ProfileSettingsService,
  QuickAnswer,
  ScheduleUseCase,
  SYNC_STATE_BLOCKED,
  SyncState,
  SYNC_STATE_OK,
  syncStateNoteOf,
  syncStateTitleOf,
  syncTroubleOf,
  WindowSummary
} from 'feature';
import { NavRoutes } from '../navigation/NavRoutes';
import { COTIME_SEG_PLANS, navToCoTime } from '../util/NavUtil';
import { syncOnPull } from '../util/PullRefresh';
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
import { WindowDetailSheet } from '../component/WindowDetailSheet';
import { Breakpoint, Breakpoints } from '../responsive/Breakpoints';
import { ResponsiveContainer } from '../responsive/ResponsiveContainer';

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
  /** 打开栈内路由（班表 / 配对），由 AppNavigator 注入：页面不持有 NavPathStack，也不解析路由种类。 */
  onOpenRoute: (name: string) => void = (name: string) => {
  };
  @State private home: HomeSummary | null = null;
  /** 读模型加载失败：无内容时给整页错误面板，有内容时只挂一条提示，不清空旧结果。 */
  @State private failed: boolean = false;
  /** 配对状态 + 云同步三态：只为决定要不要挂那一条降级提示，页面不据此改算任何东西。 */
  @State private pairState: string = '';
  @State private syncState: SyncState = { outcome: SYNC_STATE_OK, day: 0, code: '' };
  @State private refreshing: boolean = false;
  @State private sheetVisible: boolean = false;
  @State private sheetStart: number = 0;
  @State private sheetEnd: number = 0;
  @State private sheetTags: string = '';
  /** 本页容器宽度档位：只影响留白与正文封顶，不改答案层级。 */
  @State private bp: Breakpoint = Breakpoint.COMPACT;
  // 保存动作 / 伴侣档案变更 / 日切重算都会广播重算计数，这里只重读读模型
  @StorageProp('recomputeCount') @Watch('onRecomputeChanged') recomputeCount: number = 0;

  aboutToAppear(): void {
    this.load(true);
  }

  onRecomputeChanged(): void {
    this.load(false);
  }

  // ---------- 数据 ----------

  /**
   * 读首页读模型。allowRecompute=true（首次进入 / 用户点重试或重新计算）时，
   * 缓存为空或跨天过期才补一次本机重算；手动刷新传 false，只重读读模型，
   * 不触发重算、通知注册与云端推送。
   */
  private async load(allowRecompute: boolean): Promise<void> {
    // 一次加载只读一次表：三次读数各算各的"现在"，跨午夜那瞬能把同一次渲染劈成两天
    const now = nowEpochMin();
    for (let attempt = 1; attempt <= LOAD_ATTEMPTS; attempt++) {
      try {
        let summary = await CommonTimeQueryService.getHomeSummary(now);
        if (allowRecompute && (summary.computedAt <= 0 || summary.stale)) {
          // 冷启动重算可能还在路上：此时缓存为空或属于昨天，补算一次再渲染，
          // 否则首页会先告诉用户"没有窗口"，等到下一次广播才纠正
          await ScheduleUseCase.ensureSeeded();
          await ScheduleUseCase.recompute(todayEpochDay());
          summary = await CommonTimeQueryService.getHomeSummary(now);
          if (summary.computedAt <= 0) {
            // 自己刚写完就读到空表，只能是另一路重算正在 DELETE/INSERT：等它落盘再读一次
            await this.delay(SETTLE_DELAY_MS);
            summary = await CommonTimeQueryService.getHomeSummary(now);
          }
        }
        this.home = summary;
        this.failed = false;
        this.pairState = ProfileSettingsService.getPairState();
        this.syncState = ProfileSettingsService.getCloudSyncState();
        return;
      } catch (e) {
        if (attempt >= LOAD_ATTEMPTS) {
          // 有旧结果就不清空，只把状态标成可恢复错误（提示条在内容上方）
          this.failed = true;
          Logger.error(TAG, 'load home summary failed: ' + (e as Error).message);
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

  /**
   * 下拉刷新：重算一遍视界，已配对时这一步就把对方最新的快照拉下来。
   * 重算完成的广播会带动本页重读读模型，这里只负责把转圈落回地面。
   */
  private async onRefresh(): Promise<void> {
    await syncOnPull();
    this.refreshing = false;
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

  /**
   * 云同步那两格坏结论（待重试 / 已降级）要不要在这页挂出来（协议 §3.4 末行：UI 只消费这三态）。
   * 判据与「我的 · 配对卡」逐字相同，两句用的是同一份 `syncStateTitleOf` / `syncStateNoteOf`，
   * 不为首页另写一套说法——同一件事在两个页面两种口径，正是最终验收 R1 点过的那类问题。
   * 未配对不出：偏好里残留的降级结论讲的是上一段配对时的事，挂在单人首页等于编造一个不存在的通路。
   */
  private cloudTrouble(): boolean {
    return FeatureFlags.cloudPairing && this.pairState === PAIRED && syncTroubleOf(this.syncState);
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
    this.sheetVisible = true;
  }

  @Builder
  detailSheet() {
    WindowDetailSheet({
      winStart: this.sheetStart,
      winEnd: this.sheetEnd,
      winTags: this.sheetTags,
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
    Row() {
      Column({ space: 2 }) {
        Text(this.greeting())
          .fontSize(DesignTokens.fontTitle)
          .fontFamily(DesignTokens.fontRound)
          .fontWeight(FontWeight.Bolder)
          .fontColor(DesignTokens.textPrimary)
        Text(this.subtitle())
          .fontSize(DesignTokens.fontCaption)
          .fontColor(this.isSolo() ? DesignTokens.textTertiary : DesignTokens.primary)
      }
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1)
      // 问候语单独念没信息量，和"和谁的时间"合成一句
      .accessibilityGroup(true)
      .accessibilityText(this.greeting() + '，' + this.subtitle())

      // 日期印章：7 分甜把它从"旋转的圆章"改成"浮在页眉上的一颗白方块"
      Column() {
        Text(this.sealDay())
          .fontSize(DesignTokens.fontCaption)
          .fontFamily(DesignTokens.fontRound)
          .fontWeight(800)
          .fontColor(DesignTokens.primary)
        Text(this.sealMonth())
          .fontSize(DesignTokens.fontCaption)
          .fontFamily(DesignTokens.fontRound)
          .fontWeight(800)
          .fontColor(DesignTokens.primary)
          .opacity(0.72)
      }
      .width(48)
      .height(48)
      .justifyContent(FlexAlign.Center)
      .alignItems(HorizontalAlign.Center)
      .borderRadius(DesignTokens.radiusHeroCut)
      .backgroundColor(DesignTokens.card)
      .shadow(DesignTokens.floatShadow())
      .margin({ left: DesignTokens.space3 })
      // 「22 / 9月」两行分开读会变成一个孤零零的数字，这里念成完整日期
      .accessibilityGroup(true)
      .accessibilityText('今天 ' + DateLabel.mdw(todayEpochDay()))
    }
    .width('100%')
    .alignItems(VerticalAlign.Top)
    .padding({ top: DesignTokens.space5, bottom: DesignTokens.space1 })
  }

  build() {
    ResponsiveContainer({ breakpoint: this.bp }) {
      Stack() {
        Refresh({ refreshing: $$this.refreshing, offset: 64, friction: 10 }) {
          Scroll() {
            Column({ space: DesignTokens.space3 }) {
              this.header()

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
                  // 这一串四种说法各挂一颗节点：NoticeBar 的 tone/title/body 是普通成员，父页重渲染
                  // 不更新它们，只有整颗拆掉重挂才换得了那一句（共同页与「我的」配对卡同一口径）。
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
                } else if (this.cloudTrouble() && this.syncState.outcome === SYNC_STATE_BLOCKED) {
                  // 三态里唯一会改变这一页读数的坏消息：TA 那一半是本机上的旧一份。
                  NoticeBar({
                    tone: NoticeTone.ERROR,
                    title: syncStateTitleOf(this.syncState),
                    body: syncStateNoteOf(this.syncState)
                  })
                } else if (this.cloudTrouble()) {
                  NoticeBar({
                    tone: NoticeTone.WARN,
                    title: syncStateTitleOf(this.syncState),
                    body: syncStateNoteOf(this.syncState)
                  })
                }

                NextWindowHero({
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
                      question: this.tonightQuestion(),
                      answerState: this.home.tonight.state,
                      headline: this.home.tonight.headline,
                      supporting: this.home.tonight.supportingText,
                      onTap: () => {
                        this.openTonight();
                      }
                    })
                    QuickAnswerRow({
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
                  onEditSchedule: () => {
                    this.onOpenRoute(NavRoutes.SCHEDULE_HUB);
                  },
                  onAddPlan: () => {
                    this.openPlan();
                  }
                })
              }
            }
            // 宽屏只收正文宽度和留白，答案层级不变：Scroll 的 align(Top) 会把这列居中
            .width('100%')
            .constraintSize({ maxWidth: Breakpoints.contentMaxWidth(this.bp) })
            .padding({
              left: Breakpoints.hPadding(this.bp),
              right: Breakpoints.hPadding(this.bp),
              bottom: DesignTokens.dockClearance
            })
          }
          .width('100%')
          .height('100%')
          // 页面底画在最外层：渐变要像原型的 #screen 那样定住，滚动容器自己不能再铺底
          .backgroundColor(Color.Transparent)
          .align(Alignment.Top)
          .scrollBar(BarState.Off)
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
      .width('100%')
      .height('100%')
      .linearGradient(DesignTokens.pageGradient())
    }
  }
}
