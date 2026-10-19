import { Interval, MIN_PER_DAY, WindowChannel, WindowTag, nowEpochMin, todayEpochDay,
  weekdayOf, clipInto, dayOfStart, intersects } from 'domain';
import { DateLabel } from 'commons';
import { SettingsStore } from 'data';
import {
  CommonTimeQueryService, ScheduleOverviewQueryService, SettingsStoreParams, WeekBlock,
  WeekLanes, WeekSchedule, WindowFilter, WindowFilterKey, WindowSummary
} from 'feature';
import { DesignTokens } from '../theme/DesignTokens';
import { busyTagLabel, tagColor } from '../util/WindowTagUtil';
import { LatestLanding } from '../util/LatestLanding';
import { AccessibilityPolicy } from '../accessibility/AccessibilityPolicy';
import { NoticeBar, NoticeTone } from './NoticeBar';
import { LocalTween } from '../util/LocalTween';
import { WeekNavigator } from './WeekNavigator';

/** 周视图模式：某一方的日程，或双方的共同空闲。 */
export const WEEK_MODE_SCHEDULE = 'SCHEDULE';
export const WEEK_MODE_COMMON = 'COMMON';

const LABEL_W = 26;
/** 7 枚列的宽度基准只写这一处，列头与网格共用。 */
const WEEK_COL_W = '14.28%';
const DAY_HEADERS: string[] = ['一', '二', '三', '四', '五', '六', '日'];
/** 共同空闲分级门槛（分钟）：≥6h / ≥3h / 其余。 */
const FREE_HIGH_MIN = 360;
const FREE_MID_MIN = 180;
/** 网格可用高度（vp）：两种模式都按它反推每小时高度，块越少格子越高，总高不会超过这一档。 */
const GRID_BUDGET = 452;
/** 每小时高度上下限。下限分模式：日程块里要放两行文字，不能压到只剩色块那么矮。 */
const HOUR_H_MIN_COMMON = 13;
const HOUR_H_MIN_SCHEDULE = 18;
const HOUR_H_MAX = 30;
/** 默认只画 06:00–24:00：凌晨与深夜一律缩略，有内容落在外面才把坐标轴撑开。 */
const AXIS_DEFAULT_START = 6;
const AXIS_END = 24;
/** 泳道块最低高度（vp）：半小时的忙碌在矮格里也只有 6vp，再低就看不出那一条了。 */
const LANE_MIN_H = 6;

/** 共同空闲块：裁剪到当日后的区间 + 所属窗口的原始起止。 */
interface FreeBlock {
  start: number;
  end: number;
  /** 原始窗口起止：点击必须回传它，列表与周历选中的才是同一个窗口。 */
  winStart: number;
  winEnd: number;
}

/** 忙碌泳道块：区间已裁剪到当日，tag 是忙碌类型（块里不放文字，类型只由读屏念出）。 */
interface LaneBlock {
  start: number;
  end: number;
  tag: string;
}

interface WeekPlanArg { plan: WeekBlock; day: number; }

/** 当前周周一。 */
export function currentWeekStart(): number {
  const today = todayEpochDay();
  return today - (weekdayOf(today) - 1);
}

function pad2(n: number): string {
  return n < 10 ? '0' + n : '' + n;
}

/** 周视图网格，两种模式共用一套周导航与列布局： */
@Component
export struct WeekScheduleView {
  @Prop @Watch('onActiveChanged') active: boolean = true;
  private mounted: boolean = false;
  initialWeekStart: number = -1;
  onWeekChange: (day: number) => void = () => {};
  @Prop @Watch('reload') owner: string = 'ME';
  /** 模式由父页决定且运行期不变：日程模式读班表，共同模式读窗口读模型。 */
  mode: string = WEEK_MODE_SCHEDULE;
  /** 点列：日程模式=改这天的班（临时调整），共同模式=看当日明细。 */
  onPickDay: (epochDay: number) => void = () => {
  };
  /** 共同模式：点色块去建计划，回传的是原始窗口起止。 */
  onPickWindow: (start: number, end: number) => void = () => {
  };
  /** 共同模式：父页下拉刷新时自增。父页读模型已换新，这里跟着重读，不自己再算一次。 */
  @Prop @Watch('reload') refreshTick: number = 0;
  @State weekStart: number = currentWeekStart();
  @State loading: boolean = true;
  /** 这一周是没读到，还是真的没有：两者在界面上必须是两句话（失败态不能说成"没有"）。 */
  @State failed: boolean = false;
  @State private reading: boolean = false;
  private displayedKey: string = '';
  @State weekItems: WeekBlock[] = [];
  @State commonWindows: WindowSummary[] = [];
  /** 共同模式的双方忙碌泳道：没有 TA 数据时 partner 为 null（右半不画，图例跟着改说法）。 */
  @State myLanes: Interval[] = [];
  @State private planBlocks: WeekBlock[] = [];
  @State partnerLanes: Interval[] | null = null;
  @State axisStart: number = AXIS_DEFAULT_START;
  @State hourH: number = 24;
  @State horizonDays: number = 0;
  @StorageProp('recomputeCount') @Watch('reload') recomputeCount: number = 0;
  // 装饰器实参必须是字面量，取值与 SENIOR_MODE_KEY 保持一致。
  @StorageProp('crd_senior_mode') senior: boolean = false;
  /** 钟点广播键：回前台与切页时自增，「现在」游标跟着重取一次值。 */
  @StorageProp('crdClockTick') @Watch('refreshNow') clockTick: number = 0;
  /** 当下分钟数（epoch 分钟，与窗口起止同一把尺子）；0 表示还没看过钟。 */
  @State nowMin: number = 0;
  @State private partnerName: string = 'TA';
  @State private weekOffset: number = 0;
  @State private weekAlpha: number = 1;
  private weekDirection: number = 0;
  private weekTween: LocalTween = new LocalTween();
  private loadedOwner: string = '';
  /** 并发读数闸门：owner 切换、父页下拉、重算广播、翻页点击四个触发点共用这一周的数据面， */
  private landing: LatestLanding = new LatestLanding();

