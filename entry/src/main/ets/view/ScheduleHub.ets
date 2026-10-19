import { router, SegmentButtonV2Items } from '@kit.ArkUI';
import { OWNER_ME, OWNER_PARTNER, defaultParams } from 'domain';
import { ScheduleOverview, ScheduleOverviewQueryService } from 'feature';
import { Logger } from 'commons';
import { DesignTokens } from '../theme/DesignTokens';
import { ownerParam } from '../model/RouteParams';
import { EditorialCard } from '../component/EditorialCard';
import { EditorialSection } from '../component/EditorialSection';
import { CapsuleSegment } from '../component/CapsuleSegment';
import { StatePanel, StatePanelKind } from '../component/StatePanel';
import { WeekScheduleView } from '../component/WeekScheduleView';
import { DayShiftSheet } from '../component/DayShiftSheet';
import { pushPendingRoute } from '../util/NavUtil';
import { syncOnPull } from '../util/PullRefresh';
import { readScrollY } from '../util/ScrollOffset';
import { LatestLanding } from '../util/LatestLanding';
import { NavRoutes } from '../navigation/NavRoutes';
import { AccessibilityPolicy } from '../accessibility/AccessibilityPolicy';
import { Breakpoint, Breakpoints } from '../responsive/Breakpoints';
import { ResponsiveContainer } from '../responsive/ResponsiveContainer';
import { FadingHeaderSurface, FadingScrollViewport, ScrollHeaderState } from '../component/FadingHeader';

/** 录入链路页（仍是 @Entry router 页）：路由名即 pages 下的 url 后缀。 */
const PAGE_CYCLE = 'pages/CycleEditor';
const PAGE_COURSE = 'pages/CourseImport';

const TAG = 'ScheduleHub';

/** 本页的两个视图：周历单独成视图，概况统计与管理入口合成另一个。 */
const VIEW_WEEK = 'week';
const VIEW_MANAGE = 'manage';

/** 读失败时的占位：0 是"确实没有"，破折号才是"不知道"，两者不能混用（D-22）。 */
const STAT_UNKNOWN = '—';

/** 读模型摘要项。@Builder 传两个及以上参数时不参与动态渲染，所以四项合成一个对象字面量按引用传。 */
interface StatCell {
  value: string;
  label: string;
}

interface SidePillArg {
  label: string;
  partner: boolean;
}

/** 主入口条目。page 为空串的条目开本页的 sheet，不跳页。 */
interface EntryItem {
  key: string;
  glyph: Resource;
  title: string;
  desc: string;
  page: string;
}

const MAIN_ENTRIES: EntryItem[] = [
  {
    key: 'week', glyph: $r('sys.symbol.calendar'), title: '周班表',
    desc: '排班、复制或按周重复', page: PAGE_CYCLE
  },
  {
    key: 'course', glyph: $r('sys.symbol.square_and_pencil'), title: '课程表',
    desc: '导入课表或手动添加', page: PAGE_COURSE
  }
];

/** 日程录入页：从底部 Tab 降级为「我的 · 我的日程」里的栈目的地。 */
@Component
export struct ScheduleHub {
  /** 壳层 pushPathByName 带入的侧别：不传落在「我」，传 PARTNER 直接落在 TA 侧。 */
  initialOwner: string = OWNER_ME;
  /** 返回动作由壳层注入：pop 的是它手里的 NavPathStack，本页够不到。 */
  onBack: () => void = () => {
  };
  @State private side: string = OWNER_ME;
  /** 本机是否代录过伴侣（有档案或 owner=PARTNER 数据）；纯云端配对不算代录。 */
  @State private partnerLocal: boolean = false;
  @State private types: number = 0;
  @State private tplSet: boolean = false;
  @State private ovs: number = 0;
  @State private courses: number = 0;
  /** 读模型给的视界天数：文案与统计区间都用它；首帧先用引擎默认，读模型回来即替换。 */
  @State private horizon: number = defaultParams().horizonDays;
  /** 摘要读失败态：读失败与"真的没数据"必须分开画，否则会把已录入的人引去重复录入（D-22）。 */
  @State private statusFailed: boolean = false;
  @State private dayVisible: boolean = false;
  @State private dayEpoch: number = -1;
  /** 本页容器宽度档位：expanded 把两组录入入口并排，正文按可读宽度收拢。 */
  @State private bp: Breakpoint = Breakpoint.COMPACT;
  /** 当前视图：进来默认落在周历——来这一页多半是看哪天能改，管理入口放第二屏。 */
  @State private hubView: string = VIEW_WEEK;
  /** 下拉刷新的转圈：重算（含向云上要一次对方快照）落地后才收。 */
  @State private refreshing: boolean = false;
  /** 周历与日程管理入口。 */
  segItems: SegmentButtonV2Items = new SegmentButtonV2Items([{ text: '我的班表' }, { text: '日程管理' }]);
  // 装饰器实参必须是字面量，取值与 SENIOR_MODE_KEY 保持一致。
  @StorageProp('crd_senior_mode') senior: boolean = false;
  // 保存动作 → 重算广播 → 伴侣侧数据可能刚被增删，摘要与 TA 可见性都要跟着刷
  @StorageProp('recomputeCount') @Watch('onRecomputeChanged') recomputeCount: number = 0;
  /** 只接受当前侧最后一次查询的结果。 */
  private landing: LatestLanding = new LatestLanding();
  private hubScroller: Scroller = new Scroller();
  @State private scrollVisual: ScrollHeaderState = new ScrollHeaderState();

