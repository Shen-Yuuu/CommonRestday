import {
  BlockTag, Interval, MIN_PER_DAY, ShiftInstance, ShiftType, WindowChannel, WindowTag,
  expandCycle, shiftToBlocks, termWeekOf, todayEpochDay, weekdayOf
} from 'domain';
import { PlanRow, ScheduleRepo } from 'data';
import { DateLabel } from 'commons';
import {
  CommonTimeQueryService, ScheduleUseCase, SettingsStoreParams, WindowFilter, WindowFilterKey,
  WindowSummary
} from 'feature';
import { DesignTokens } from '../theme/DesignTokens';
import { tagColor } from '../util/WindowTagUtil';

/** 周视图模式：某一方的日程，或双方的共同空闲。 */
export const WEEK_MODE_SCHEDULE = 'SCHEDULE';
export const WEEK_MODE_COMMON = 'COMMON';

/** 日程模式网格：全天 24h 纵向网格，每小时 HOUR_H。 */
const HOUR_H = 34;
const GRID_H = 24 * HOUR_H;
const LABEL_W = 26;
const DAY_HEADERS: string[] = ['一', '二', '三', '四', '五', '六', '日'];
/** 课程/计划/恢复块的固定配色（班次块使用班次自带颜色）。 */
const COURSE_COLOR = '#3AA6E8';
const PLAN_COLOR = '#4E9A63';
const PLAN_CONFLICT_COLOR = '#D9534F';
const RECOVERY_COLOR = '#A08CD8';

/** 共同空闲分级门槛（分钟）：≥6h / ≥3h / 其余。 */
const FREE_HIGH_MIN = 360;
const FREE_MID_MIN = 180;
/** 周历可用高度（vp）：按它反推每小时高度，窗口越少格子越高。 */
const GRID_BUDGET = 452;
const HOUR_H_MIN = 13;
const HOUR_H_MAX = 30;
/** 默认只画 06:00–24:00，有空闲落在外面才把坐标轴撑开。 */
const AXIS_DEFAULT_START = 6;
const AXIS_END = 24;

const HOURS: number[] = (() => {
  const out: number[] = [];
  for (let i = 0; i < 24; i++) {
    out.push(i);
  }
  return out;
})();

/** 周视图单个日程块（绝对 epochMin 区间；渲染时按日裁剪，跨天块拆到两列）。 */
interface WeekItem {
  start: number;
  end: number;
  name: string;
  color: string;
}

/** 共同空闲块：裁剪到当日后的区间 + 所属窗口的原始起止。 */
interface FreeBlock {
  start: number;
  end: number;
  /** 原始窗口起止：点击必须回传它，列表与周历选中的才是同一个窗口。 */
  winStart: number;
  winEnd: number;
}

/** 当前周周一。 */
function currentWeekStart(): number {
  const today = todayEpochDay();
  return today - (weekdayOf(today) - 1);
}

function pad2(n: number): string {
  return n < 10 ? '0' + n : '' + n;
}

/**
 * 周视图网格，两种模式共用一套周导航与列布局：
 * - 日程模式（班表页）：当前侧的班次（循环+单日覆盖）、课程（学期+节次模板）、共同计划；
 * - 共同空闲模式（共同时间页「周历」）：把月历的"哪天有空"细化成课程表式的"几点到几点有空"，
 *   只画常规通道（睡眠不计入空闲），旅行通道在表头标点，点色块直接去建计划。
 * 数据随重算广播自动刷新（涂抹/导入/参数变更后无需手动更新）。
 */