  aboutToAppear(): void {
    this.mounted = true;
    if (this.initialWeekStart >= 0) {
      this.weekStart = this.initialWeekStart;
    }
    this.loadWeek();
  }

  aboutToDisappear(): void {
    this.mounted = false;
    this.landing.begin();
    this.weekTween.cancel();
  }
  onActiveChanged(): void {
    if (!this.active) { this.landing.invalidate(); this.weekTween.cancel(); return; }
    if (this.mounted) this.loadWeek();
  }

  /** 重新看一眼钟：不排定时器、不做常驻动画，进页面/回前台时准就够了（K-4③ 的口径）。 */
  refreshNow(): void {
    this.nowMin = nowEpochMin();
  }

  reload(): void {
    this.loadWeek();
  }

  prevWeek(): void {
    this.moveToWeek(this.weekStart - 7);
  }

  nextWeek(): void {
    this.moveToWeek(this.weekStart + 7);
  }

  goCurrentWeek(): void {
    this.moveToWeek(currentWeekStart());
  }

  private moveToWeek(target: number): void {
    if (target === this.weekStart) {
      return;
    }
    this.weekTween.cancel();
    this.weekDirection = target > this.weekStart ? 1 : -1;
    this.weekOffset = this.weekDirection * 24;
    this.weekAlpha = 0;
    this.weekStart = target;
    this.onWeekChange(this.weekStart);
    this.loadWeek();
  }

