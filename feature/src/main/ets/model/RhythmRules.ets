import { hhmmToMin } from 'domain';

/** 视界天数允许区间：与引擎按日展开的成本匹配，也覆盖"只看本周"的用法。 */
export const HORIZON_MIN: number = 7;
export const HORIZON_MAX: number = 366;

/** 把 "60" / "20" 这类分钟数文本解析成数字；非数字返回 -1。 */
export function toMinutes(text: string): number {
  const v = Number.parseInt(text, 10);
  return Number.isNaN(v) ? -1 : v;
}

/**
 * 作息输入校验（自己与伴侣共用一条口径），返回空串表示合法。
 * 就寝早于起床是合法输入：那是次日凌晨就寝（轮班/夜班），跨零点由领域层 AvailabilityBuilder 解释。
 * UI 若按数值大小判先后，轮班用户根本无法配置作息——这正是"就寝 00:30"必须能保存的原因。
 */
export function rhythmError(wakeText: string, bedText: string, windText: string): string {
  const wake = hhmmToMin(wakeText);
  const bed = hhmmToMin(bedText);
  if (wake < 0 || bed < 0) {
    return '时间格式应为 HH:MM（如 07:00）';
  }
  if (bed === wake) {
    return '起床与就寝是同一时刻，这样算不出一天的清醒区间';
  }
  if (toMinutes(windText) < 0) {
    return '收整缓冲请填分钟数（如 20）';
  }
  return '';
}

/** 就寝是否已过零点（页面据此补一句说明，否则"就寝 01:00"看着像漏填）。 */
export function isCrossMidnight(wakeText: string, bedText: string): boolean {
  const wake = hhmmToMin(wakeText);
  const bed = hhmmToMin(bedText);
  return wake >= 0 && bed >= 0 && bed < wake;
}

/** 视界天数校验，返回空串表示合法。 */
export function horizonError(horizonText: string): string {
  const v = toMinutes(horizonText);
  if (v < HORIZON_MIN || v > HORIZON_MAX) {
    return '视界天数需在 ' + HORIZON_MIN + '–' + HORIZON_MAX + ' 天之间';
  }
  return '';
}
