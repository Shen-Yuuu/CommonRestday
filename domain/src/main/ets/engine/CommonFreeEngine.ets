import {
  CommonFreeResult, EngineInput, EngineParams, Interval, MIN_PER_DAY,
  MySchedule, ScheduleOverride, ShiftInstance, ShiftType, Window, WindowTag
} from '../model/Types';
import { expandCycle } from '../expand/CycleExpander';
import { expandCourses } from '../expand/CourseExpander';
import { buildNotAvailable, shiftToBlocks } from '../buffer/AvailabilityBuilder';
import { complement, mergeIntervals, mkIv, unionIntervals } from '../merge/IntervalOps';
import { classifyWindows } from '../classify/WindowClassifier';

/**
 * 共同空闲计算引擎门面：展开 → 缓冲 → 合并取补 → 分类 → 筛选。
 * 纯同步纯函数，120 天 × 2 人毫秒级，UI/卡片可在任意线程直接调用。
 *
 * 两类窗口（v1.2 语义修正）：
 * - 常规窗口：睡眠参与忙集（不可在睡眠时段安排活动），产出 MEAL/HALF_DAY/FULL_DAY/STUDY 等标签；
 * - 旅行窗口：真忙+收整参与忙集、睡眠可被跨越（出行的夜晚发生在目的地），
 *   产出 OVERNIGHT_TRIP（≥16h 跨零点）/ TRIP（≥32h）标签，满足 PRD"连续 24h+ 空档短途旅行"。
 */
export class CommonFreeEngine {
  /** 计算共同空闲窗口。 */
  static compute(input: EngineInput): CommonFreeResult {
    const t0 = Date.now();
    const p = input.params;
    const start = input.horizonStartEpochDay;
    const days = Math.max(1, Math.min(p.horizonDays, 366));
    const from = start * MIN_PER_DAY;
    const to = (start + days) * MIN_PER_DAY;

    const my = buildAvailability(input.my, p, start, days);
    const partnerBusy: Interval[] = [];
    if (input.partner != null) {
      const pb = input.partner.busyIntervals;
      for (let i = 0; i < pb.length; i++) {
        partnerBusy.push(pb[i]);
      }
    }
    // 对方"不含睡眠"的不可用（忙+收整）：完整同休日与旅行判定专用。
    // 缺省时从 busyIntervals 剥离 SLEEP 段；L1 快照标签不可分（全为 BUSY），
    // 剥离结果仍含对方睡眠 → 同休日/旅行判定自然保守，不会误标。
    let peerBusyNoSleep: Interval[];
    if (input.partner == null) {
      peerBusyNoSleep = [];
    } else if (input.partner.tripBusyIntervals != null) {
      peerBusyNoSleep = input.partner.tripBusyIntervals;
    } else {
      peerBusyNoSleep = partnerBusy.filter((iv: Interval) => iv.tag !== 'SLEEP');
    }

    const allBusy = unionIntervals(my.notAvailable, partnerBusy);
    const free = complement(allBusy, from, to);
    const cls = classifyWindows(free, my.trueBusy, peerBusyNoSleep, p,
      input.my.wakeMin, input.my.bedMin, start, days);

    // 旅行窗口：真忙+收整参与忙集（睡眠可跨越），只保留带旅行标签的跨时段窗口
    const windows: Window[] = cls.windows.slice();
    const myTripBusy = mergeIntervals(my.trueBusy.map((iv: Interval): Interval => {
      return mkIv(iv.start, iv.end + input.my.windDownMin, iv.tag);
    }));
    const tripFree = complement(unionIntervals(myTripBusy, peerBusyNoSleep), from, to);
    const tripCls = classifyWindows(tripFree, my.trueBusy, peerBusyNoSleep, p,
      input.my.wakeMin, input.my.bedMin, start, days);
    for (let i = 0; i < tripCls.windows.length; i++) {
      const w = tripCls.windows[i];
      if (w.tags.indexOf(WindowTag.TRIP) >= 0 || w.tags.indexOf(WindowTag.OVERNIGHT_TRIP) >= 0) {
        windows.push(w);
      }
    }
    windows.sort((a: Window, b: Window) => a.start - b.start);

    const r: CommonFreeResult = {
      windows: windows,
      fullDays: cls.fullDays,
      computeMs: Date.now() - t0
    };
    return r;
  }
}

