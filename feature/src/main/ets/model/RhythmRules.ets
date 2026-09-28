import { clampHorizonDays, hhmmToMin, HORIZON_MAX_DAYS } from 'domain';

/**
 * 视界天数允许区间：下限是本页的用法约定（"只看本周"是 7 天，引擎本身只要求 ≥1 天）；
 * 上限**不在这儿写死**——它由 domain 的 HORIZON_MAX_DAYS 派生，因为引擎按日展开时用的就是
 * 那个数（`clampHorizonDays`）。D-57 之前两边各抄了一份 366，谁改谁记得、另一个人不知道，
 * 于是"校验放行 / 引擎截断"能悄悄分家。
 */
export const HORIZON_MIN: number = 7;
export const HORIZON_MAX: number = HORIZON_MAX_DAYS;

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
    return '时间写成 07:00 这样';
  }
  if (bed === wake) {
    return '起床和就寝填了同一个时间，算不出空闲';
  }
  if (toMinutes(windText) < 0) {
    return '收整缓冲填分钟数，比如 20';
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
    return '往后算的天数要在 ' + HORIZON_MIN + '–' + HORIZON_MAX + ' 之间';
  }
  return '';
}

/**
 * 视界口语读法：参数存的是天数（7–366），读者关心的是"往后能看多远"，所以满一个月
 * 折成月；不足一个月照实念天——允许输入 7 天，折成月就成了"0 个月"。
 * 先过 clampHorizonDays 再念：设置页有校验，但 Preferences 里那份 JSON 可能是备份/换机
 * 从别的版本带回来的，那上面的数字不受本页校验管。念成 500 天而引擎只算到 366 天，
 * 就是一句承诺不起的读数（D-57）。
 */
export function horizonLabel(horizonDays: number): string {
  const days = clampHorizonDays(horizonDays);
  const months = Math.round(days / 30);
  return months < 1 ? '未来 ' + days + ' 天' : '未来 ' + months + ' 个月';
}

/**
 * 夜班判定三档的下拉文字（D-33）。**顺序即 domain 的 nightMode 值**：
 * 0=自动识别、1=强制夜班、2=不触发夜班恢复，所以下标可以原值往返。
 * 原来只给两档，库里值为 2 的班次进编辑页被折成「自动识别」，下一次保存静默改写成 0。
 */
export const NIGHT_MODE_LABELS: string[] = ['自动识别', '强制夜班', '不触发夜班恢复'];

/** 下拉框下标 → 存库值；认不出的下标落回自动档。 */
export function nightModeOf(index: number): number {
  return index >= 0 && index < NIGHT_MODE_LABELS.length ? index : 0;
}

/** 存库值 → 下拉框下标；将来多出来的新值按自动档显示，不会选中越界。 */
export function nightModeIndex(mode: number): number {
  return mode >= 0 && mode < NIGHT_MODE_LABELS.length ? mode : 0;
}

/** 当前档的一句话说明：三档都要有，不能只有中间那档带解释。 */
export function nightModeHint(index: number): string {
  if (index === 1) {
    return '强制夜班：不管几点下班，下班后都算恢复时间';
  }
  if (index === 2) {
    return '不触发夜班恢复：即使撞上夜班窗口，也不生成恢复块';
  }
  return '自动识别：班次和夜班窗口有时间重叠才算夜班';
}

/**
 * 首页问候语按钟点分档（D-39）。原来是一串 hour < N 的顺落判定，0–4 点被 <13 那一支
 * 接住，于是凌晨两点首页念「中午好」——所以最前面必须先挡掉凌晨档。
 * 05:00 起仍是早上好，23:00 起念「夜深了」，两端口径不动。
 */
export function greetingOf(hour: number): string {
  if (hour < 5) {
    return '凌晨好';
  }
  if (hour < 11) {
    return '早上好';
  }
  if (hour < 13) {
    return '中午好';
  }
  if (hour < 18) {
    return '下午好';
  }
  if (hour < 23) {
    return '晚上好';
  }
  return '夜深了';
}

