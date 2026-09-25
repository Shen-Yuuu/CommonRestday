import { router, SegmentButtonV2Items } from '@kit.ArkUI';
import { OWNER_ME, OWNER_PARTNER, defaultParams, todayEpochDay } from 'domain';
import { ScheduleOverview, ScheduleOverviewQueryService } from 'feature';
import { Logger } from 'commons';
import { DesignTokens } from '../theme/DesignTokens';
import { ownerFromParams, ownerParam } from '../model/RouteParams';
import { EditorialCard } from '../component/EditorialCard';
import { EditorialSection } from '../component/EditorialSection';
import { CapsuleSegment } from '../component/CapsuleSegment';
import { DayShiftSheet } from '../component/DayShiftSheet';
import { StatePanel, StatePanelKind } from '../component/StatePanel';
import { WeekScheduleView } from '../component/WeekScheduleView';
import { pushPendingRoute } from '../util/NavUtil';
import { NavRoutes } from '../navigation/NavRoutes';
import { AccessibilityPolicy } from '../accessibility/AccessibilityPolicy';
import { Breakpoint, Breakpoints } from '../responsive/Breakpoints';
import { ResponsiveContainer } from '../responsive/ResponsiveContainer';

/** 录入链路页（仍是 @Entry router 页）：路由名即 pages 下的 url 后缀。 */
const PAGE_SHIFT = 'pages/ScheduleEditor';
const PAGE_CYCLE = 'pages/CycleEditor';
const PAGE_COURSE = 'pages/CourseImport';

const TAG = 'ScheduleHub';

/** 本页的两个视图：周历单独成视图，概况统计与四个主入口合成另一个。 */
const VIEW_WEEK = 'week';
const VIEW_MANAGE = 'manage';

/** 读失败时的占位：0 是"确实没有"，破折号才是"不知道"，两者不能混用（D-22）。 */
const STAT_UNKNOWN = '—';

/** 读模型摘要项。@Builder 传两个及以上参数时不参与动态渲染，所以四项合成一个对象字面量按引用传。 */
interface StatCell {
  value: string;
  label: string;
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
    key: 'shift', glyph: $r('sys.symbol.gearshape'), title: '班次类型',
    desc: '定义上下班时刻、通勤与夜班恢复', page: PAGE_SHIFT
  },
  {
    key: 'cycle', glyph: $r('sys.symbol.arrow_clockwise'), title: '循环模板',
    desc: '白白夜夜休休等序列 + 锚点，自动铺开未来视界内的每一天', page: PAGE_CYCLE
  },
  {
    key: 'course', glyph: $r('sys.symbol.square_and_pencil'), title: '课程表',
    desc: '学生场景：粘贴课表文本或手动添加每周固定课程', page: PAGE_COURSE
  },
  {
    key: 'today', glyph: $r('sys.symbol.paintbrush'), title: '临时调整',
    desc: '给某一天单独改班或请假，优先于循环模板', page: ''
  }
];