@Component
export struct WeekScheduleView {
  @Prop @Watch('reload') owner: string = 'ME';
  /** 模式由父页决定且运行期不变：日程模式读班表，共同模式读窗口读模型。 */
  mode: string = WEEK_MODE_SCHEDULE;
  /** 共同模式：点空白处看当日明细。 */
  onPickDay: (epochDay: number) => void = () => {
  };
  /** 共同模式：点色块去建计划，回传的是原始窗口起止。 */
  onPickWindow: (start: number, end: number) => void = () => {
  };
  /** 共同模式：父页下拉刷新时自增。父页读模型已换新，这里跟着重读，不自己再算一次。 */
  @Prop @Watch('reload') refreshTick: number = 0;
  @State weekStart: number = currentWeekStart();
  @State loading: boolean = true;
  @State weekItems: WeekItem[] = [];
  @State commonWindows: WindowSummary[] = [];
  @State axisStart: number = AXIS_DEFAULT_START;
  @State hourH: number = 24;
  @State horizonDays: number = 0;
  @StorageProp('recomputeCount') @Watch('reload') recomputeCount: number = 0;

  aboutToAppear(): void {
    this.loadWeek();
  }

  reload(): void {
    this.loadWeek();
  }

  prevWeek(): void {
    this.weekStart = this.weekStart - 7;
    this.loadWeek();
  }

  nextWeek(): void {
    this.weekStart = this.weekStart + 7;
    this.loadWeek();
  }

  goCurrentWeek(): void {
    this.weekStart = currentWeekStart();
    this.loadWeek();
  }

  weekDays(): number[] {
    const out: number[] = [];
    for (let i = 0; i < 7; i++) {
      out.push(this.weekStart + i);
    }
    return out;
  }

  private isCommon(): boolean {
    return this.mode === WEEK_MODE_COMMON;
  }

  private nowEpochMin(): number {
    const d = new Date();
    return todayEpochDay() * MIN_PER_DAY + d.getHours() * 60 + d.getMinutes();
  }

  loadWeek(): void {
    if (this.isCommon()) {
      this.loadCommonWeek();
      return;
    }
    this.loadScheduleWeek();
  }

  /** 装配当前周的日程块：班次 + 课程 + 共同计划（绝对区间，跨天渲染时裁剪）。 */
  async loadScheduleWeek(): Promise<void> {
    this.loading = true;
    try {
      const params = SettingsStoreParams();
      const types = await ScheduleRepo.listShiftTypes(this.owner);
      const tpl = await ScheduleRepo.getTemplate(this.owner);
      const ovs = await ScheduleRepo.listOverrides(this.weekStart, this.weekStart + 6, this.owner);
      const courses = await ScheduleRepo.listCourses(this.owner);
      const termStart = await ScheduleRepo.getTermStart();
      const sectionTimes = ScheduleUseCase.sectionTimesFromJson(await ScheduleRepo.getSectionTimes());
      const plans: PlanRow[] = await ScheduleRepo.listActivePlans();

      const typeMap = new Map<string, ShiftType>();
      for (let i = 0; i < types.length; i++) {
        typeMap.set(types[i].id, types[i]);
      }

      const items: WeekItem[] = [];

      // ① 班次：循环模板（+单日覆盖）；无模板时仅显示覆盖班次日
      const insts: ShiftInstance[] = [];
      if (tpl != null) {
        const ex = expandCycle(tpl, ovs, this.weekStart, 7);
        for (let i = 0; i < ex.length; i++) {
          insts.push(ex[i]);
        }
      } else {
        for (let i = 0; i < ovs.length; i++) {
          const ov = ovs[i];
          if (ov.shiftTypeId != null && ov.epochDay >= this.weekStart && ov.epochDay < this.weekStart + 7) {
            const inst: ShiftInstance = { epochDay: ov.epochDay, typeId: ov.shiftTypeId as string };
            insts.push(inst);
          }
        }
      }
      for (let i = 0; i < insts.length; i++) {
        const cfg = typeMap.get(insts[i].typeId);
        if (cfg == null) {
          continue;
        }
        const blocks = shiftToBlocks(insts[i], cfg, params);
        for (let j = 0; j < blocks.length; j++) {
          const b: Interval = blocks[j];
          const isRecovery = b.tag === BlockTag.RECOVERY;
          items.push({
            start: b.start, end: b.end,
            name: isRecovery ? cfg.name + '·恢复' : cfg.name,
            color: isRecovery ? RECOVERY_COLOR : cfg.color
          });
        }
      }

      // ② 课程：学期周次 + 单双周 + 节次模板
      if (termStart > 0) {
        for (let d = 0; d < 7; d++) {
          const ed = this.weekStart + d;
          const week = termWeekOf(termStart, ed);
          if (week < 1) {
            continue;
          }
          const wd = weekdayOf(ed);
          for (let i = 0; i < courses.length; i++) {
            const c = courses[i];
            if (c.weekday !== wd || week < c.weekFrom || week > c.weekTo) {
              continue;
            }
            if (c.parity === 1 && week % 2 === 0) {
              continue;
            }
            if (c.parity === 2 && week % 2 === 1) {
              continue;
            }
            const first = sectionTimes[c.sectionStart - 1];
            const last = sectionTimes[c.sectionEnd - 1];
            if (first == null || last == null) {
              continue;
            }
            const base = ed * MIN_PER_DAY;
            items.push({ start: base + first.startMin, end: base + last.endMin, name: c.name, color: COURSE_COLOR });
          }
        }
      }

      // ③ 共同计划（双方共享，双侧周视图都显示；冲突计划红色）
      for (let i = 0; i < plans.length; i++) {
        const p = plans[i];
        items.push({
          start: p.start, end: p.end, name: p.title,
          color: p.status === 'CONFLICT' ? PLAN_CONFLICT_COLOR : PLAN_COLOR
        });
      }

      items.sort((a: WeekItem, b: WeekItem) => a.start - b.start);
      this.weekItems = items;
    } catch (e) {
      this.weekItems = [];
    }
    this.loading = false;
  }

