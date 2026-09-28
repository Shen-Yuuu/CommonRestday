import { MIN_PER_DAY } from '../model/Types';

/**
 * 纯时间工具：本地时区语义的 epochDay / epochMin 换算。
 * 仅用于测试与领域层边界换算，运行时 UI 层同样可直接使用。
 */

/**
 * 由年月日（本地）求 epochDay。
 * 必须用 Math.round：本地零点对应的 UTC 时刻可能落在前一天（如 UTC+8 为前一天 16:00），
 * floor 会整体偏移一天；round 在 |时区偏移| < 12h 时恒等于"本地日历日的真纪元日序号"。
 */
export function epochDayOf(year: number, month1: number, day: number): number {
  const ms = new Date(year, month1 - 1, day, 0, 0, 0, 0).getTime();
  return Math.round(ms / (MIN_PER_DAY * 60 * 1000));
}

/** 今天（本地）的 epochDay。 */
export function todayEpochDay(now: number = Date.now()): number {
  const d = new Date(now);
  return epochDayOf(d.getFullYear(), d.getMonth() + 1, d.getDate());
}

/**
 * 由**一个**时刻读出「自 epoch 起的本地分钟」（epochMin）。
 * 日和时分必须同源：分两次读表时，跨午夜那一瞬两次读数会各说各话，
 * 拼出偏整整一天的 epochMin，页面据此挑错「今天」。
 */
export function epochMinOf(now: Date): number {
  return epochDayOf(now.getFullYear(), now.getMonth() + 1, now.getDate()) * MIN_PER_DAY
    + now.getHours() * 60 + now.getMinutes();
}

/** 当下的 epochMin；只在这里读一次表，测试可注入时刻。 */
export function nowEpochMin(now: number = Date.now()): number {
  return epochMinOf(new Date(now));
}

/** epochDay 是否为周六或周日（周一=1 … 周日=7）。 */
export function isWeekend(epochDay: number): boolean {
  const wd = weekdayOf(epochDay);
  return wd === 6 || wd === 7;
}

/** 星期几：1=周一 … 7=周日（1970-01-01 为周四=4）。 */
export function weekdayOf(epochDay: number): number {
  return ((epochDay % 7) + 7 + 3) % 7 + 1;
}

/** 学期第几周（第 1 周起）；在学期前返回 0 或负数。 */
export function termWeekOf(termStartEpochDay: number, epochDay: number): number {
  return Math.floor((epochDay - termStartEpochDay) / 7) + 1;
}

/**
 * 区间的**起点**落在哪个自然日。
 *
 * 半开区间 `[start, end)` 的头一天就是起点那一天，所以这里不需要任何端点判断。
 * 反过来，终点不能这么读——见 {@link dayOfEnd}。
 */
export function dayOfStart(epochMin: number): number {
  return Math.floor(epochMin / MIN_PER_DAY);
}

/**
 * 区间的**终点**落在哪个自然日：整零点归前一天（`[…, 24:00)` 说的是这一天的尾巴，
 * 不是次日的一天），其余按当日读。
 *
 * 这一条与 D-58 的 `DateLabel.edgeTime`（午夜终点念 "24:00"）是同一条口径的两半：
 * 一半决定屏幕上写哪天，一半决定算到哪天。分家过一次——日详情同一个 `w.end`
 * 在窗口行念 24:00、在忙碌行念 00:00（批次 AH）。`commons` 那份不能 import 这里
 * （依赖图的底，见 `DateLabel.ets` 的 `DAY_MIN` 注释），所以两份由 `DateLabelTest`
 * 的 `edge_day_and_time_agree_with_the_domain_edge_rule` 钉住同值。
 */
export function dayOfEnd(epochMin: number): number {
  return Math.floor((epochMin - 1) / MIN_PER_DAY);
}

/** 半开区间 `[start, end)` 触及的自然日数；空区间（`end <= start`）给 0。 */
export function daySpan(startEpochMin: number, endEpochMin: number): number {
  if (endEpochMin <= startEpochMin) {
    return 0;
  }
  return dayOfEnd(endEpochMin) - dayOfStart(startEpochMin) + 1;
}

/**
 * 就寝早于起床 = 次日凌晨就寝（轮班/夜班的合法输入，见 `RhythmRules.rhythmError`）。
 * 判据只认数值先后，"填了同一个时间"那一类是校验层的事。
 */
export function bedCrossesMidnight(wakeMin: number, bedMin: number): boolean {
  return bedMin < wakeMin;
}

/**
 * 就寝端在"当日 00:00 起算的分钟轴"上的位置：跨零点时延到次日，所以可以 ≥ 1440。
 * 睡眠段与"当日可安排核心 `[wake, bed)`"都用它，两边必须同一份判定——
 * 一份延、一份不延，就会出现"引擎认为这段时间在睡觉、分类器认为它还能安排"。
 */
export function bedEndMin(wakeMin: number, bedMin: number): number {
  return bedCrossesMidnight(wakeMin, bedMin) ? bedMin + MIN_PER_DAY : bedMin;
}

/** 分钟数 → "HH:MM"。 */
export function minToHHmm(min: number): string {
  const m = ((min % MIN_PER_DAY) + MIN_PER_DAY) % MIN_PER_DAY;
  const h = Math.floor(m / 60);
  const mm = m % 60;
  const hs = h < 10 ? '0' + h : '' + h;
  const mms = mm < 10 ? '0' + mm : '' + mm;
  return hs + ':' + mms;
}

/** "HH:MM" → 分钟数。 */
export function hhmmToMin(text: string): number {
  const parts = text.split(':');
  if (parts.length !== 2) {
    return -1;
  }
  const h = Number.parseInt(parts[0], 10);
  const m = Number.parseInt(parts[1], 10);
  if (Number.isNaN(h) || Number.isNaN(m) || h < 0 || h > 47 || m < 0 || m > 59) {
    return -1;
  }
  return h * 60 + m;
}
