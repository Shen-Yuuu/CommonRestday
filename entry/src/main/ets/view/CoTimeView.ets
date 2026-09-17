import { Interval, MIN_PER_DAY, WindowTag, todayEpochDay } from 'domain';
import { ScheduleRepo } from 'data';
import { DateLabel, Logger } from 'commons';
import { ScheduleUseCase } from 'feature';
import {
  CapsuleSegmentButtonV2, ChipV2, ChipV2Label, ChipV2Options, ChipV2Size,
  ColorMetrics, LengthMetrics, SegmentButtonV2Items
} from '@kit.ArkUI';
import { navToMe } from '../util/NavUtil';
import { WindowDetailSheet } from '../component/WindowDetailSheet';
import { DayDetailSheet } from '../component/DayDetailSheet';
import { tagColor, tagLabel } from '../util/WindowTagUtil';
import { PlansView } from './PlansView';

/** 窗口列表项（computed_window 缓存 → 展示视图）。 */
interface WindowItem {
  start: number;
  end: number;
  durationMin: number;
  tags: string[];
}

/** 筛选项（key 对应 WindowTag 或专用过滤键）。 */
interface FilterOption {
  key: string;
  label: string;
}

/** 月历单元格：当天共同空闲分钟数（多窗口按日裁剪求和）。 */
interface MonthCell {
  day: number;
  epochDay: number;
  freeMin: number;
}

/** 月历一行（7 格，空位为 null 补齐）。 */
interface WeekRow {
  cells: (MonthCell | null)[];
  key: string;
}

const FILTER_ALL = 'ALL';
const FILTER_GTE2H = 'GTE2H';
const VIEW_LIST = 'list';
const VIEW_MONTH = 'month';
const SEG_WINDOW = 'window';
const SEG_PLANS = 'plans';
const WEEKDAY_HEADERS: string[] = ['一', '二', '三', '四', '五', '六', '日'];

/** 筛选 chips：全部 / 有点空(≥2h) / 半天 / 完整同休日 / 共同周末 / 共同自习 / 过夜旅行 / 短途旅行。 */
const FILTERS: FilterOption[] = [
  { key: FILTER_ALL, label: '全部' },
  { key: FILTER_GTE2H, label: '有点空 ≥2h' },
  { key: WindowTag.HALF_DAY, label: '半天' },
  { key: WindowTag.FULL_DAY, label: '完整同休日' },
  { key: WindowTag.WEEKEND, label: '共同周末' },
  { key: WindowTag.STUDY, label: '共同自习' },
  { key: WindowTag.OVERNIGHT_TRIP, label: '过夜旅行' },
  { key: WindowTag.TRIP, label: '短途旅行' }
];

/**
 * 共同时间页（US1 核心）：
 * - 列表视图：computed_window 缓存 + 标签筛选 chips + 窗口卡片（点击创建计划）；
 * - 月历视图（C2）：按天聚合共同空闲分钟数分级着色，点日期弹日详情；
 * - 无伴侣：显示"我的空闲"语义 + 添加伴侣引导；
 * - 监听重算计数（RECOMPUTE_COUNT_KEY）变化刷新。
 */
@Component
export struct CoTimeView {
  @State windows: WindowItem[] = [];
  @State filterKey: string = FILTER_ALL;
  @State hasPartner: boolean = false;
  @State loading: boolean = true;
  // 顶层分段：窗口 / 计划（计划由 PlansView 嵌入承载）
  @State pageSegment: string = SEG_WINDOW;
  // 分段按钮数据源（SegmentButtonV2，静态两项无需响应式）
  segItems: SegmentButtonV2Items = new SegmentButtonV2Items([{ text: '窗口' }, { text: '计划' }]);
  // 下拉刷新（Refresh 组件，列表/月历视图均可触发重算）
  @State refreshing: boolean = false;
  // 视图切换：列表 / 月历
  @State viewMode: string = VIEW_LIST;
  // 月历当前显示年月
  @State calY: number = 0;
  @State calM: number = 0;
  // 窗口详情半模态（T029/T030：窗口点击 → 创建共同计划）
  @State sheetVisible: boolean = false;
  @State sheetWin: WindowItem | null = null;
  // 日详情半模态（C2：月历点日期 → 当日窗口 + 双方忙碌时间轴）
  @State dayVisible: boolean = false;
  @State dayEpoch: number = -1;
  @StorageProp('recomputeCount') @Watch('onRecomputeChanged') recomputeCount: number = 0;