  /**
   * 装配当前周的共同空闲：读模型给的是"现在起"的窗口，周历要能翻到过去与更远的周，
   * 因此按周起点取全量（ALL 档）再按日裁剪；筛选只在列表视图生效，两个视图看到的是同一批窗口。
   */
  async loadCommonWeek(): Promise<void> {
    this.loading = true;
    try {
      const params = SettingsStoreParams();
      this.horizonDays = params.horizonDays;
      const filter: WindowFilter = {
        key: WindowFilterKey.ALL,
        fromEpochMin: this.weekStart * MIN_PER_DAY
      };
      const page = await CommonTimeQueryService.getCommonTimePage(filter, this.nowEpochMin());
      const weekEnd = (this.weekStart + 7) * MIN_PER_DAY;
      const wins: WindowSummary[] = [];
      for (let i = 0; i < page.windows.length; i++) {
        const w = page.windows[i];
        if (w.start < weekEnd && w.end > this.weekStart * MIN_PER_DAY) {
          wins.push(w);
        }
      }
      this.commonWindows = wins;
      this.fitAxis();
    } catch (e) {
      this.commonWindows = [];
    }
    this.loading = false;
  }

  /** 纵轴自适应：默认 06:00–24:00，凌晨有空闲才把起点往上撑；每小时高度按可用高度反推。 */
  private fitAxis(): void {
    let h0 = AXIS_DEFAULT_START;
    const days = this.weekDays();
    for (let i = 0; i < days.length; i++) {
      if (!this.isKnown(days[i])) {
        continue;
      }
      const blocks = this.dayFreeBlocks(days[i]);
      for (let j = 0; j < blocks.length; j++) {
        const startMin = blocks[j].start - days[i] * MIN_PER_DAY;
        h0 = Math.min(h0, Math.floor(startMin / 60));
      }
    }
    this.axisStart = h0;
    const hours = AXIS_END - h0;
    this.hourH = Math.max(HOUR_H_MIN, Math.min(HOUR_H_MAX, Math.floor(GRID_BUDGET / hours)));
  }

