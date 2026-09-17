import {
  CommonFreeResult, EngineInput, EngineParams, Interval, MIN_PER_DAY,
  MySchedule, ScheduleOverride, ShiftInstance, ShiftType
} from '../model/Types';
import { expandCycle } from '../expand/CycleExpander';
import { expandCourses } from '../expand/CourseExpander';
import { buildNotAvailable, shiftToBlocks } from '../buffer/AvailabilityBuilder';
import { complement, mkIv, unionIntervals } from '../merge/IntervalOps';
import { classifyWindows } from '../classify/WindowClassifier';

/**
 * 共同空闲计算引擎门面：展开 → 缓冲 → 合并取补 → 分类 → 筛选。
 * 纯同步纯函数，120 天 × 2 人毫秒级，UI/卡片可在任意线程直接调用。
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

    const allBusy = unionIntervals(my.notAvailable, partnerBusy);
    const free = complement(allBusy, from, to);
    const cls = classifyWindows(free, my.trueBusy, partnerBusy, p, input.my.wakeMin, input.my.bedMin, start, days);

    const r: CommonFreeResult = {
      windows: cls.windows,
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