  aboutToAppear(): void {
    const ymd = DateLabel.ymd(todayEpochDay());
    this.calY = ymd.y;
    this.calM = ymd.m;
    this.refresh();
  }

  /** 全量刷新：重算（毫秒级）后读缓存渲染。 */
  refresh(): void {
    this.loading = true;
    ScheduleUseCase.ensureSeeded().then(() => {
      return ScheduleUseCase.recompute(todayEpochDay());
    }).then(() => {
      return this.loadFromCache();
    }).catch((e: Error) => {
      Logger.error('CoTimeView', 'refresh failed: ' + e.message);
      this.loading = false;
      this.refreshing = false;
    });
  }

  /** 重算广播（保存动作/伴侣档案变更）→ 只重读缓存。 */
  onRecomputeChanged(): void {
    this.loadFromCache();
  }

  async loadFromCache(): Promise<void> {
    try {
      const ivs: Interval[] = await ScheduleRepo.listWindows();
      const now = todayEpochDay() * MIN_PER_DAY + this.minutesNow();
      const out: WindowItem[] = [];
      for (let i = 0; i < ivs.length; i++) {
        if (ivs[i].end <= now) {
          continue; // 已过期
        }
        const tags: string[] = ivs[i].tag === '' ? [] : ivs[i].tag.split('|');
        const item: WindowItem = {
          start: ivs[i].start,
          end: ivs[i].end,
          durationMin: ivs[i].end - ivs[i].start,
          tags: tags
        };
        out.push(item);
      }
      this.windows = out;
      this.hasPartner = await ScheduleUseCase.hasPartnerContext();
    } catch (e) {
      // 缓存读取失败保持既有展示
    }
    this.loading = false;
    this.refreshing = false;
  }

  /** 当前筛选下的窗口列表。 */
  filtered(): WindowItem[] {
    const out: WindowItem[] = [];
    for (let i = 0; i < this.windows.length; i++) {
      const w = this.windows[i];
      if (this.filterKey === FILTER_ALL) {
        out.push(w);
      } else if (this.filterKey === FILTER_GTE2H) {
        // 引擎 minSlotMin 默认 2h，此处按 ≥2h 语义过滤
        if (w.durationMin >= 120) {
          out.push(w);
        }
      } else if (w.tags.indexOf(this.filterKey) >= 0) {
        out.push(w);
      }
    }
    return out;
  }

  minutesNow(): number {
    const d = new Date();
    return d.getHours() * 60 + d.getMinutes();
  }

  // ---------- 月历聚合 ----------

  /** 指定年月日的 epochDay（与 DateLabel 同为 UTC 日历日语义）。 */
  epochDayOfYmd(y: number, m: number, d: number): number {
    return Math.floor(Date.UTC(y, m - 1, d) / 86400000);
  }

  /** 指定年月天数。 */
  daysInMonth(y: number, m: number): number {
    return new Date(Date.UTC(y, m, 0)).getUTCDate();
  }

  /** 指定年月 1 日的周内下标（0=周一，与 WEEKDAY_HEADERS 对齐）。 */
  firstWeekdayIndex(y: number, m: number): number {
    const ed = this.epochDayOfYmd(y, m, 1);
    return ((ed % 7) + 7 + 3) % 7;
  }

