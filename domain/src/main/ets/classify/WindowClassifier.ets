import { EngineParams, Interval, MIN_PER_DAY, Window, WindowTag } from '../model/Types';
import { isWeekend } from '../utils/TimeUtil';
import { mkIv, overlapMin, totalOverlap } from '../merge/IntervalOps';

/** 分类结果。 */
export interface ClassifyResult {
  windows: Window[];
  fullDays: number[];
}

/** 午餐/晚餐时段（距 00:00 分钟）。 */
const LUNCH_START = 690;   // 11:30
const LUNCH_END = 780;     // 13:00
const DINNER_START = 1080; // 18:00
const DINNER_END = 1170;   // 19:30

/**
 * 窗口分类打标（PRD F4 判定表）：
 * - MEAL：覆盖午/晚餐时段
 * - HALF_DAY：≥ halfDayMin
 * - FULL_DAY：存在"完整同休日" d（双方当日无任何不可用占用，且当日共同可安排 ≥ fullDayAvailMin），
 *   且窗口完整覆盖当日可安排核心 [d+wake, d+bed)
 * - TWO_DAYS：覆盖两个相邻的完整同休日
 * - WEEKEND：覆盖周六或周日
 * - OVERNIGHT_TRIP：≥ overnightMinMin 且跨零点
 * - TRIP：≥ tripMinMin 或 TWO_DAYS
 * - STUDY：≥ studyMinMin 且窗口起止同一天、该天为周一至周五、整体落在
 *   [studyStartMin, studyEndMin] 白天时段内（跨多日的长窗口不标）
 *
 * @param trueBusyMine 我方真忙（工作/恢复/课程/计划，不含睡眠与收整）
 * @param peerBusyNoSleep 对方"不含睡眠"的不可用区间（忙碌块+收整；L1 快照会含对方睡眠，
 *                        当日占用恒 >0 → 同休日判定自然保守，不会误标）
 */
export function classifyWindows(free: Interval[], trueBusyMine: Interval[], peerBusyNoSleep: Interval[],
  params: EngineParams, wakeMin: number, bedMin: number,
  startEpochDay: number, days: number): ClassifyResult {

  const fullDays: number[] = [];
  for (let i = 0; i < days; i++) {
    const d = startEpochDay + i;
    const dayStart = d * MIN_PER_DAY;
    const dayEnd = dayStart + MIN_PER_DAY;
    const myBusy = totalOverlap(trueBusyMine, dayStart, dayEnd);
    const peerBusy = totalOverlap(peerBusyNoSleep, dayStart, dayEnd);
    const freeMin = totalOverlap(free, dayStart, dayEnd);
    if (myBusy === 0 && peerBusy === 0 && freeMin >= params.fullDayAvailMin) {
      fullDays.push(d);
    }
  }
  const fullSet = new Set<number>();
  for (let i = 0; i < fullDays.length; i++) {
    fullSet.add(fullDays[i]);
  }

  const bed = bedMin < wakeMin ? bedMin + MIN_PER_DAY : bedMin;
  const windows: Window[] = [];
  for (let i = 0; i < free.length; i++) {
    const w = free[i];
    const dur = w.end - w.start;
    if (dur < params.minSlotMin) {
      continue;
    }
    const tags: string[] = [];
    const firstDay = Math.floor(w.start / MIN_PER_DAY);
    const lastDay = Math.floor((w.end - 1) / MIN_PER_DAY);

    if (dur >= params.halfDayMin) {
      tags.push(WindowTag.HALF_DAY);
    }

    let meal = false;
    let weekend = false;
    let lastCoveredDay = -2;
    let adjacentCovered = false;
    let fullCoverCount = 0;
    for (let d = firstDay; d <= lastDay; d++) {
      const dayStart = d * MIN_PER_DAY;
      if (overlapMin(w.start, w.end, dayStart + LUNCH_START, dayStart + LUNCH_END) > 0
        || overlapMin(w.start, w.end, dayStart + DINNER_START, dayStart + DINNER_END) > 0) {
        meal = true;
      }
      if (isWeekend(d)) {
        weekend = true;
      }
      // 完整覆盖当日可安排核心 [wake, bed)（bed 跨零点时核心延伸至次日）
      const coreS = dayStart + wakeMin;
      const coreE = dayStart + bed;
      if (w.start <= coreS && w.end >= coreE && fullSet.has(d)) {
        if (lastCoveredDay === d - 1) {
          adjacentCovered = true;
        }
        lastCoveredDay = d;
        fullCoverCount++;
      }
    }

    if (meal) {
      tags.push(WindowTag.MEAL);
    }
    if (weekend) {
      tags.push(WindowTag.WEEKEND);
    }
    if (fullCoverCount > 0) {
      tags.push(WindowTag.FULL_DAY);
    }
    if (adjacentCovered) {
      tags.push(WindowTag.TWO_DAYS);
    }
    if (dur >= params.overnightMinMin && lastDay > firstDay) {
      tags.push(WindowTag.OVERNIGHT_TRIP);
    }
    if (dur >= params.tripMinMin || adjacentCovered) {
      tags.push(WindowTag.TRIP);
    }
    // STUDY：工作日白天 ≥studyMinMin；判定收窄为"起止同一天 + 工作日 + 整体落在白天时段内"
    if (dur >= params.studyMinMin && firstDay === lastDay && !isWeekend(firstDay)) {
      const studyDayStart = firstDay * MIN_PER_DAY;
      if (w.start >= studyDayStart + params.studyStartMin && w.end <= studyDayStart + params.studyEndMin) {
        tags.push(WindowTag.STUDY);
      }
    }

    const win: Window = { start: w.start, end: w.end, durationMin: dur, tags: tags };
    windows.push(win);
  }

  const r: ClassifyResult = { windows: windows, fullDays: fullDays };
  return r;
}

/** 供测试/UI：构造某天的餐点区间。 */
export function mealInterval(epochDay: number, dinner: boolean): Interval {
  const base = epochDay * MIN_PER_DAY;
  return dinner ? mkIv(base + DINNER_START, base + DINNER_END, 'MEAL')
    : mkIv(base + LUNCH_START, base + LUNCH_END, 'MEAL');
}

/** 判断标签集合是否包含某标签。 */
export function hasTagOf(tags: string[], tag: string): boolean {
  return tags.indexOf(tag) >= 0;
}