  /** 该日是否在计算视界内：视界外的列不画块、不可点，避免把"没算"当成"没空"。 */
  private isKnown(epochDay: number): boolean {
    const today = todayEpochDay();
    return epochDay >= today && epochDay < today + this.horizonDays;
  }

  private gridH(): number {
    return this.isCommon() ? (AXIS_END - this.axisStart) * this.hourH : GRID_H;
  }

  private axisHours(): number[] {
    if (!this.isCommon()) {
      return HOURS;
    }
    const out: number[] = [];
    for (let h = this.axisStart; h < AXIS_END; h++) {
      out.push(h);
    }
    return out;
  }

  /** 刻度文字间隔：格子越矮越疏（与原型同口径），网格线仍每小时一条。 */
  private showHourLabel(h: number): boolean {
    return (h - this.axisStart) % (this.hourH >= 22 ? 2 : 3) === 0;
  }

  /** 某日的日程块（把绝对区间裁剪到该自然日内，跨天班次自然断到两列）。 */
  dayItems(epochDay: number): WeekItem[] {
    const s = epochDay * MIN_PER_DAY;
    const e = s + MIN_PER_DAY;
    const out: WeekItem[] = [];
    for (let i = 0; i < this.weekItems.length; i++) {
      const it = this.weekItems[i];
      const cs = Math.max(it.start, s);
      const ce = Math.min(it.end, e);
      if (ce > cs) {
        out.push({ start: cs, end: ce, name: it.name, color: it.color });
      }
    }
    return out;
  }

  /** 某日的共同空闲块：只取常规通道（旅行通道与常规窗口时间重叠，一起画会重复计时）。 */
  dayFreeBlocks(epochDay: number): FreeBlock[] {
    const s = epochDay * MIN_PER_DAY;
    const e = s + MIN_PER_DAY;
    const out: FreeBlock[] = [];
    for (let i = 0; i < this.commonWindows.length; i++) {
      const w = this.commonWindows[i];
      if (w.channel !== WindowChannel.REGULAR) {
        continue;
      }
      const cs = Math.max(w.start, s);
      const ce = Math.min(w.end, e);
      if (ce > cs) {
        out.push({ start: cs, end: ce, winStart: w.start, winEnd: w.end });
      }
    }
    out.sort((a: FreeBlock, b: FreeBlock): number => a.start - b.start);
    return out;
  }

  /** 该日是否有旅行通道窗口覆盖（表头标点，不画块）。 */
  private hasTrip(epochDay: number): boolean {
    const s = epochDay * MIN_PER_DAY;
    const e = s + MIN_PER_DAY;
    for (let i = 0; i < this.commonWindows.length; i++) {
      const w = this.commonWindows[i];
      if (w.channel === WindowChannel.TRIP && w.start < e && w.end > s) {
        return true;
      }
    }
    return false;
  }

  private dayFreeMin(epochDay: number): number {
    const blocks = this.dayFreeBlocks(epochDay);
    let total = 0;
    for (let i = 0; i < blocks.length; i++) {
      total += blocks[i].end - blocks[i].start;
    }
    return total;
  }

  private dayTotalLabel(epochDay: number): string {
    const total = this.dayFreeMin(epochDay);
    if (total <= 0) {
      return '—';
    }
    if (total < 60) {
      return total + 'm';
    }
    const h = Math.floor(total / 60);
    return h + (total % 60 >= 30 ? '.5' : '') + 'h';
  }

  private freeBg(minutes: number): Resource {
    if (minutes >= FREE_HIGH_MIN) {
      return DesignTokens.primary;
    }
    if (minutes >= FREE_MID_MIN) {
      return DesignTokens.freeMid;
    }
    return DesignTokens.freeLow;
  }

  private freeFg(minutes: number): Resource {
    return minutes >= FREE_MID_MIN ? DesignTokens.freeOnStrong : DesignTokens.freeOnLow;
  }