  /** 月历单元格：每天共同空闲分钟（窗口与当日交集求和）。 */
  monthCells(): MonthCell[] {
    const first = this.epochDayOfYmd(this.calY, this.calM, 1);
    const dim = this.daysInMonth(this.calY, this.calM);
    const cells: MonthCell[] = [];
    for (let d = 1; d <= dim; d++) {
      const ed = first + d - 1;
      const s = ed * MIN_PER_DAY;
      const e = s + MIN_PER_DAY;
      let free = 0;
      for (let i = 0; i < this.windows.length; i++) {
        const os = Math.max(this.windows[i].start, s);
        const oe = Math.min(this.windows[i].end, e);
        if (oe > os) {
          free += oe - os;
        }
      }
      const c: MonthCell = { day: d, epochDay: ed, freeMin: free };
      cells.push(c);
    }
    return cells;
  }

  /** 月历按周分行（首行前置空位、末行补空位）。 */
  monthRows(): WeekRow[] {
    const cells = this.monthCells();
    const lead = this.firstWeekdayIndex(this.calY, this.calM);
    const rows: WeekRow[] = [];
    let cur: (MonthCell | null)[] = [];
    for (let i = 0; i < lead; i++) {
      cur.push(null);
    }
    for (let i = 0; i < cells.length; i++) {
      cur.push(cells[i]);
      if (cur.length === 7) {
        const row: WeekRow = { cells: cur, key: 'r' + rows.length };
        rows.push(row);
        cur = [];
      }
    }
    if (cur.length > 0) {
      while (cur.length < 7) {
        cur.push(null);
      }
      const row: WeekRow = { cells: cur, key: 'r' + rows.length };
      rows.push(row);
    }
    return rows;
  }

  /** 分级底色：无 / 有点空(<4h) / ≥4h / ≥12h（资源引用，深浅色自适应）。 */
  cellBg(freeMin: number): ResourceColor {
    if (freeMin <= 0) {
      return $r('app.color.month_free_none_bg');
    }
    if (freeMin < 240) {
      return $r('app.color.month_free_low_bg');
    }
    if (freeMin < 720) {
      return $r('app.color.month_free_mid_bg');
    }
    return $r('app.color.brand_pink');
  }

  /** 分级前景色（深底白字）。 */
  cellFg(freeMin: number): ResourceColor {
    if (freeMin >= 240) {
      return '#FFFFFF';
    }
    if (freeMin > 0) {
      return $r('app.color.month_free_low_fg');
    }
    return $r('app.color.month_free_none_fg');
  }

  /** 单元格空闲短标签（"<4h" / "5h"）。 */
  freeShort(freeMin: number): string {
    const h = Math.round(freeMin / 60);
    if (h < 1) {
      return freeMin + 'm';
    }
    return h + 'h';
  }

  prevMonth(): void {
    let m = this.calM - 1;
    let y = this.calY;
    if (m < 1) {
      m = 12;
      y -= 1;
    }
    this.calY = y;
    this.calM = m;
  }

  nextMonth(): void {
    let m = this.calM + 1;
    let y = this.calY;
    if (m > 12) {
      m = 1;
      y += 1;
    }
    this.calY = y;
    this.calM = m;
  }

  /** 回到本月。 */
  goCurrentMonth(): void {
    const ymd = DateLabel.ymd(todayEpochDay());
    this.calY = ymd.y;
    this.calM = ymd.m;
  }

  // ---------- 半模态 ----------

  /** 日期区间标签：同日 "9月14日 周一"；跨日 "9月14日–9月15日"。 */
  dateRangeLabel(w: WindowItem): string {
    const sd = Math.floor(w.start / MIN_PER_DAY);
    const ed = Math.floor((w.end - 1) / MIN_PER_DAY);
    if (sd === ed) {
      return DateLabel.mdw(sd);
    }
    return DateLabel.md(sd) + '–' + DateLabel.md(ed) + ' ' + DateLabel.weekday(sd);
  }

  /** 窗口条目点击 → 弹出窗口详情半模态（创建共同计划入口）。 */
  onWindowTap(w: WindowItem): void {
    this.sheetWin = w;
    this.sheetVisible = true;
  }