/**
 * 日程录入页：从底部 Tab 降级为「我的 · 我的日程」里的栈目的地。
 * - 默认展示"我"的日程摘要与周视图；只有本机代录了伴侣（有档案或 TA 的班表数据）才出现"TA"侧；
 * - 两个视图用与共同页同一款滑动选项卡切换：「周历」单独一屏，「日程管理」装摘要统计与四个主入口；
 * - 系统标题栏藏掉了，所以页首要自己给一颗看得见的返回键（手势与返回键没有视觉线索）；
 * - 四个主入口：班次类型 / 循环模板 / 课程表 / 临时调整（单日改班 sheet）；
 * - 批量录入的二级入口首发不上线：`PaintMonth` / `OcrCourse` 两个旧录入页保留在路由表与 `main_pages.json` 里，只是这里不再给入口；
 * - 点周历日格 = 改这天的班，与主入口「临时调整」是同一条链路（临时调整默认今天）。
 */
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
  // 单日改班 sheet（临时调整 / 点日格）
  @State private sheetOpen: boolean = false;
  @State private sheetDay: number = 0;
  /** 本页容器宽度档位：expanded 把两组录入入口并排，正文按可读宽度收拢。 */
  @State private bp: Breakpoint = Breakpoint.COMPACT;
  /** 当前视图：进来默认落在周历——来这一页多半是看哪天能改，管理入口放第二屏。 */
  @State private hubView: string = VIEW_WEEK;
  /** 与共同页「时间窗口 / 共同计划」同款滑动选项卡；标题不带人称，两侧切换后仍然读得通。 */
  segItems: SegmentButtonV2Items = new SegmentButtonV2Items([{ text: '周历' }, { text: '日程管理' }]);
  // 装饰器实参必须是字面量，取值与 SENIOR_MODE_KEY 保持一致。
  @StorageProp('crd_senior_mode') senior: boolean = false;
  // 保存动作 → 重算广播 → 伴侣侧数据可能刚被增删，摘要与 TA 可见性都要跟着刷
  @StorageProp('recomputeCount') @Watch('onRecomputeChanged') recomputeCount: number = 0;

  aboutToAppear(): void {
    this.side = this.initialOwner === OWNER_PARTNER ? OWNER_PARTNER : OWNER_ME;
    this.loadStatus();
  }

  onRecomputeChanged(): void {
    this.loadStatus();
  }

  /** 当前侧录入概况：班次/循环/临时调整/课程四项 + 真实视界 + 是否代录过 TA。 */
  async loadStatus(): Promise<void> {
    try {
      const ov: ScheduleOverview = await ScheduleOverviewQueryService.getOverview(this.side);
      this.types = ov.shiftTypes;
      this.tplSet = ov.hasTemplate;
      this.ovs = ov.overrides;
      this.courses = ov.courses;
      this.horizon = ov.horizonDays;
      this.partnerLocal = ov.partnerLocal;
      this.statusFailed = false;
    } catch (e) {
      // 保留上一次读到的值，只把这一态标出来：静默归零等于对着有数据的用户说"没数据"（D-22）
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

  private openDay(epochDay: number): void {
    this.sheetDay = epochDay;
    this.sheetOpen = true;
  }

  /** 主入口「临时调整」：没有既定点选目标日时默认今天。 */
  private openToday(): void {
    this.openDay(todayEpochDay());
  }

  private pickSide(partner: boolean): void {
    this.side = partner ? OWNER_PARTNER : OWNER_ME;
    this.loadStatus();
  }

  @Builder
  sidePill(label: string, partner: boolean) {
    Text(label)
      .fontSize(DesignTokens.fontCaption(this.senior))
      .fontWeight(this.isPartnerSide() === partner ? FontWeight.Medium : FontWeight.Normal)
      .fontColor(this.isPartnerSide() === partner ? DesignTokens.heroText : DesignTokens.textSecondary)
      .textAlign(TextAlign.Center)
      .layoutWeight(1)
      .padding({ top: DesignTokens.space2, bottom: DesignTokens.space2 })
      .constraintSize({ minHeight: AccessibilityPolicy.minHit(this.senior) })
      .borderRadius(DesignTokens.radiusPill)
      .backgroundColor(this.isPartnerSide() === partner ? DesignTokens.primary : Color.Transparent)
      .focusable(true)
      // 选中的那一侧只剩底色区别，读屏要念出"当前"
      .accessibilityText(this.isPartnerSide() === partner ? '当前查看' + label : '切换到' + label)
      .onClick(() => this.pickSide(partner))
  }

  /** 循环入口的视界天数用户可改：文案跟着读模型给的实际值走，不写死默认常量。 */
  private descOf(item: EntryItem): string {
    return item.key === 'cycle'
      ? '白白夜夜休休等序列 + 锚点，自动铺开未来 ' + this.horizon + ' 天' : item.desc;
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
          .fontSize(DesignTokens.fontBody(this.senior))
          .fontWeight(FontWeight.Medium)
          .fontColor(DesignTokens.textPrimary)
        Text(this.descOf(item))
          .fontSize(DesignTokens.fontCaption(this.senior))
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
    .accessibilityText(item.title + '。' + this.descOf(item))
    .onClick(() => {
      if (item.page === '') {
        this.openToday();
        return;
      }
      this.go(item.page);
    })
  }

  @Builder
  summaryCard() {
    EditorialCard({ hero: false, cutTopLeft: true, tappable: false }) {
      Column({ space: DesignTokens.space3 }) {
        Row() {
          Text(this.sideTitle())
            .fontSize(DesignTokens.fontTitle(this.senior))
            .fontFamily(DesignTokens.fontSerif)
            .fontWeight(FontWeight.Medium)
            .fontColor(DesignTokens.textPrimary)
            .letterSpacing(-0.7)
            .layoutWeight(1)
          if (this.statusFailed) {
            Text('读取失败').fontSize(DesignTokens.fontCaption(this.senior))
              .fontColor(DesignTokens.warn)
          } else if (this.isConfigured()) {
            Text('已录入').fontSize(DesignTokens.fontCaption(this.senior))
              .fontColor(DesignTokens.success)
          } else {
            Text('待录入').fontSize(DesignTokens.fontCaption(this.senior))
              .fontColor(DesignTokens.textTertiary)
          }
        }
        .width('100%')

        Row() {
          this.stat({ value: this.statOf(this.types + ''), label: '班次' })
          this.stat({ value: this.statOf(this.tplSet ? '已设' : '未设'), label: '循环模板' })
          this.stat({ value: this.statOf(this.ovs + ''), label: '临时调整' })
          this.stat({ value: this.statOf(this.courses + ''), label: '课程' })
        }
        .width('100%')

        if (this.statusFailed) {
          Text('统计暂时读不到，已录入的班表没有受影响；退出这一页重进即可重试。')
            .fontSize(DesignTokens.fontCaption(this.senior))
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
        .fontSize(DesignTokens.fontBody(this.senior))
        .fontFamily(DesignTokens.fontSerif)
        .fontWeight(FontWeight.Medium)
        .fontColor(DesignTokens.primary)
      Text(cell.label)
        .fontSize(DesignTokens.fontCaption(this.senior))
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

  /** 读失败时四项一律退化成占位：catch 里保留的是上一次的旧值，把旧值当现状念出来同样是说谎。 */
  private statOf(value: string): string {
    return this.statusFailed ? STAT_UNKNOWN : value;
  }

  /**
   * 页首标题栏：与四个主入口页同一款——左「返回」＋居中粗标题，标题下面不再挂说明行。
   * 系统标题栏是本页自己藏掉的（标题与滚动都在正文里），藏掉它就一起失去了唯一的可见出口，
   * 所以这颗可见返回键必须留着（从「我的 · 我的日程」跳进来的人要看得见怎么回去）。
   */
  @Builder
  headBar() {
    Row() {
      Row({ space: 2 }) {
        SymbolGlyph($r('sys.symbol.chevron_left'))
          .fontSize(16).fontColor([DesignTokens.primary])
          // 箭头和"返回"是一回事，念两遍不如合成一句
          .accessibilityLevel('no')
        Text('返回')
          .fontSize(DesignTokens.fontBody(this.senior)).fontColor(DesignTokens.primary)
      }
      .padding({ left: 2, top: DesignTokens.space3, bottom: DesignTokens.space3 })
      .constraintSize({ minHeight: AccessibilityPolicy.minHit(this.senior) })
      .focusable(true)
      .accessibilityGroup(true)
      .accessibilityText('返回上一页')
      .onClick(() => this.onBack())

      Blank()
      Text('日程录入')
        .fontSize(DesignTokens.fontHead(this.senior))
        .fontWeight(FontWeight.Bold)
        .fontColor(DesignTokens.textPrimary)
      Blank()
    }
    .width('100%')
    .alignItems(VerticalAlign.Center)
    .padding({ left: 2, right: DesignTokens.space3, top: DesignTokens.space4 })
  }

  /** 视图切换：与共同页同一款胶囊分段（列表/周历那对 viewPill 是页内二级切换，不混用）。 */
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

  build() {
    ResponsiveContainer({ breakpoint: this.bp }) {
      // 周历网格本身超过一屏，整页必须可滚
      Scroll() {
        Column({ space: DesignTokens.space3 }) {
          this.headBar()

          // 我 / TA 分段：只有本机代录过伴侣才出现第二侧
          if (this.partnerLocal) {
            Row({ space: DesignTokens.space1 }) {
              this.sidePill('我的班表', false)
              this.sidePill('TA 的班表', true)
            }
            .width('100%')
            .padding(4)
            .borderRadius(DesignTokens.radiusPill)
            .backgroundColor(DesignTokens.fillSoft)
          }

          if (this.isPartnerSide() && !this.partnerLocal) {
            // 深链指定了 TA 侧但本机没代录过（纯配对不算代录）：给引导，不显示空的 TA 表单
            StatePanel({
              kind: StatePanelKind.EMPTY,
              title: '还没有代录 TA 的日程',
              description: '在「我的 · 伴侣与同步」添加伴侣后，就能在这台手机上为 TA 录班表，一起算共同时间。',
              actionLabel: '去添加伴侣',
              onAction: () => {
                pushPendingRoute(NavRoutes.ME);
              }
            })
          } else {
            this.segmentControl()

            if (this.hubView === VIEW_WEEK) {
              EditorialCard({ hero: false, cutTopLeft: false, tappable: false }) {
                Column({ space: DesignTokens.space2 }) {
                  WeekScheduleView({
                    owner: this.side,
                    onPickDay: (epochDay: number) => {
                      this.openDay(epochDay);
                    }
                  })
                  Text('点周历里的某一天，可直接改这天的班')
                    .fontSize(DesignTokens.fontCaption(this.senior))
                    .fontColor(DesignTokens.textHint)
                    .width('100%').textAlign(TextAlign.Center)
                }
                .width('100%')
              }
            } else {
              this.summaryCard()
              this.mainEntriesCard()
            }
          }
        }
        .width('100%')
        .constraintSize({ maxWidth: Breakpoints.contentMaxWidth(this.bp) })
        // 页脚那条代录说明删掉后，末张卡下面原本由它承担的空隙要自己留着
        .padding({ bottom: DesignTokens.space6 })
      }
      .width('100%')
      .height('100%')
      .align(Alignment.Top)
      .padding({ left: Breakpoints.hPadding(this.bp), right: Breakpoints.hPadding(this.bp) })
      .scrollBar(BarState.Off)
      .backgroundColor(DesignTokens.page)
      .bindSheet($$this.sheetOpen, this.daySheet(), {
        detents: [SheetSize.MEDIUM, SheetSize.LARGE],
        dragBar: false,
        showClose: false,
        blurStyle: BlurStyle.Thick
      })
    }
  }

  @Builder
  mainEntriesCard() {
    EditorialCard({ hero: false, cutTopLeft: true, tappable: false }) {
      EditorialSection({ eyebrow: 'MAIN', title: '四个主入口' }) {
        ForEach(MAIN_ENTRIES, (item: EntryItem) => {
          this.entryRow(item)
        }, (item: EntryItem) => this.side + '-' + item.key)
      }
    }
  }

  @Builder
  daySheet() {
    if (this.sheetDay > 0) {
      DayShiftSheet({
        owner: this.side,
        epochDay: this.sheetDay,
        onClose: () => {
          this.sheetOpen = false;
        }
      })
    }
  }
}