  aboutToAppear(): void {
    this.side = this.initialOwner === OWNER_PARTNER ? OWNER_PARTNER : OWNER_ME;
    this.loadStatus();
  }

  aboutToDisappear(): void {
    this.landing.begin();
  }

  onRecomputeChanged(): void {
    this.loadStatus();
  }

  /** 当前侧录入概况与本机代录可见性。 */
  async loadStatus(): Promise<void> {
    const token = this.landing.begin();
    try {
      const ov: ScheduleOverview = await ScheduleOverviewQueryService.getOverview(this.side);
      if (!this.landing.isCurrent(token)) {
        return;
      }
      this.types = ov.shiftTypes;
      this.tplSet = ov.hasTemplate;
      this.ovs = ov.overrides;
      this.courses = ov.courses;
      this.horizon = ov.horizonDays;
      this.partnerLocal = ov.partnerLocal;
      this.statusFailed = false;
    } catch (e) {
      if (!this.landing.isCurrent(token)) {
        return;
      }
      Logger.warn(TAG, 'overview read failed: ' + (e as Error).name + ': ' + (e as Error).message);
      this.statusFailed = true;
    }
  }

  private sideTitle(): string {
    return this.isPartnerSide() ? 'TA 的日程' : '我的日程';
  }

  private isPartnerSide(): boolean {
    return this.side === OWNER_PARTNER;
  }

  go(page: string): void {
    router.pushUrl({ url: page, params: ownerParam(this.side) });
  }

  private requestBack(): void {
    this.onBack();
  }

  private pickSide(partner: boolean): void {
    const next = partner ? OWNER_PARTNER : OWNER_ME;
    if (next === this.side) {
      return;
    }
    this.side = next;
    this.loadStatus();
  }

  private openDay(epochDay: number): void {
    this.dayEpoch = epochDay;
    this.dayVisible = true;
  }

  @Builder
  daySheet() {
    if (this.dayEpoch >= 0) {
      DayShiftSheet({ owner: this.side, epochDay: this.dayEpoch,
        onClose: () => { this.dayVisible = false; } })
    }
  }

  @Builder
  sidePill(item: SidePillArg) {
    Text(item.label)
      .fontSize(DesignTokens.fontCaption)
      .fontWeight(FontWeight.Bold)
      .fontColor(this.isPartnerSide() === item.partner ? DesignTokens.textAccent : DesignTokens.textSecondary)
      .textAlign(TextAlign.Center)
      .layoutWeight(1)
      .padding({ top: DesignTokens.space2, bottom: DesignTokens.space2 })
      .constraintSize({ minHeight: AccessibilityPolicy.minHit(this.senior) })
      .borderRadius(DesignTokens.radiusPill)
      .backgroundColor(this.isPartnerSide() === item.partner ? DesignTokens.card : Color.Transparent)
      .shadow(this.isPartnerSide() === item.partner ? DesignTokens.floatShadow() : undefined)
      .focusable(true)
      // 选中的那一侧只剩底色区别，读屏要念出"当前"
      .accessibilityText(this.isPartnerSide() === item.partner ? '当前查看' + item.label : '切换到' + item.label)
      .clickEffect(DesignTokens.tapChip())
      .onClick(() => this.pickSide(item.partner))
  }