  /** sheet 关闭（取消或创建成功）：收回并兜底刷新（创建成功路径另有重算广播）。 */
  onSheetClose(): void {
    this.sheetVisible = false;
    this.loadFromCache();
  }

  /** 月历点日期 → 日详情半模态。 */
  openDay(epochDay: number): void {
    this.dayEpoch = epochDay;
    this.dayVisible = true;
  }

  /** 日详情里点某个共同窗口 → 收回日详情，转开创建计划 sheet。 */
  pickWindow(start: number, end: number, tags: string): void {
    this.dayVisible = false;
    const tagsArr: string[] = tags === '' ? [] : tags.split('|');
    const w: WindowItem = { start: start, end: end, durationMin: end - start, tags: tagsArr };
    this.sheetWin = w;
    // 先收日详情 sheet，稍后再弹创建计划 sheet，避免同帧开关冲突
    setTimeout(() => {
      this.sheetVisible = true;
    }, 180);
  }

  build() {
    Column() {
      // 页头：标题 + 副标题
      Text('共同时间').fontSize(22).fontWeight(FontWeight.Bold)
        .margin({ top: 16 }).width('100%')
      Text(this.hasPartner ? $r('app.string.cotime_subtitle_partner') : $r('app.string.cotime_subtitle_single'))
        .fontSize(12)
        .fontColor(this.hasPartner ? $r('app.color.brand_pink') : $r('app.color.text_tertiary')).width('100%')

      // 分段控件：窗口 | 计划（CapsuleSegmentButtonV2 系统胶囊分段，API 18）
      CapsuleSegmentButtonV2({
        items: this.segItems,
        selectedIndex: this.pageSegment === SEG_WINDOW ? 0 : 1,
        $selectedIndex: (idx: number) => {
          this.pageSegment = idx === 0 ? SEG_WINDOW : SEG_PLANS;
        },
        itemFontSize: LengthMetrics.fp(14),
        itemFontColor: ColorMetrics.resourceColor($r('app.color.text_secondary')),
        itemSelectedFontColor: ColorMetrics.resourceColor('#FFFFFF'),
        itemSelectedFontWeight: FontWeight.Medium,
        itemSelectedBackgroundColor: ColorMetrics.resourceColor($r('app.color.brand_pink')),
        itemBorderRadius: LengthMetrics.vp(10),
        buttonBackgroundColor: ColorMetrics.resourceColor($r('app.color.fill_soft')),
        buttonBorderRadius: LengthMetrics.vp(14),
        buttonPadding: LengthMetrics.vp(4)
      })
      .width('100%')
      .margin({ top: 4 })

      // 分段内容
      if (this.pageSegment === SEG_WINDOW) {
        this.windowBody()
      } else {
        Column() {
          PlansView({
            embedded: true,
            onGoWindow: () => {
              this.pageSegment = SEG_WINDOW;
            }
          })
        }
        .width('100%').layoutWeight(1)
      }
    }
    .width('100%').height('100%')
    .bindSheet($$this.dayVisible, this.daySheet(), {
      detents: [SheetSize.LARGE],
      dragBar: false,
      showClose: false,
      blurStyle: BlurStyle.Thick
    })
    .bindSheet($$this.sheetVisible, this.detailSheet(), {
      detents: [SheetSize.MEDIUM, SheetSize.LARGE],
      dragBar: false,
      showClose: false,
      blurStyle: BlurStyle.Thick
    })
  }