  /** 色块内文字：够高才写起止与时长，矮块只留色块本身。 */
  private blockLabel(b: FreeBlock): string {
    const minutes = b.end - b.start;
    const px = minutes / 60 * this.hourH;
    if (px < 15) {
      return '';
    }
    if (px < 30) {
      return DateLabel.hm(b.start);
    }
    const h = Math.floor(minutes / 60);
    const short = minutes < 60 ? minutes + 'm' : h + (minutes % 60 >= 30 ? '.5' : '') + 'h';
    return DateLabel.hm(b.start) + '\n' + short;
  }

  blockY(startMin: number, epochDay: number): number {
    const axisMin = this.isCommon() ? this.axisStart * 60 : 0;
    const hourH = this.isCommon() ? this.hourH : HOUR_H;
    return (startMin - epochDay * MIN_PER_DAY - axisMin) / 60 * hourH;
  }

  blockH(startMin: number, endMin: number): number {
    const hourH = this.isCommon() ? this.hourH : HOUR_H;
    const h = (endMin - startMin) / 60 * hourH;
    // 共同模式留 1vp 缝：相邻块属于不同窗口，贴死会被看成一段
    return this.isCommon() ? Math.max(h - 1, 4) : Math.max(h, 14);
  }

  /** 周历底部说明：按当前周与结果给一句可操作的话，不给空泛提示。 */
  private commonNote(): string {
    const today = todayEpochDay();
    if (this.weekStart + 7 <= today) {
      return '这一周已经过去了，点「本周」回到当前周。';
    }
    if (this.weekStart >= today + this.horizonDays) {
      return '超出计算视界，到「我的」里放宽视界天数。';
    }
    let sum = 0;
    const days = this.weekDays();
    for (let i = 0; i < days.length; i++) {
      sum += this.isKnown(days[i]) ? this.dayFreeMin(days[i]) : 0;
    }
    if (sum <= 0) {
      return '本周没有共同空闲，改班表或放宽起床/就寝后再看。';
    }
    return '点色块直接去计划，点空白处看当日明细。';
  }

  build() {
    Column({ space: 8 }) {
      this.weekNav()

      if (this.loading) {
        Text('加载中…').fontSize(12).fontColor($r('app.color.text_tertiary'))
          .width('100%').textAlign(TextAlign.Center).padding({ top: 20, bottom: 20 })
      } else if (this.isCommon()) {
        this.commonHead()
        this.commonCols()
        this.commonLegend()
        Text(this.commonNote())
          .fontSize(11).fontColor(DesignTokens.textHint)
          .width('100%').textAlign(TextAlign.Center)
      } else {
        this.scheduleHead()
        this.scheduleCols()
        if (this.weekItems.length === 0) {
          Text('本周暂无班次 / 课程 / 计划')
            .fontSize(11).fontColor($r('app.color.text_hint'))
            .width('100%').textAlign(TextAlign.Center)
        }
      }
    }
    .width('100%')
  }

  @Builder
  weekNav() {
    Row({ space: 6 }) {
      SymbolGlyph($r('sys.symbol.chevron_left'))
        .fontSize(18).fontColor([$r('app.color.text_secondary')])
        .padding({ left: 6, right: 6 })
        .onClick(() => this.prevWeek())
      Text(DateLabel.md(this.weekStart) + ' – ' + DateLabel.md(this.weekStart + 6))
        .fontSize(14).fontWeight(FontWeight.Medium)
        .layoutWeight(1).textAlign(TextAlign.Center)
        .onClick(() => this.goCurrentWeek())
      SymbolGlyph($r('sys.symbol.chevron_right'))
        .fontSize(18).fontColor([$r('app.color.text_secondary')])
        .padding({ left: 6, right: 6 })
        .onClick(() => this.nextWeek())
      Text('本周').fontSize(12).fontColor($r('app.color.brand_pink'))
        .padding({ left: 8, right: 8, top: 4, bottom: 4 })
        .borderRadius(10)
        .backgroundColor($r('app.color.brand_pink_bg'))
        .onClick(() => this.goCurrentWeek())
    }.width('100%')
  }

