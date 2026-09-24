import { router } from '@kit.ArkUI';
import { OWNER_ME, OWNER_PARTNER, defaultParams, todayEpochDay } from 'domain';
import { FeatureFlags, ScheduleOverview, ScheduleOverviewQueryService } from 'feature';
import { DesignTokens } from '../theme/DesignTokens';
import { ownerFromParams, ownerParam } from '../model/RouteParams';
import { EditorialCard } from '../component/EditorialCard';
import { EditorialSection } from '../component/EditorialSection';
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
 * 日程页（班表中心）：从底部 Tab 降级为「我的 · 我的日程」里的栈目的地。
 * - 默认展示"我"的日程摘要与周视图；只有本机代录了伴侣（有档案或 TA 的班表数据）才出现"TA"侧；
 * - 四个主入口：班次类型 / 循环模板 / 课程表 / 临时调整（单日改班 sheet）；
 * - 批量录入的二级入口首发不上线：`PaintMonth` / `OcrCourse` 两个旧录入页保留在路由表与 `main_pages.json` 里，只是这里不再给入口；
 * - 点周历日格 = 改这天的班，与主入口「临时调整」是同一条链路（临时调整默认今天）。
 */
@Component
export struct ScheduleHub {
  /** 壳层 pushPathByName 带入的侧别：从「代录 TA 的班表」进入时直接落在 TA。 */
  initialOwner: string = OWNER_ME;
  @State private side: string = OWNER_ME;
  /** 本机是否代录过伴侣（有档案或 owner=PARTNER 数据）；纯云端配对不算代录。 */
  @State private partnerLocal: boolean = false;
  @State private types: number = 0;
  @State private tplSet: boolean = false;
  @State private ovs: number = 0;
  @State private courses: number = 0;
  /** 读模型给的视界天数：文案与统计区间都用它；首帧先用引擎默认，读模型回来即替换。 */
  @State private horizon: number = defaultParams().horizonDays;
  // 单日改班 sheet（临时调整 / 点日格）
  @State private sheetOpen: boolean = false;
  @State private sheetDay: number = 0;
  /** 本页容器宽度档位：expanded 把两组录入入口并排，正文按可读宽度收拢。 */
  @State private bp: Breakpoint = Breakpoint.COMPACT;
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
    } catch (e) {
      this.types = 0;
      this.tplSet = false;
      this.ovs = 0;
      this.courses = 0;
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
      .fontSize(DesignTokens.fontCaption)
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
          .fontSize(DesignTokens.fontBody)
          .fontWeight(FontWeight.Medium)
          .fontColor(DesignTokens.textPrimary)
        Text(this.descOf(item))
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
            .fontSize(DesignTokens.fontTitle)
            .fontFamily(DesignTokens.fontSerif)
            .fontWeight(FontWeight.Medium)
            .fontColor(DesignTokens.textPrimary)
            .letterSpacing(-0.7)
            .layoutWeight(1)
          if (this.isConfigured()) {
            Text('已录入').fontSize(DesignTokens.fontCaption)
              .fontColor(DesignTokens.success)
          } else {
            Text('待录入').fontSize(DesignTokens.fontCaption)
              .fontColor(DesignTokens.textTertiary)
          }
        }
        .width('100%')

        Row() {
          this.stat(this.types + '', '班次')
          this.stat(this.tplSet ? '已设' : '未设', '循环模板')
          this.stat(this.ovs + '', '临时调整')
          this.stat(this.courses + '', '课程')
        }
        .width('100%')
      }
      .width('100%')
      .alignItems(HorizontalAlign.Start)
    }
  }

  @Builder
  stat(value: string, label: string) {
    Column({ space: 2 }) {
      Text(value)
        .fontSize(DesignTokens.fontBody)
        .fontFamily(DesignTokens.fontSerif)
        .fontWeight(FontWeight.Medium)
        .fontColor(DesignTokens.primary)
      Text(label)
        .fontSize(DesignTokens.fontCaption)
        .fontColor(DesignTokens.textTertiary)
    }
    .layoutWeight(1)
    .alignItems(HorizontalAlign.Start)
    // 数字和标签合成一句，否则四个格子会念成"3、班次、true、循环模板…"
    .accessibilityGroup(true)
    .accessibilityText(label + ' ' + value)
  }

  private isConfigured(): boolean {
    return this.types > 0 && this.tplSet;
  }

  build() {
    ResponsiveContainer({ breakpoint: this.bp }) {
      // 周历网格本身超过一屏，整页必须可滚
      Scroll() {
        Column({ space: DesignTokens.space3 }) {
          Column({ space: 2 }) {
            Text('日程录入')
              .fontSize(DesignTokens.fontTitle)
              .fontFamily(DesignTokens.fontSerif)
              .fontWeight(FontWeight.Medium)
              .fontColor(DesignTokens.textPrimary)
              .letterSpacing(-0.9)
            Text('班次、循环、课程与临时调整都在这里；改完自动重算共同时间')
              .fontSize(DesignTokens.fontCaption)
              .fontColor(DesignTokens.textTertiary)
          }
          .width('100%')
          .alignItems(HorizontalAlign.Start)
          .padding({ top: DesignTokens.space5 })

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
            this.summaryCard()

            EditorialCard({ hero: false, cutTopLeft: false, tappable: false }) {
              Column({ space: DesignTokens.space2 }) {
                WeekScheduleView({
                  owner: this.side,
                  onPickDay: (epochDay: number) => {
                    this.openDay(epochDay);
                  }
                })
                Text('点周历里的某一天，可直接改这天的班')
                  .fontSize(DesignTokens.fontCaption)
                  .fontColor(DesignTokens.textHint)
                  .width('100%').textAlign(TextAlign.Center)
              }
              .width('100%')
            }

            this.mainEntriesCard()

            // 云端档位关闭时不把用户指向一个已经收起来的入口（阶段 6R.2）
            Text(FeatureFlags.cloudPairing
              ? 'TA 的班表由你在这台手机上代录；两台手机各自记录请用「我的 · 伴侣与同步」配对。'
              : 'TA 的班表由你在这台手机上代录。')
              .fontSize(DesignTokens.fontCaption)
              .fontColor(DesignTokens.textHint)
              .width('100%')
              .padding({ bottom: DesignTokens.space6 })
          }
        }
        .width('100%')
        .constraintSize({ maxWidth: Breakpoints.contentMaxWidth(this.bp) })
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
