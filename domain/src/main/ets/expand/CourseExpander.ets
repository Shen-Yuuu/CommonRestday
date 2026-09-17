import { Course, Interval, MIN_PER_DAY, SectionTime } from '../model/Types';
import { epochDayToMs, termWeekOf, weekdayOf } from '../utils/TimeUtil';
import { mkIv } from '../merge/IntervalOps';

/**
 * 课程展开：按 weekday + 周次范围 + 单双周 + 节次模板 生成课程忙碌块。
 * 节次超出现有作息模板时该节忽略（UI 层负责提示补齐模板）。
 */
export function expandCourses(courses: Course[], sectionTimes: SectionTime[],
  termStartEpochDay: number, startEpochDay: number, days: number): Interval[] {
  const res: Interval[] = [];
  if (termStartEpochDay < 0 || courses.length === 0 || sectionTimes.length === 0) {
    return res;
  }
  for (let i = 0; i < days; i++) {
    const d = startEpochDay + i;
    const week = termWeekOf(termStartEpochDay, d);
    if (week < 1) {
      continue;
    }
    const wd = weekdayOf(d);
    for (let c = 0; c < courses.length; c++) {
      const course = courses[c];
      if (course.weekday !== wd) {
        continue;
      }
      if (week < course.weekFrom || week > course.weekTo) {
        continue;
      }
      if (course.parity === 1 && week % 2 === 0) {
        continue;
      }
      if (course.parity === 2 && week % 2 === 1) {
        continue;
      }
      const iv = courseInterval(course, sectionTimes, d);
      if (iv != null) {
        res.push(iv);
      }
    }
  }
  return res;
}

function courseInterval(course: Course, sectionTimes: SectionTime[], epochDay: number): Interval | null {
  const first = sectionTimes[course.sectionStart - 1];
  const last = sectionTimes[course.sectionEnd - 1];
  if (first == null || last == null) {
    return null;
  }
  const base = epochDay * MIN_PER_DAY;
  return mkIv(base + first.startMin, base + last.endMin, 'COURSE');
}

/** 课程占用（分钟）→ 显示用（供确认页预览等）。 */
export function courseIntervalToMs(iv: Interval): number {
  return epochDayToMs(Math.floor(iv.start / MIN_PER_DAY)) + (iv.start % MIN_PER_DAY) * 60 * 1000;
}