  // ---------- 日程模式 ----------

  @Builder
  scheduleHead() {
    Row() {
      Column().width(LABEL_W)
      ForEach(this.weekDays(), (ed: number, idx: number) => {
        Column({ space: 1 }) {
          Text(DAY_HEADERS[idx])
            .fontSize(10)
            .fontColor(ed === todayEpochDay() ? $r('app.color.brand_pink') : $r('app.color.text_tertiary'))
          Text('' + DateLabel.ymd(ed).d)
            .fontSize(11).fontWeight(FontWeight.Medium)
            .fontColor(ed === todayEpochDay() ? $r('app.color.brand_pink') : $r('app.color.text_secondary'))
        }
        .width('14.28%')
        .alignItems(HorizontalAlign.Center)
      }, (ed: number, idx: number) => '' + ed + '-' + idx)
    }.width('100%')
  }

  @Builder
  scheduleCols() {
    Row() {
      Column() {
        ForEach(HOURS, (h: number) => {
          Row() {
            Text(pad2(h))
              .fontSize(8).fontColor($r('app.color.text_hint'))
              .visibility(h % 2 === 0 ? Visibility.Visible : Visibility.None)
          }
          .width(LABEL_W)
          .height(HOUR_H)
          .alignItems(VerticalAlign.Top)
        }, (h: number) => 'h' + h)
      }.height(GRID_H)

      Row() {
        ForEach(this.weekDays(), (ed: number) => {
          Stack({ alignContent: Alignment.TopStart }) {
            // 小时网格线
            Column() {
              ForEach(HOURS, (h: number) => {
                Row()
                  .width('100%')
                  .height(HOUR_H)
                  .border({ width: { bottom: 0.5 }, color: $r('app.color.divider') })
              }, (h: number) => 'l' + h)
            }.width('100%').height(GRID_H)

            // 今日列高亮
            if (ed === todayEpochDay()) {
              Column()
                .width('100%').height(GRID_H)
                .backgroundColor($r('app.color.brand_pink_bg'))
            }

            // 日程块
            ForEach(this.dayItems(ed), (item: WeekItem) => {
              Column() {
                Text(item.name)
                  .fontSize(9).fontColor('#FFFFFF')
                  .maxLines(2)
                  .width('100%').textAlign(TextAlign.Center)
              }
              .width('92%')
              .height(this.blockH(item.start, item.end))
              .position({ x: 1, y: this.blockY(item.start, ed) })
              .backgroundColor(item.color)
              .borderRadius(4)
              .clip(true)
            }, (item: WeekItem) => '' + item.start + '-' + item.end + item.name)
          }
          .width('14.28%')
          .height(GRID_H)
          .clip(true)
          .border({ width: { right: 0.5 }, color: $r('app.color.divider') })
        }, (ed: number) => 'c' + ed)
      }
      .layoutWeight(1)
      .height(GRID_H)
    }
    .width('100%')
    .height(GRID_H)
  }

  // ---------- 共同空闲模式 ----------

  @Builder
  commonHead() {
    Row() {
      Column() {
        Text('纵轴')
          .fontSize(8).fontColor(DesignTokens.textHint)
        Text(pad2(this.axisStart) + '–24')
          .fontSize(8).fontColor(DesignTokens.textHint)
      }
      .width(LABEL_W)
      .alignItems(HorizontalAlign.Center)

      ForEach(this.weekDays(), (ed: number, idx: number) => {
        Column({ space: 1 }) {
          Text(DAY_HEADERS[idx])
            .fontSize(10)
            .fontColor(ed === todayEpochDay() ? DesignTokens.primary : DesignTokens.textTertiary)
          Text('' + DateLabel.ymd(ed).d)
            .fontSize(11).fontWeight(FontWeight.Medium)
            .fontColor(ed === todayEpochDay() ? DesignTokens.primary : DesignTokens.textSecondary)
          Text(this.isKnown(ed) ? this.dayTotalLabel(ed) : '·')
            .fontSize(8)
            .fontColor(this.isKnown(ed) ? DesignTokens.textSecondary : DesignTokens.textHint)
          Circle()
            .width(4).height(4)
            .fill(this.hasTrip(ed) ? tagColor(WindowTag.TRIP) : Color.Transparent)
        }
        .width('14.28%')
        .alignItems(HorizontalAlign.Center)
      }, (ed: number, idx: number) => 'ch' + ed + '-' + idx)
    }
    .width('100%')
    .alignItems(VerticalAlign.Top)
  }

