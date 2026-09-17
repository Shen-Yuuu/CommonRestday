import { WindowTag } from 'domain';

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