  /** 窗口分段主体：Refresh 包裹的 列表/月历 双视图。 */
  @Builder
  windowBody() {
    Refresh({ refreshing: $$this.refreshing, offset: 64, friction: 10 }) {
      Scroll() {
        Column({ space: 12 }) {
          // 视图切换（列表 / 月历，ChipV2）
          Row({ space: 8 }) {
            ChipV2({
              chipV2Options: new ChipV2Options({
                label: new ChipV2Label({
                  text: '列表',
                  fontSize: LengthMetrics.fp(12),
                  fontColor: ColorMetrics.resourceColor($r('app.color.text_secondary')),
                  activatedFontColor: ColorMetrics.resourceColor('#FFFFFF')
                }),
                activated: this.viewMode === VIEW_LIST,
                backgroundColor: ColorMetrics.resourceColor($r('app.color.fill_weak')),
                activatedBackgroundColor: ColorMetrics.resourceColor($r('app.color.brand_pink')),
                allowClose: false,
                size: ChipV2Size.SMALL,
                onClicked: () => {
                  this.viewMode = VIEW_LIST;
                }
              })
            })
            ChipV2({
              chipV2Options: new ChipV2Options({
                label: new ChipV2Label({
                  text: '月历',
                  fontSize: LengthMetrics.fp(12),
                  fontColor: ColorMetrics.resourceColor($r('app.color.text_secondary')),
                  activatedFontColor: ColorMetrics.resourceColor('#FFFFFF')
                }),
                activated: this.viewMode === VIEW_MONTH,
                backgroundColor: ColorMetrics.resourceColor($r('app.color.fill_weak')),
                activatedBackgroundColor: ColorMetrics.resourceColor($r('app.color.brand_pink')),
                allowClose: false,
                size: ChipV2Size.SMALL,
                onClicked: () => {
                  this.viewMode = VIEW_MONTH;
                }
              })
            })
          }.width('100%')

          if (this.viewMode === VIEW_LIST) {
            this.listView()
          } else {
            this.monthView()
          }
        }
        .padding(16)
        .width('100%')
      }
      .width('100%').height('100%')
      .align(Alignment.Top)
    }
    .onRefreshing(() => this.refresh())
    .layoutWeight(1)
    .width('100%')
  }

  /** 列表视图：筛选 chips + 窗口卡片。 */
  @Builder
  listView() {
    Column({ space: 12 }) {
      // 筛选 chips（横向滚动）
      Scroll() {
        Row({ space: 8 }) {
          ForEach(FILTERS, (f: FilterOption) => {
            ChipV2({
              chipV2Options: new ChipV2Options({
                label: new ChipV2Label({
                  text: f.label,
                  fontSize: LengthMetrics.fp(12),
                  fontColor: ColorMetrics.resourceColor($r('app.color.text_secondary')),
                  activatedFontColor: ColorMetrics.resourceColor('#FFFFFF')
                }),
                activated: this.filterKey === f.key,
                backgroundColor: ColorMetrics.resourceColor($r('app.color.fill_weak')),
                activatedBackgroundColor: ColorMetrics.resourceColor($r('app.color.brand_pink')),
                allowClose: false,
                size: ChipV2Size.SMALL,
                onClicked: () => {
                  this.filterKey = f.key;
                }
              })
            })
          }, (f: FilterOption) => f.key)
        }
        .padding({ left: 2, right: 2 })
      }
      .width('100%')
      .scrollable(ScrollDirection.Horizontal)
      .scrollBar(BarState.Off)

      if (this.loading) {
        Text($r('app.string.computing')).fontSize(14)
          .fontColor($r('app.color.text_tertiary')).margin({ top: 40 })
      } else {
        if (!this.hasPartner) {
          // 无伴侣引导（US1 场景 4：仍展示"我的空闲"，不崩溃）
          Column({ space: 10 }) {
            Text($r('app.string.cotime_empty_partner_title')).fontSize(15).fontWeight(FontWeight.Medium)
            Text($r('app.string.cotime_empty_partner_desc'))
              .fontSize(12).fontColor($r('app.color.text_tertiary')).textAlign(TextAlign.Center)
            Button('去添加伴侣').backgroundColor($r('app.color.brand_pink'))
              .onClick(() => navToMe())
          }
          .alignItems(HorizontalAlign.Center)
          .width('100%').padding(20).borderRadius(20)
          .backgroundColor($r('app.color.brand_pink_bg'))
        }

        if (this.filtered().length === 0) {
          Text(this.hasPartner ? $r('app.string.cotime_empty_with_partner') : $r('app.string.cotime_empty_single'))
            .fontSize(13).fontColor($r('app.color.text_tertiary')).margin({ top: 24 })
        } else {
          ForEach(this.filtered(), (w: WindowItem) => {
            this.windowCard(w)
          }, (w: WindowItem) => '' + w.start + '-' + w.end)
        }
      }
    }
    .width('100%')
  }