  @Builder
  commonCols() {
    Row() {
      Column() {
        ForEach(this.axisHours(), (h: number) => {
          Row() {
            if (this.showHourLabel(h)) {
              Text(pad2(h % 24))
                .fontSize(8).fontColor(DesignTokens.textHint)
            }
          }
          .width(LABEL_W)
          .height(this.hourH)
          .alignItems(VerticalAlign.Top)
        }, (h: number) => 'ch' + h)
      }.height(this.gridH())

      Row() {
        ForEach(this.weekDays(), (ed: number) => {
          Stack({ alignContent: Alignment.TopStart }) {
            Column() {
              ForEach(this.axisHours(), (h: number) => {
                Row()
                  .width('100%')
                  .height(this.hourH)
                  .border({ width: { bottom: 0.5 }, color: DesignTokens.divider })
              }, (h: number) => 'cl' + h)
            }.width('100%').height(this.gridH())

            if (ed === todayEpochDay()) {
              Column()
                .width('100%').height(this.gridH())
                .backgroundColor(DesignTokens.primaryBg)
            }
            if (!this.isKnown(ed)) {
              // 视界外：压暗且不响应点击，避免把"没算"当成"没空"
              Column()
                .width('100%').height(this.gridH())
                .backgroundColor(DesignTokens.fillWeak)
                .opacity(0.6)
            }

            ForEach(this.dayFreeBlocks(ed), (b: FreeBlock) => {
              Column() {
                Text(this.blockLabel(b))
                  .fontSize(9).fontColor(this.freeFg(b.end - b.start))
                  .maxLines(2)
                  .width('100%').textAlign(TextAlign.Center)
              }
              .width('92%')
              .height(this.blockH(b.start, b.end))
              .position({ x: 1, y: this.blockY(b.start, ed) })
              .backgroundColor(this.freeBg(b.end - b.start))
              .borderRadius(4)
              .clip(true)
              .onClick(() => this.onPickWindow(b.winStart, b.winEnd))
            }, (b: FreeBlock) => '' + b.winStart + '-' + b.winEnd + '-' + b.start)
          }
          .width('14.28%')
          .height(this.gridH())
          .clip(true)
          .border({ width: { right: 0.5 }, color: DesignTokens.divider })
          .onClick(() => {
            if (this.isKnown(ed)) {
              this.onPickDay(ed);
            }
          })
        }, (ed: number) => 'cc' + ed)
      }
      .layoutWeight(1)
      .height(this.gridH())
    }
    .width('100%')
    .height(this.gridH())
  }

  @Builder
  legendDot(color: ResourceColor, label: string) {
    Row({ space: 4 }) {
      Circle().width(8).height(8).fill(color)
      Text(label).fontSize(10).fontColor(DesignTokens.textHint)
    }
  }

  @Builder
  commonLegend() {
    Row({ space: 10 }) {
      this.legendDot(DesignTokens.primary, '≥6h')
      this.legendDot(DesignTokens.freeMid, '3–6h')
      this.legendDot(DesignTokens.freeLow, '<3h')
      this.legendDot(tagColor(WindowTag.TRIP), '可过夜')
    }
    .width('100%')
    .justifyContent(FlexAlign.Center)
  }
}