  private finishWeekMotion(): void {
    if (this.weekDirection === 0) {
      return;
    }
    const from = this.weekDirection * 24;
    this.weekDirection = 0;
    const reduce: boolean = AppStorage.get<boolean>('crd_reduce_motion') ?? false;
    this.weekTween.play(this.getUIContext(), 0, 1, DesignTokens.motion(reduce, 220), (progress: number) => {
      this.weekOffset = from * (1 - progress);
      this.weekAlpha = progress;
    });
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

  loadWeek(): void {
    if (!this.mounted || !this.active) return;
    if (!this.isCommon() && this.loadedOwner !== this.owner) {
      this.weekItems = [];
      this.failed = false;
      this.loadedOwner = this.owner;
    }
    // 每次读数顺带重取一次当下：翻页/切侧/首帧都经过这里，游标不会停在旧分钟上
    this.refreshNow();
    if (this.isCommon()) {
      this.loadCommonWeek();
      return;
    }
    this.loadScheduleWeek();
  }

  /** 周日程块由 feature 读模型装配（班次+课程+共同计划），这里只负责画。 */
  async loadScheduleWeek(): Promise<void> {
    const token = this.landing.begin();
    const key = this.mode + ':' + this.owner + ':' + this.weekStart;
    const retain = this.displayedKey === key;
    this.reading = true; this.loading = !retain;
    try {
      this.partnerName = SettingsStore.getPartnerDisplayName() || 'TA';
      const data: WeekSchedule = await ScheduleOverviewQueryService.getWeekSchedule(this.owner,
        this.weekStart);
      if (!this.landing.isCurrent(token)) {
        return;
      }
      this.weekItems = data.blocks;
      this.displayedKey = key;
      this.failed = false;
      this.fitAxis();
    } catch (e) {
      if (!this.landing.isCurrent(token)) {
        return;
      }
      if (!retain) this.weekItems = [];
      this.failed = true;
    } finally {
      if (this.landing.isCurrent(token)) {
        this.loading = false;
        this.reading = false;
        this.finishWeekMotion();
      }
    }
  }

  /** 装配当前周的共同空闲：读模型给的是"现在起"的窗口，周历要能翻到过去与更远的周， */
  async loadCommonWeek(): Promise<void> {
    const token = this.landing.begin();
    const key = this.mode + ':' + this.owner + ':' + this.weekStart;
    const retain = this.displayedKey === key;
    this.reading = true; this.loading = !retain;
    try {
      this.partnerName = SettingsStore.getPartnerDisplayName() || 'TA';
      const params = SettingsStoreParams();
      this.horizonDays = params.horizonDays;
      const filter: WindowFilter = {
        key: WindowFilterKey.ALL,
        fromEpochMin: this.weekStart * MIN_PER_DAY
      };
      const page = await CommonTimeQueryService.getCommonTimePage(filter, this.nowMin);
      if (!this.landing.isCurrent(token)) {
        return;
      }
      const weekEnd = (this.weekStart + 7) * MIN_PER_DAY;
      const wins: WindowSummary[] = [];
      for (let i = 0; i < page.windows.length; i++) {
        const w = page.windows[i];
        if (intersects(w.start, w.end, this.weekStart * MIN_PER_DAY, weekEnd)) {
          wins.push(w);
        }
      }
      this.commonWindows = wins;
      this.failed = false;
      await this.loadLanes(token, retain);
      if (!this.landing.isCurrent(token)) {
        return;
      }
      this.fitAxis();
      this.displayedKey = key;
    } catch (e) {
      if (!this.landing.isCurrent(token)) {
        return;
      }
      if (!retain) this.commonWindows = [];
      this.failed = true;
    } finally {
      if (this.landing.isCurrent(token)) {
        this.loading = false;
        this.reading = false;
        this.finishWeekMotion();
      }
    }
  }

  /** 单独读一周的双方忙碌。失败只让左右两半空着：空闲块是另一条读模型算好的， */
  private async loadLanes(token: number, retain: boolean): Promise<void> {
    try {
      const lanes: WeekLanes = await ScheduleOverviewQueryService.getWeekLanes(this.weekStart);
      if (!this.landing.isCurrent(token)) {
        return;
      }
      this.myLanes = lanes.mine;
      this.partnerLanes = lanes.partner;
      this.planBlocks = lanes.plans;
    } catch (e) {
      if (!this.landing.isCurrent(token)) {
        return;
      }
      this.failed = true;
      if (!retain) {
        this.myLanes = [];
        this.partnerLanes = null;
        this.planBlocks = [];
      }
    }
  }

  /** 纵轴自适应：默认只画 06:00–24:00（深夜直接缩略），有内容落在六点之前才把起点往上撑。 */
  private fitAxis(): void {
    let h0 = AXIS_DEFAULT_START;
    const days = this.weekDays();
    for (let i = 0; i < days.length; i++) {
      const day = days[i];
      if (this.isCommon()) {
        if (!this.isKnown(day)) {
          continue;
        }
        const blocks = this.dayFreeBlocks(day);
        for (const plan of this.dayPlanBlocks(day)) h0 = Math.min(h0, this.startHour(plan.start, day));
        for (let j = 0; j < blocks.length; j++) {
          h0 = Math.min(h0, this.startHour(blocks[j].start, day));
        }
      } else {
        const items = this.dayItems(day);
        for (let j = 0; j < items.length; j++) {
          h0 = Math.min(h0, this.startHour(items[j].start, day));
        }
      }
    }
    this.axisStart = h0;
    const hours = AXIS_END - h0;
    const min = this.isCommon() ? HOUR_H_MIN_COMMON : HOUR_H_MIN_SCHEDULE;
    this.hourH = Math.max(min, Math.min(HOUR_H_MAX, Math.floor(GRID_BUDGET / hours)));
  }

  /** 块起点落在当日第几小时。块已按自然日裁剪，末端不会超过 24:00，轴只需往起点方向撑。 */
  private startHour(startMin: number, epochDay: number): number {
    return Math.floor((startMin - epochDay * MIN_PER_DAY) / 60);
  }

  /** 该日是否在计算视界内：视界外的列不画块、不可点，避免把"没算"当成"没空"。 */
  private isKnown(epochDay: number): boolean {
    const today = todayEpochDay();
    return epochDay >= today && epochDay < today + this.horizonDays;
  }

  private gridH(): number {
    return (AXIS_END - this.axisStart) * this.hourH;
  }

  private axisHours(): number[] {
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
  dayItems(epochDay: number): WeekBlock[] {
    const s = epochDay * MIN_PER_DAY;
    const e = s + MIN_PER_DAY;
    const out: WeekBlock[] = [];
    for (let i = 0; i < this.weekItems.length; i++) {
      const it = this.weekItems[i];
      const c = clipInto(it.start, it.end, s, e);
      if (c == null) {
        continue;
      }
      out.push({ id: it.id, kind: it.kind, start: c.start, end: c.end, name: it.name, color: it.color,
        conflicted: it.conflicted });
    }
    return out;
  }

  private dayPlanBlocks(epochDay: number): WeekBlock[] {
    const s = epochDay * MIN_PER_DAY;
    const e = s + MIN_PER_DAY;
    const out: WeekBlock[] = [];
    for (const it of this.planBlocks) {
      const c = clipInto(it.start, it.end, s, e);
      if (c !== null) out.push({ id: it.id, kind: it.kind, start: c.start, end: c.end,
        name: it.name, color: it.color, conflicted: it.conflicted });
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
      const c = clipInto(w.start, w.end, s, e);
      if (c != null) {
        out.push({ start: c.start, end: c.end, winStart: w.start, winEnd: w.end });
      }
    }
    out.sort((a: FreeBlock, b: FreeBlock): number => a.start - b.start);
    return out;
  }

  /** 某日的忙碌泳道块：跨天班次/夜班自然断到两列，与日程模式同一套裁剪口径。无数据（null）给空数组。 */
  private dayLanes(list: Interval[] | null, epochDay: number): LaneBlock[] {
    const s = epochDay * MIN_PER_DAY;
    const e = s + MIN_PER_DAY;
    const out: LaneBlock[] = [];
    if (list == null) {
      return out;
    }
    for (let i = 0; i < list.length; i++) {
      const it = list[i];
      const c = clipInto(it.start, it.end, s, e);
      if (c == null) {
        continue;
      }
      out.push({ start: c.start, end: c.end, tag: it.tag });
    }
    return out;
  }

  /** 泳道块的朗读文本。块里一个像素的文字都放不下（半列宽约 40vp）， */
  private laneRead(who: string, b: LaneBlock, epochDay: number): string {
    return DateLabel.weekday(epochDay) + ' ' + who + ' ' + DateLabel.hm(b.start) + ' 到 '
      + DateLabel.edgeTime(b.end, true) + '，' + busyTagLabel(b.tag);
  }

  /** 该日是否有旅行通道窗口覆盖（表头标点，不画块）。 */
  private hasTrip(epochDay: number): boolean {
    const s = epochDay * MIN_PER_DAY;
    const e = s + MIN_PER_DAY;
    for (let i = 0; i < this.commonWindows.length; i++) {
      const w = this.commonWindows[i];
      if (w.channel === WindowChannel.TRIP && intersects(w.start, w.end, s, e)) {
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

  /** 空闲块的朗读文本。矮块上面根本没有文字（blockLabel 返回空串）， */
  private freeBlockRead(b: FreeBlock, epochDay: number): string {
    return DateLabel.weekday(epochDay) + ' ' + DateLabel.hm(b.start) + ' 到 ' + DateLabel.edgeTime(b.end, true)
      + '，' + DateLabel.duration(b.end - b.start) + '共同空闲，点击去计划';
  }

  /** 日程块的朗读文本：名称 + 当日内的起止（跨天班次已裁剪到本列）。 */
  private scheduleBlockRead(item: WeekBlock, epochDay: number): string {
    return DateLabel.weekday(epochDay) + ' ' + item.name + ' ' + DateLabel.hm(item.start) + ' 到 '
      + DateLabel.edgeTime(item.end, true);
  }

  /** 表头一列的朗读文本：日期 + 今天标记 + 当天空闲总量 + 旅行标点（点只靠颜色，读屏要说法）。 */
  private headRead(epochDay: number): string {
    let s = DateLabel.mdw(epochDay);
    if (epochDay === todayEpochDay()) {
      s += '，今天';
    }
    if (this.isCommon()) {
      if (!this.isKnown(epochDay)) {
        // 视界外的列画的是「·」，读屏不能把它念成"空闲 —"，要说明是没算
        s += '，超出计算范围';
      } else {
        s += '，当天共同空闲 ' + this.dayTotalLabel(epochDay);
        if (this.hasTrip(epochDay)) {
          s += '，有可过夜窗口';
        }
      }
    }
    return s;
  }

  blockY(startMin: number, epochDay: number): number {
    return (startMin - epochDay * MIN_PER_DAY - this.axisStart * 60) / 60 * this.hourH;
  }

  blockH(startMin: number, endMin: number): number {
    const h = (endMin - startMin) / 60 * this.hourH;
    // 共同模式留 1vp 缝：相邻块属于不同窗口，贴死会被看成一段
    return this.isCommon() ? Math.max(h - 1, 4) : Math.max(h, 14);
  }

  /** 游标所在的那天取自 `nowMin` 自己，不再于渲染时另读一次表： */
  private nowDay(): number {
    return dayOfStart(this.nowMin);
  }

  /** 「现在」游标画不画：落在纵轴覆盖的那段里才有容身之处。 */
  nowShown(): boolean {
    const minuteOfDay = this.nowMin % MIN_PER_DAY;
    return minuteOfDay >= this.axisStart * 60 && minuteOfDay <= AXIS_END * 60;
  }

  /** 「现在」静态游标：一枚点 + 一条向右淡出的细线，压在色块之上，只作装饰。 */
  @Builder
  nowMarker() {
    Row()
      .width('100%')
      .height(1.5)
      .position({ x: 0, y: this.blockY(this.nowMin, this.nowDay()) })
      .linearGradient({ angle: 90, colors: [[DesignTokens.primary, 0], [Color.Transparent, 1]] })
      .accessibilityLevel('no')
    Circle()
      .width(5)
      .height(5)
      .fill(DesignTokens.primary)
      .position({ x: 0, y: this.blockY(this.nowMin, this.nowDay()) - 2 })
      .accessibilityLevel('no')
  }

  /** 周历底部说明：按当前周与结果给一句可操作的话，不给空泛提示。 */
  private commonNote(): string {
    const today = todayEpochDay();
    if (this.weekStart + 7 <= today) {
      return '这一周已经过去了，点「本周」回到当前周。';
    }
    if (this.weekStart >= today + this.horizonDays) {
      return '已经超出计算范围，到「我的」里把天数调大。';
    }
    let sum = 0;
    const days = this.weekDays();
    for (let i = 0; i < days.length; i++) {
      sum += this.isKnown(days[i]) ? this.dayFreeMin(days[i]) : 0;
    }
    if (sum <= 0) {
      return '这周没有共同空闲，改改班表或放宽作息再看。';
    }
    return '点色块直接去计划，点空白处看当日明细。';
  }

  build() {
    Column({ space: 4 }) {
      this.weekNav()
      this.axisLine()
      Column({ space: 4 }) {
        this.weekBody()
      }
      .width('100%').translate({ x: this.weekOffset }).opacity(this.weekAlpha)
      .hitTestBehavior(this.loading || this.reading ? HitTestMode.None : HitTestMode.Default)
    }
    .width('100%').clip(true)
  }

  @Builder
  weekBody() {
      if (this.isCommon()) {
        this.commonHead()
        this.commonCols()
        this.busyLegendLine()
        this.commonLegend()
        if (this.failed) {
          // 失败不能念成「这周没有共同空闲」：那句还带着"去改班表"的指令，
          // 用户会照着一句没读出来的话去动真实排班。
          NoticeBar({
            tone: NoticeTone.ERROR,
            title: '这一周没读到',
            body: '不是没有共同空闲，是这次没读出来。',
            actionLabel: '重试',
            onAction: () => {
              this.loadWeek();
            }
          })
        } else if (!this.loading) {
          Text(this.commonNote())
            .fontSize(11).fontColor(DesignTokens.textHint)
            .width('100%').textAlign(TextAlign.Center)
        }
      } else {
        this.scheduleHead()
        this.scheduleCols()
        if (this.failed) {
          NoticeBar({
            tone: NoticeTone.ERROR,
            title: '这一周没读到',
            body: '不是这周没有安排，是这次没读出来。',
            actionLabel: '重试',
            onAction: () => {
              this.loadWeek();
            }
          })
        } else if (!this.loading && this.weekItems.length === 0) {
          Text('这周还没有班次、课程和计划')
            .fontSize(11).fontColor($r('app.color.text_hint'))
            .width('100%').textAlign(TextAlign.Center)
        }
      }
  }

  @Builder
  weekNav() {
    WeekNavigator({ weekStart: this.weekStart, horizontalOffset: this.weekOffset, alpha: this.loading ? 1 : this.weekAlpha,
      onPrevious: () => this.prevWeek(), onNext: () => this.nextWeek(), onCurrent: () => this.goCurrentWeek() })
  }

  /** 更新状态与纵轴说明共用一行，不保留空的加载占位。 */
  @Builder
  axisLine() {
    Row({ space: 8 }) {
      Text(this.loading ? '更新中…' : '')
        .fontSize(10).fontColor(DesignTokens.textHint)
      Blank()
      Text('纵轴 ' + pad2(this.axisStart) + '–24')
        .fontSize(10).fontColor(DesignTokens.textHint)
    }.width('100%')
  }

  // ---------- 日程模式 ----------

  @Builder
  scheduleHead() {
    Row() {
      Column().width(LABEL_W).accessibilityLevel('no')
      // 与 scheduleCols 同一个基准：7 枚列铺在扣掉刻度占位的那一段上，逐列对齐下方的网格
      Row() {
        ForEach(this.weekDays(), (ed: number, idx: number) => {
          Column({ space: 1 }) {
            Text(DAY_HEADERS[idx])
              .fontSize(10)
              .fontColor(ed === todayEpochDay() ? $r('app.color.text_accent') : $r('app.color.text_tertiary'))
            Text('' + DateLabel.ymd(ed).d)
              .fontSize(11).fontWeight(FontWeight.Medium)
              .fontColor(ed === todayEpochDay() ? $r('app.color.text_accent') : $r('app.color.text_secondary'))
          }
          .width(WEEK_COL_W)
          .alignItems(HorizontalAlign.Center)
          // 星期字 + 日号两枚 Text 读成一句，今天靠颜色额外标出来的部分由文本自己带上
          .accessibilityGroup(true)
          .accessibilityText(this.headRead(ed))
          .constraintSize({ minHeight: AccessibilityPolicy.minHit(this.senior) })
          .focusable(true)
          .onClick(() => this.onPickDay(ed))
        }, (ed: number, idx: number) => '' + ed + '-' + idx)
      }
      .layoutWeight(1)
    }.width('100%')
  }

  @Builder
  scheduleCols() {
    Row() {
      Column() {
        ForEach(this.axisHours(), (h: number) => {
          Row() {
            if (this.showHourLabel(h)) {
              Text(pad2(h))
                .fontSize(8).fontColor($r('app.color.text_hint'))
                .accessibilityLevel('no')
            }
          }
          .width(LABEL_W)
          .height(this.hourH)
          .alignItems(VerticalAlign.Top)
        }, (h: number) => 'sh' + h)
      }
      .height(this.gridH())

      Row() {
        ForEach(this.weekDays(), (ed: number) => {
          Stack({ alignContent: Alignment.TopStart }) {
            // 小时网格线
            Column() {
              ForEach(this.axisHours(), (h: number) => {
                Row()
                  .width('100%')
                  .height(this.hourH)
                  .border({ width: { bottom: 0.5 }, color: $r('app.color.divider') })
              }, (h: number) => 'sl' + h)
            }.width('100%').height(this.gridH()).accessibilityLevel('no')

            // 今日列高亮
            if (ed === todayEpochDay()) {
              Column()
                .width('100%').height(this.gridH())
                .backgroundColor($r('app.color.brand_pink_bg'))
                .accessibilityLevel('no')
            }

            ForEach(this.dayItems(ed), (item: WeekBlock) => {
              if (item.kind === 'PLAN') {
                this.planBlock({ plan: item, day: ed })
              } else {
                Column() {
                  Text(item.name)
                    .fontSize(9).fontColor(DesignTokens.foregroundOn(item.color))
                    .fontWeight(FontWeight.Bold)
                    .maxLines(2)
                    .width('100%').textAlign(TextAlign.Center)
                }
                .width('92%')
                .height(this.blockH(item.start, item.end))
                .position({ x: 1, y: this.blockY(item.start, ed) })
                .backgroundColor(item.color)
                .borderRadius(DesignTokens.blockRadius())
                .clip(true)
                .accessibilityGroup(true)
                .accessibilityText(this.scheduleBlockRead(item, ed))
              }
            }, (item: WeekBlock) => '' + item.start + '-' + item.end + item.name + item.color)

            if (ed === this.nowDay() && this.nowShown()) {
              this.nowMarker()
            }
          }
          .width(WEEK_COL_W)
          .height(this.gridH())
          .clip(true)
          .border({ width: { right: 0.5 }, color: $r('app.color.divider') })
          .focusable(true)
          .accessibilityDescription('点这一列查看当日明细')
          .onClick(() => this.onPickDay(ed))
        }, (ed: number) => 'c' + ed)
      }
      .layoutWeight(1)
      .height(this.gridH())
    }
    .width('100%')
    .height(this.gridH())
  }

  // ---------- 共同空闲模式 ----------

  @Builder
  commonHead() {
    Row() {
      // 只留一格占位，让 7 列和下方网格逐列对齐；纵轴说明已挪到网格右上（见 axisLine）
      Column().width(LABEL_W).accessibilityLevel('no')

      Row() {
        ForEach(this.weekDays(), (ed: number, idx: number) => {
          Column({ space: 1 }) {
            Text(DAY_HEADERS[idx])
              .fontSize(10)
              .fontColor(ed === todayEpochDay() ? DesignTokens.textAccent : DesignTokens.textTertiary)
            Text('' + DateLabel.ymd(ed).d)
              .fontSize(11).fontWeight(FontWeight.Medium)
              .fontColor(ed === todayEpochDay() ? DesignTokens.textAccent : DesignTokens.textSecondary)
            Text(this.isKnown(ed) ? this.dayTotalLabel(ed) : '·')
              .fontSize(8)
              .fontColor(this.isKnown(ed) ? DesignTokens.textSecondary : DesignTokens.textHint)
            Circle()
              .width(4).height(4)
              .fill(this.hasTrip(ed) ? tagColor(WindowTag.TRIP) : Color.Transparent)
          }
          .width(WEEK_COL_W)
          .alignItems(HorizontalAlign.Center)
          // 四行（星期/日号/总量/旅行标点）合成一句；标点只有颜色，读屏靠 headRead 里的文字
          .accessibilityGroup(true)
          .accessibilityText(this.headRead(ed))
          .constraintSize({ minHeight: AccessibilityPolicy.minHit(this.senior) })
          .focusable(this.isKnown(ed))
          .onClick(() => {
            if (this.isKnown(ed)) {
              this.onPickDay(ed);
            }
          })
        }, (ed: number, idx: number) => 'ch' + ed + '-' + idx)
      }
      .layoutWeight(1)
    }
    .width('100%')
    .alignItems(VerticalAlign.Top)
  }

  /** 半列宽的忙碌泳道。块里一个字都不放：半列约 40vp，写「07 到 12 班次」只会糊成一团， */
  @Builder
  laneRow(b: LaneBlock, epochDay: number, partner: boolean) {
    Column()
      .width('100%')
      .height(Math.max(this.blockH(b.start, b.end), LANE_MIN_H))
      .position({ x: 0, y: this.blockY(b.start, epochDay) })
      .backgroundColor(b.tag === 'UNKNOWN' ? DesignTokens.fillWeak : partner ? DesignTokens.busyPartnerGlass : DesignTokens.busyMineGlass)
      .border({ width: 0.5, color: b.tag === 'UNKNOWN' ? DesignTokens.borderWeak : partner ? DesignTokens.busyPartnerEdge : DesignTokens.busyMineEdge })
      .borderRadius(3)
      .accessibilityGroup(true)
      .accessibilityText(this.laneRead(partner ? this.partnerName : '我', b, epochDay))
  }

  @Builder
  commonCols() {
    Row() {
      Column() {
        ForEach(this.axisHours(), (h: number) => {
          Row() {
            if (this.showHourLabel(h)) {
              // 同 scheduleCols：静音要落在刻度自己身上，右上那行「纵轴 06–24」已经把轴说明念出来了
              Text(pad2(h % 24))
                .fontSize(8).fontColor(DesignTokens.textHint)
                .accessibilityLevel('no')
            }
          }
          .width(LABEL_W)
          .height(this.hourH)
          .alignItems(VerticalAlign.Top)
        }, (h: number) => 'ch' + h)
      }
      .height(this.gridH())

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
            }.width('100%').height(this.gridH()).accessibilityLevel('no')

            if (ed === todayEpochDay()) {
              Column()
                .width('100%').height(this.gridH())
                .backgroundColor(DesignTokens.primaryBg)
                .accessibilityLevel('no')
            }
            if (!this.isKnown(ed)) {
              // 视界外：压暗且不响应点击，避免把"没算"当成"没空"
              Column()
                .width('100%').height(this.gridH())
                .backgroundColor(DesignTokens.fillWeak)
                .opacity(0.6)
                .accessibilityLevel('no')
            }

            // 双方忙碌泳道：这一列纵向分两半，左半是我、右半是 TA。
            // 画在空闲块之下——共同空闲本来就是"两边都空"，它是泳道之间的缝，色块压上去才读得出空档怎么来的。
            Row() {
              Stack({ alignContent: Alignment.TopStart }) {
                ForEach(this.dayLanes(this.myLanes, ed), (b: LaneBlock) => {
                  this.laneRow(b, ed, false)
                }, (b: LaneBlock) => 'm' + b.start + '-' + b.end + b.tag)
              }
              .layoutWeight(1)
              .height(this.gridH())

              if (this.partnerLanes != null) {
                Stack({ alignContent: Alignment.TopStart }) {
                  ForEach(this.dayLanes(this.partnerLanes, ed), (b: LaneBlock) => {
                    this.laneRow(b, ed, true)
                  }, (b: LaneBlock) => 'p' + b.start + '-' + b.end + b.tag)
                }
                .layoutWeight(1)
                .height(this.gridH())
              }
            }
            .width('100%')
            .height(this.gridH())
            // 泳道只是底色，点列看当日明细、点色块去建计划这两件事不能被它挡住
            .hitTestBehavior(HitTestMode.None)

            ForEach(this.dayFreeBlocks(ed), (b: FreeBlock) => {
              Column() {
                Text(this.blockLabel(b))
                  .fontSize(9).fontColor(this.freeFg(b.end - b.start))
                  .fontWeight(FontWeight.Bold)
                  .maxLines(2)
                  .width('100%').textAlign(TextAlign.Center)
              }
              .width('92%')
              .height(this.blockH(b.start, b.end))
              .position({ x: 1, y: this.blockY(b.start, ed) })
              .backgroundColor(this.freeBg(b.end - b.start))
              .borderRadius(DesignTokens.blockRadius())
              .clip(true)
              .focusable(true)
              .accessibilityGroup(true)
              .accessibilityText(this.freeBlockRead(b, ed))
              .clickEffect(DesignTokens.tapButton())
              .onClick(() => {
                // 切周/刷新时日期仍可看，旧空闲块不能被当作新结果拿去建计划。
                if (!this.loading && !this.reading && !this.failed) {
                  this.onPickWindow(b.winStart, b.winEnd);
                }
              })
            }, (b: FreeBlock) => '' + b.winStart + '-' + b.winEnd + '-' + b.start + '-' + b.end)

            ForEach(this.dayPlanBlocks(ed), (plan: WeekBlock) => {
              this.planBlock({ plan: plan, day: ed })
            }, (plan: WeekBlock) => 'cp' + plan.id + '-' + plan.start + '-' + plan.end)

            if (ed === this.nowDay() && this.nowShown()) {
              this.nowMarker()
            }
          }
          .width(WEEK_COL_W)
          .height(this.gridH())
          .clip(true)
          .border({ width: { right: 0.5 }, color: DesignTokens.divider })
          .focusable(this.isKnown(ed))
          .accessibilityDescription(this.isKnown(ed) ? '点空白处查看当日明细' : '')
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
    .accessibilityGroup(true)
  }

  /** 泳道图例的色样：比空闲点更方、带描边，和网格里的半列块同一种画法。 */
  @Builder
  busySwatch(fill: ResourceColor, edge: ResourceColor, label: string) {
    Row({ space: 4 }) {
      Column()
        .width(10).height(10)
        .backgroundColor(fill)
        .border({ width: 0.5, color: edge })
        .borderRadius(2)
      Text(label).fontSize(10).fontColor(DesignTokens.textHint)
    }
    .accessibilityGroup(true)
    .accessibilityText(label)
  }

  /** 两种周历共用计划便签；不改变原始时段和占用计算。 */
  @Builder
  planBlock(arg: WeekPlanArg) {
    Stack({ alignContent: Alignment.TopStart }) {
      Column().width(3).height('100%')
        .backgroundColor(arg.plan.conflicted === true ? DesignTokens.dangerDeep : DesignTokens.planAccent)
        .accessibilityLevel('no')
      Column({ space: 2 }) {
        Text(arg.plan.name).fontSize(10).fontWeight(FontWeight.Medium)
          .fontColor(DesignTokens.planInk).width('100%')
          .maxLines(this.blockH(arg.plan.start, arg.plan.end) >= 42 ? 2 : 1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
        if (this.blockH(arg.plan.start, arg.plan.end) >= 42) {
          Text(DateLabel.hm(arg.plan.start)).fontSize(9).fontColor(DesignTokens.planMuted)
        }
      }.width('100%').height('100%').alignItems(HorizontalAlign.Start)
        .padding({ left: 6, right: 2, top: 3, bottom: 2 })
    }.width('96%').height(this.blockH(arg.plan.start, arg.plan.end))
      .position({ x: 1, y: this.blockY(arg.plan.start, arg.day) })
      .backgroundColor(DesignTokens.planSurface).borderRadius(6).clip(true)
      .accessibilityGroup(true).accessibilityText((arg.plan.conflicted === true ? '计划有冲突，' : '已安排计划，')
        + this.scheduleBlockRead(arg.plan, arg.day))
      .clickEffect(DesignTokens.tapButton()).onClick(() => this.onPickDay(arg.day))
  }

  @Builder
  busyLegendLine() {
    Column({ space: 4 }) {
    Row({ space: 10 }) {
      this.busySwatch(DesignTokens.busyMineGlass, DesignTokens.busyMineEdge, '我在忙')
      this.busySwatch(DesignTokens.planSurface, DesignTokens.planAccent, '已安排计划')
      if (this.partnerLanes != null) {
        this.busySwatch(DesignTokens.busyPartnerGlass, DesignTokens.busyPartnerEdge, this.partnerName + '在忙')
      } else {
        Text('还没有' + this.partnerName + '的数据').fontSize(10).fontColor(DesignTokens.textHint)
      }
    }
    .width('100%')
    .justifyContent(FlexAlign.Center)
    if (this.myLanes.some((iv: Interval): boolean => iv.tag === 'UNKNOWN')
      || (this.partnerLanes ?? []).some((iv: Interval): boolean => iv.tag === 'UNKNOWN')) {
      Text('浅灰区域：尚未更新的班表结果，请双方更新应用并同步')
        .fontSize(10).fontColor(DesignTokens.textHint)
    }
    }.width('100%')
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
