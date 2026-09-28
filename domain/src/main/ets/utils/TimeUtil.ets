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