  /** 月历视图：月份导航 + 分级着色日历 + 图例。 */
  @Builder
  monthView() {
    Column({ space: 12 }) {
      // 月份导航
      Row({ space: 12 }) {
        SymbolGlyph($r('sys.symbol.chevron_left'))
          .fontSize(20).fontColor([$r('app.color.text_secondary')])
          .padding({ left: 8, right: 8 })
          .onClick(() => this.prevMonth())
        Text(this.calY + '年' + this.calM + '月')
          .fontSize(15).fontWeight(FontWeight.Medium)
          .layoutWeight(1).textAlign(TextAlign.Center)
        SymbolGlyph($r('sys.symbol.chevron_right'))
          .fontSize(20).fontColor([$r('app.color.text_secondary')])
          .padding({ left: 8, right: 8 })
          .onClick(() => this.nextMonth())
        Text('本月').fontSize(12).fontColor($r('app.color.brand_pink'))
          .padding({ left: 8, right: 8, top: 4, bottom: 4 })
          .borderRadius(10)
          .backgroundColor($r('app.color.brand_pink_bg'))
          .onClick(() => this.goCurrentMonth())
      }.width('100%')

      if (this.loading) {
        Text($r('app.string.computing')).fontSize(14)
          .fontColor($r('app.color.text_tertiary')).margin({ top: 40 })
      } else {
        Column({ space: 10 }) {
          // 周表头
          Row() {
            ForEach(WEEKDAY_HEADERS, (h: string) => {
              Text(h)
                .fontSize(11).fontColor($r('app.color.text_tertiary'))
                .width('14.28%').textAlign(TextAlign.Center)
            }, (h: string) => h)
          }.width('100%')

          // 日历格（按周分行）
          ForEach(this.monthRows(), (row: WeekRow) => {
            Row() {
              ForEach(row.cells, (c: MonthCell | null, idx: number) => {
                if (c == null) {
                  Column().width('14.28%').height(46)
                } else {
                  Column({ space: 1 }) {
                    Text('' + c.day)
                      .fontSize(13).fontColor(this.cellFg(c.freeMin))
                    Text(this.freeShort(c.freeMin))
                      .fontSize(9).fontColor(this.cellFg(c.freeMin))
                  }
                  .width('14.28%').height(46)
                  .justifyContent(FlexAlign.Center)
                  .backgroundColor(this.cellBg(c.freeMin))
                  .borderRadius(8)
                  .onClick(() => this.openDay(c.epochDay))
                }
              }, (c: MonthCell | null, idx: number) => c == null ? 'blank' + row.key + idx : 'd' + c.epochDay)
            }.width('100%')
          }, (row: WeekRow) => row.key + '-' + this.calY + '-' + this.calM)

          // 图例
          Row({ space: 12 }) {
            this.legendDot($r('app.color.month_free_none_bg'), '无')
            this.legendDot($r('app.color.month_free_low_bg'), '<4小时')
            this.legendDot($r('app.color.month_free_mid_bg'), '≥4小时')
            this.legendDot($r('app.color.brand_pink'), '≥12小时')
          }
          .width('100%').justifyContent(FlexAlign.Center)

          Text('色块 = 当天共同空闲时长，点日期查看当天详情')
            .fontSize(11).fontColor($r('app.color.text_hint')).width('100%').textAlign(TextAlign.Center)
        }
        .width('100%').padding(12).borderRadius(20)
        .backgroundColor($r('app.color.card_bg'))
        .shadow({ radius: 16, color: $r('app.color.shadow_soft'), offsetX: 0, offsetY: 4 })
      }
    }
    .width('100%')
  }