  /** 条目行：图标 + 主副文本 + 箭头，整行 44vp 以上热区。 */
  @Builder
  entryRow(item: EntryItem) {
    Row({ space: DesignTokens.space3 }) {
      SymbolGlyph(item.glyph)
        .fontSize(20)
        .fontColor([DesignTokens.primary])
        // 主副文案已经说清了这一条是干什么的，图标只是重复提示
        .accessibilityLevel('no')
      Column({ space: 2 }) {
        Text(item.title)
          .fontSize(DesignTokens.fontBody)
          .fontWeight(FontWeight.Medium)
          .fontColor(DesignTokens.textPrimary)
        Text(item.desc)
          .fontSize(DesignTokens.fontCaption)
          .fontColor(DesignTokens.textTertiary)
      }
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1)

      SymbolGlyph($r('sys.symbol.chevron_right'))
        .fontSize(16).fontColor([DesignTokens.textDisabled])
        .accessibilityLevel('no')
    }
    .width('100%')
    .padding(DesignTokens.space3)
    .constraintSize({ minHeight: AccessibilityPolicy.minHit(this.senior) })
    .alignItems(VerticalAlign.Center)
    .focusable(true)
    .accessibilityGroup(true)
    .accessibilityText(item.title + '。' + item.desc)
    .onClick(() => {
      this.go(item.page);
    })
  }

  @Builder
  summaryCard() {
    EditorialCard({ hero: false, cutTopLeft: true, tappable: false }) {
      Column({ space: DesignTokens.space3 }) {
        Row() {
          Text(this.sideTitle())
            .fontSize(DesignTokens.fontTitle)
            .fontFamily(DesignTokens.fontRound)
            .fontWeight(FontWeight.Bolder)
            .fontColor(DesignTokens.textPrimary)
            .layoutWeight(1)
          if (this.statusFailed) {
            Text('读取失败').fontSize(DesignTokens.fontCaption)
              .fontColor(DesignTokens.warn)
          } else if (this.isConfigured()) {
            Text('已录入').fontSize(DesignTokens.fontCaption)
              .fontColor(DesignTokens.success)
          } else {
            Text('待录入').fontSize(DesignTokens.fontCaption)
              .fontColor(DesignTokens.textTertiary)
          }
        }
        .width('100%')

        Row() {
          this.stat({ value: this.statOf(this.types + ''), label: '班次' })
          this.stat({ value: this.statOf(this.courses + ''), label: '课程' })
        }
        .width('100%')

        if (this.statusFailed) {
          Text('统计读取失败，班表已保留，请重新进入。')
            .fontSize(DesignTokens.fontCaption)
            .fontColor(DesignTokens.textTertiary)
            .width('100%')
        }
      }
      .width('100%')
      .alignItems(HorizontalAlign.Start)
    }
  }

  @Builder
  stat(cell: StatCell) {
    Column({ space: 2 }) {
      Text(cell.value)
        .fontSize(DesignTokens.fontBody)
        .fontFamily(DesignTokens.fontRound)
        .fontWeight(FontWeight.Medium)
        .fontColor(DesignTokens.textAccent)
      Text(cell.label)
        .fontSize(DesignTokens.fontCaption)
        .fontColor(DesignTokens.textTertiary)
    }
    .layoutWeight(1)
    .alignItems(HorizontalAlign.Start)
    // 数字和标签合成一句，否则四个格子会念成"3、班次、true、循环模板…"
    .accessibilityGroup(true)
    .accessibilityText(cell.label + ' ' + (cell.value === STAT_UNKNOWN ? '读取失败' : cell.value))
  }

  private isConfigured(): boolean {
    return this.types > 0 && this.tplSet;
  }

  /** 读失败时统计项一律退化成占位：catch 里保留的是上一次的旧值，把旧值当现状念出来同样是说谎。 */
  private statOf(value: string): string {
    return this.statusFailed ? STAT_UNKNOWN : value;
  }

  /** 页首标题栏：与四个主入口页同一款——左「返回」＋居中粗标题，标题下面不再挂说明行。 */
  @Builder
  headBar() {
    Row() {
      Row({ space: 2 }) {
        SymbolGlyph($r('sys.symbol.chevron_left'))
          .fontSize(16).fontColor([DesignTokens.primary])
          // 箭头和"返回"是一回事，念两遍不如合成一句
          .accessibilityLevel('no')
        Text('返回')
          .fontSize(15).fontColor(DesignTokens.textAccent)
      }
      .padding({ left: 2, top: DesignTokens.space3, bottom: DesignTokens.space3 })
      .constraintSize({ minHeight: AccessibilityPolicy.minHit(this.senior) })
      .focusable(true)
      .accessibilityGroup(true)
      .accessibilityText('返回上一页')
      .onClick(() => this.requestBack())

      Blank()
      Text('日程管理')
        .fontSize(17)
        .fontWeight(FontWeight.Bold)
        .fontColor(DesignTokens.textPrimary)
      Blank()
    }
    .width('100%')
    .alignItems(VerticalAlign.Center)
    .padding({ left: 2, right: DesignTokens.space3, top: DesignTokens.space4 })
  }

  /** 视图切换。 */
  @Builder
  segmentControl() {
    CapsuleSegment({
      items: this.segItems,
      selectedIndex: this.hubView === VIEW_WEEK ? 0 : 1,
      onPick: (idx: number) => {
        this.hubView = idx === 0 ? VIEW_WEEK : VIEW_MANAGE;
      }
    })
  }

  @Builder
  fixedTools() {
    FadingHeaderSurface() {
      Column({ space: DesignTokens.space3 }) {
        this.headBar()
        if (this.partnerLocal) {
          Row({ space: DesignTokens.space1 }) {
            this.sidePill({ label: '我的班表', partner: false })
            this.sidePill({ label: 'TA 的班表', partner: true })
          }
          .width('100%').padding(4)
          .borderRadius(DesignTokens.radiusPill)
          .backgroundColor(DesignTokens.fillSoft)
        }
        if (!this.isPartnerSide() || this.partnerLocal) {
          this.segmentControl()
        }
      }
      .width('100%')
      .constraintSize({ maxWidth: Breakpoints.contentMaxWidth(this.bp) })
      .padding({ left: Breakpoints.hPadding(this.bp), right: Breakpoints.hPadding(this.bp),
        bottom: DesignTokens.space3 })
    }
  }

  build() {
    ResponsiveContainer({ breakpoint: this.bp }) {
      Column() {
        this.fixedTools()
        Column() {
          FadingScrollViewport({ fadeHeight: 24, visual: this.scrollVisual }) {
            Refresh({ refreshing: $$this.refreshing, offset: 64, friction: 10 }) {
              Scroll(this.hubScroller) {
                Column({ space: DesignTokens.space3 }) {
                  if (this.isPartnerSide() && !this.partnerLocal) {
                    // 深链指定了 TA 侧但本机没代录过（纯配对不算代录）：给引导，不显示空的 TA 表单
                    StatePanel({
                      kind: StatePanelKind.EMPTY,
                      title: '还没有代录 TA 的日程',
                      description: '先在「我的 · 伴侣与同步」添加伴侣，就能在这里替 TA 记班表。',
                      actionLabel: '去添加伴侣',
                      onAction: () => {
                        pushPendingRoute(NavRoutes.ME);
                      }
                    })
                  } else {
                    if (this.hubView === VIEW_WEEK) {
                      EditorialCard({ hero: false, cutTopLeft: false, tappable: false }) {
                        WeekScheduleView({ owner: this.side,
                          onPickDay: (epochDay: number) => this.openDay(epochDay) })
                      }
                    } else {
                      this.summaryCard()
                      this.mainEntriesCard()
                    }
                  }
                }
                .width('100%')
                .constraintSize({ maxWidth: Breakpoints.contentMaxWidth(this.bp) })
                .padding({ bottom: DesignTokens.space6 })
              }
              .width('100%')
              .height('100%')
              .align(Alignment.Top)
              .padding({ left: Breakpoints.hPadding(this.bp), right: Breakpoints.hPadding(this.bp) })
              .scrollBar(BarState.Off)
              .onAppear(() => {
                this.scrollVisual.update(readScrollY(this.hubScroller));
              })
              .onDidScroll(() => {
                this.scrollVisual.update(readScrollY(this.hubScroller));
              })
              .bindSheet($$this.dayVisible, this.daySheet(), {
                height: SheetSize.FIT_CONTENT,
                detents: [SheetSize.FIT_CONTENT],
                preferType: SheetType.BOTTOM,
                dragBar: false,
                showClose: false,
                radius: { topLeft: DesignTokens.radiusSheet, topRight: DesignTokens.radiusSheet },
                backgroundColor: DesignTokens.card,
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
        .width('100%')
        .layoutWeight(1)
      }
      .width('100%').height('100%')
      .linearGradient(DesignTokens.pageGradient())
    }
  }

  /** 下拉刷新：重算一遍视界（已配对时顺带拉对方最新快照），本页统计跟着重算广播重读。 */
  private async onRefresh(): Promise<void> {
    await syncOnPull();
    this.refreshing = false;
  }

  @Builder
  mainEntriesCard() {
    EditorialCard({ hero: false, cutTopLeft: true, tappable: false }) {
      EditorialSection({ eyebrow: 'SCHEDULE', title: '日程管理' }) {
        ForEach(MAIN_ENTRIES, (item: EntryItem) => {
          this.entryRow(item)
        }, (item: EntryItem) => this.side + '-' + item.key)
      }
    }
  }

}