/** 我方可用性构建结果（引擎与快照构建共用）。 */
export interface MyAvailability {
  /** 真忙（工作/恢复/课程/计划，不含收整与睡眠）。 */
  trueBusy: Interval[];
  /** 不可用（真忙+收整缓冲+作息窗口外），已合并。 */
  notAvailable: Interval[];
}

/**
 * 构建任意一方（"我"或本机代录的伴侣）的可用性：
 * 1. 展开循环模板（+单日覆盖）或仅覆盖；
 * 2. 班次 → 忙碌块（含通勤、夜班恢复）；
 * 3. 课程展开；
 * 4. 已确认计划；
 * 5. 作息窗口外与收整缓冲。
 * 传入该方的班表数据与该方 EngineParams（MySchedule 内含该方 wake/bed/windDown）即可，
 * 伴侣复用与"我"完全相同的 expand → buffer 管线。
 */
export function buildAvailability(schedule: MySchedule, p: EngineParams,
  startEpochDay: number, days: number): MyAvailability {
  const typeMap = new Map<string, ShiftType>();
  for (let i = 0; i < schedule.shiftTypes.length; i++) {
    typeMap.set(schedule.shiftTypes[i].id, schedule.shiftTypes[i]);
  }
  const insts: ShiftInstance[] = [];
  if (schedule.template != null) {
    const expanded = expandCycle(schedule.template, schedule.overrides, startEpochDay, days);
    for (let i = 0; i < expanded.length; i++) {
      insts.push(expanded[i]);
    }
  } else {
    const ovs: ScheduleOverride[] = schedule.overrides;
    for (let i = 0; i < ovs.length; i++) {
      if (ovs[i].shiftTypeId != null && ovs[i].epochDay >= startEpochDay && ovs[i].epochDay < startEpochDay + days) {
        const inst: ShiftInstance = { epochDay: ovs[i].epochDay, typeId: ovs[i].shiftTypeId as string };
        insts.push(inst);
      }
    }
  }

  const trueBusy: Interval[] = [];
  for (let i = 0; i < insts.length; i++) {
    const cfg = typeMap.get(insts[i].typeId);
    if (cfg == null) {
      continue;
    }
    const blocks = shiftToBlocks(insts[i], cfg, p);
    for (let j = 0; j < blocks.length; j++) {
      trueBusy.push(blocks[j]);
    }
  }
  const courseIvs = expandCourses(schedule.courses, schedule.sectionTimes, schedule.termStartEpochDay, startEpochDay, days);
  for (let i = 0; i < courseIvs.length; i++) {
    trueBusy.push(courseIvs[i]);
  }
  for (let i = 0; i < schedule.plans.length; i++) {
    if (schedule.plans[i].end > schedule.plans[i].start) {
      trueBusy.push(mkIv(schedule.plans[i].start, schedule.plans[i].end, 'PLAN'));
    }
  }

  const notAvail = buildNotAvailable(trueBusy, schedule.wakeMin, schedule.bedMin, schedule.windDownMin, startEpochDay, days);
  const out: MyAvailability = { trueBusy: trueBusy, notAvailable: notAvail };
  return out;
}

/** 兼容别名：构建"我"的可用性（快照构建等既有调用方沿用旧名）。 */
export function buildMyAvailability(my: MySchedule, p: EngineParams,
  startEpochDay: number, days: number): MyAvailability {
  return buildAvailability(my, p, startEpochDay, days);
}