  /** 图例圆点 + 文案。 */
  @Builder
  legendDot(color: ResourceColor, label: string) {
    Row({ space: 4 }) {
      Column().width(10).height(10).borderRadius(5).backgroundColor(color)
      Text(label).fontSize(10).fontColor($r('app.color.text_tertiary'))
    }
  }

  /** 窗口详情半模态内容（WindowDetailSheet：时间轴 + 类型 + 起止调节 + 创建计划）。 */
  @Builder
  detailSheet() {
    if (this.sheetWin != null) {
      WindowDetailSheet({
        winStart: this.sheetWin.start,
        winEnd: this.sheetWin.end,
        winTags: this.sheetWin.tags.join('|'),
        onClose: () => this.onSheetClose()
      })
    }
  }

  /** 日详情半模态内容（DayDetailSheet：当日窗口 + 双方忙碌时间轴）。 */
  @Builder
  daySheet() {
    if (this.dayEpoch >= 0) {
      DayDetailSheet({
        day: this.dayEpoch,
        onPickWindow: (start: number, end: number, tags: string) => this.pickWindow(start, end, tags),
        onClose: () => {
          this.dayVisible = false;
        }
      })
    }
  }

  /** 窗口卡左侧渐变竖条两端色：出行蓝 / 周末紫 / 默认品牌粉→珊瑚橙。 */
  barGradient(w: WindowItem): [ResourceColor, ResourceColor] {
    if (w.tags.indexOf(WindowTag.TRIP) >= 0 || w.tags.indexOf(WindowTag.OVERNIGHT_TRIP) >= 0) {
      return [$r('app.color.tag_trip'), $r('app.color.info_blue')];
    }
    if (w.tags.indexOf(WindowTag.WEEKEND) >= 0) {
      return [$r('app.color.accent_purple'), $r('app.color.brand_pink')];
    }
    return [$r('app.color.brand_pink'), $r('app.color.sunset_to')];
  }

  @Builder
  windowCard(w: WindowItem) {
    Row({ space: 12 }) {
      Column().width(4).height(52).borderRadius(2)
        .linearGradient({
          angle: 180,
          colors: [[this.barGradient(w)[0], 0], [this.barGradient(w)[1], 1]]
        })
      Column({ space: 6 }) {
        Row() {
          Text(this.dateRangeLabel(w)).fontSize(14).fontWeight(FontWeight.Medium)
            .fontColor($r('app.color.text_primary')).layoutWeight(1)
          Text(DateLabel.duration(w.durationMin))
            .fontSize(12).fontColor($r('app.color.brand_pink')).fontWeight(FontWeight.Medium)
            .padding({ left: 10, right: 10, top: 3, bottom: 3 })
            .borderRadius(10)
            .backgroundColor($r('app.color.brand_pink_bg'))
        }.width('100%')

        Text(DateLabel.hm(w.start) + ' – ' + DateLabel.hm(w.end))
          .fontSize(12).fontColor($r('app.color.text_tertiary'))

        if (w.tags.length > 0) {
          Row({ space: 6 }) {
            ForEach(w.tags, (t: string) => {
              ChipV2({
                chipV2Options: new ChipV2Options({
                  label: new ChipV2Label({
                    text: tagLabel(t),
                    fontSize: LengthMetrics.fp(11),
                    fontColor: ColorMetrics.resourceColor('#FFFFFF')
                  }),
                  backgroundColor: ColorMetrics.resourceColor(tagColor(t)),
                  allowClose: false,
                  size: ChipV2Size.SMALL
                })
              })
            }, (t: string) => t)
          }.width('100%')
        }
      }.alignItems(HorizontalAlign.Start).layoutWeight(1)
    }
    .width('100%')
    .padding(16)
    .borderRadius(20)
    .backgroundColor($r('app.color.card_bg'))
    .shadow({ radius: 16, color: $r('app.color.shadow_soft'), offsetX: 0, offsetY: 4 })
    .onClick(() => this.onWindowTap(w))
  }
}
