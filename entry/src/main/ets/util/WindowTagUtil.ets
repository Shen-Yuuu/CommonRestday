import { WindowTag } from 'domain';
import { toDisplayTags } from 'feature';

/** 窗口标签中文短词（CoTimeView / DayDetailSheet 共用）。 */
export function tagLabel(t: string): string {
  if (t === WindowTag.STUDY) {
    return '共同自习';
  }
  if (t === WindowTag.MEAL) {
    return '可聚餐';
  }
  if (t === WindowTag.WEEKEND) {
    return '周末';
  }
  if (t === WindowTag.HALF_DAY) {
    return '半天';
  }
  if (t === WindowTag.FULL_DAY) {
    return '完整同休日';
  }
  if (t === WindowTag.TWO_DAYS) {
    return '连休两天';
  }
  if (t === WindowTag.OVERNIGHT_TRIP) {
    return '过夜旅行';
  }
  if (t === WindowTag.TRIP) {
    return '短途旅行';
  }
  return t;
}

/** 标签 chip 颜色（资源引用，深浅色自适应）。 */
export function tagColor(t: string): ResourceColor {
  if (t === WindowTag.STUDY) {
    return $r('app.color.info_blue');
  }
  if (t === WindowTag.MEAL) {
    return $r('app.color.warn_orange');
  }
  if (t === WindowTag.WEEKEND) {
    return $r('app.color.tag_weekend');
  }
  if (t === WindowTag.FULL_DAY || t === WindowTag.TWO_DAYS) {
    return $r('app.color.brand_pink');
  }
  if (t === WindowTag.HALF_DAY) {
    return $r('app.color.success_green');
  }
  if (t === WindowTag.OVERNIGHT_TRIP || t === WindowTag.TRIP) {
    return $r('app.color.tag_trip');
  }
  return $r('app.color.tag_fallback');
}

/**
 * 卡片展示标签文案（精简版三档：完整同休日 / 周末 / 可出行）。
 * 与 tagLabel 的差别只在出行档：卡片上不区分过夜与短途，与筛选档「可出行」同一口径。
 * 颜色沿用 tagColor，两者对同一 key 给同一色。
 */
export function displayTagLabel(t: string): string {
  if (t === WindowTag.TRIP || t === WindowTag.OVERNIGHT_TRIP) {
    return '可出行';
  }
  return tagLabel(t);
}

/**
 * 领域标签 → 一行展示串（窗口详情半模态与读屏共用）。
 * 收敛用 feature 的 toDisplayTags，与卡片、筛选档同一份口径：卡片上标了「可出行」的窗口，
 * 点进 sheet 也只能看到「可出行」，不会多出一串原始枚举。
 */
export function displayTagLine(tags: string[]): string {
  const out: string[] = [];
  const keys = toDisplayTags(tags);
  for (let i = 0; i < keys.length; i++) {
    out.push(displayTagLabel(keys[i]));
  }
  return out.join('|');
}

/** 忙碌区间标签（AvailabilityBuilder/快照的 BlockTag）中文短词。 */
export function busyTagLabel(tag: string): string {
  if (tag === 'WORK') {
    return '班次';
  }
  if (tag === 'RECOVERY') {
    return '夜班恢复';
  }
  if (tag === 'COURSE') {
    return '课程';
  }
  if (tag === 'PLAN') {
    return '已有计划';
  }
  if (tag === 'BUSY') {
    return '忙碌';
  }
  return tag === '' ? '忙碌' : tag;
}
