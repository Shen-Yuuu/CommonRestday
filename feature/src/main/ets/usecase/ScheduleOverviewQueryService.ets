import {
  BlockTag, CycleTemplate, Interval, MIN_PER_DAY, ScheduleOverride, ShiftInstance, ShiftType,
  expandCycle, shiftToBlocks, termWeekOf, todayEpochDay, weekdayOf
} from 'domain';
import { PlanRow, ScheduleRepo } from 'data';
import { ScheduleUseCase, SettingsStoreParams } from './ScheduleUseCase';

/** 周日程块配色：班次用班次自带色，其余三类是数据语义色，集中在这里避免页面散落常量。 */
const COURSE_COLOR = '#3AA6E8';
const PLAN_COLOR = '#4E9A63';
const PLAN_CONFLICT_COLOR = '#D9534F';
const RECOVERY_COLOR = '#A08CD8';

/** 录入概况（「我的日程」摘要卡 + 文案里的真实视界）。 */
export interface ScheduleOverview {
  owner: string;
  shiftTypes: number;
  hasTemplate: boolean;
  /** 视界内单日覆盖条数（临时调整）。 */
  overrides: number;
  courses: number;
  /** 用户实际保存的视界天数：文案与统计区间都用它，不再取默认常量。 */
  horizonDays: number;
  /** 这台手机是否替 TA 代录过（有伴侣档案或 TA 的班表数据）。 */
  partnerLocal: boolean;
}

/** 某一周的日程块（绝对 epochMin 区间，跨天块由渲染侧按日裁剪）。 */
export interface WeekSchedule {
  weekStart: number;
  blocks: WeekBlock[];
}

export interface WeekBlock {
  start: number;
  end: number;
  name: string;
  color: string;
}

/** 单日改班选择器的输入：模板推算值、既有覆盖与可选班次一次读齐。 */
export interface DayShiftState {
  types: ShiftType[];
  hasTemplate: boolean;
  /** 循环模板推算的当日班次 id；'' = 休。 */
  baseTypeId: string;
  /** 手动覆盖是否存在：shiftTypeId=null 表示"这天强制休息"，所以覆盖值判不出有无，需单独给一位。 */
  hasOverride: boolean;
  /** 既有覆盖的班次 id；'' = 强制休息。 */
  overrideTypeId: string;
}

/**
 * 日程录入侧的稳定读模型：概况统计与周视图块都在此装配，
 * 页面（ScheduleHub / WeekScheduleView / DayShiftSheet）不再直连 ScheduleRepo。
 */
export class ScheduleOverviewQueryService {
  /** 单日改班（临时调整）选择器状态。 */
  static async getDayShiftState(owner: string, epochDay: number): Promise<DayShiftState> {
    const types = await ScheduleRepo.listShiftTypes(owner);
    const tpl: CycleTemplate | null = await ScheduleRepo.getTemplate(owner);
    const ovs: ScheduleOverride[] = await ScheduleRepo.listOverrides(epochDay, epochDay, owner);
    let base = '';
    if (tpl != null) {
      // 传空覆盖列表取"模板原始值"，才能把手动覆盖和它区分开
      const ex = expandCycle(tpl, [], epochDay, 1);
      base = ex.length > 0 ? ex[0].typeId : '';
    }
    const state: DayShiftState = {
      types: types,
      hasTemplate: tpl != null,
      baseTypeId: base,
      hasOverride: ovs.length > 0,
      overrideTypeId: ovs.length > 0 && ovs[0].shiftTypeId != null ? ovs[0].shiftTypeId as string : ''
    };
    return state;
  }

  /** owner 侧录入概况；一次读齐四项 + 真实视界 + 代录可见性。 */
  static async getOverview(owner: string): Promise<ScheduleOverview> {
    const today = todayEpochDay();
    const horizon = SettingsStoreParams().horizonDays;
    const types = await ScheduleRepo.listShiftTypes(owner);
    const tpl = await ScheduleRepo.getTemplate(owner);
    const ovs = await ScheduleRepo.listOverrides(today, today + horizon - 1, owner);
    const courses = await ScheduleRepo.listCourses(owner);
    const overview: ScheduleOverview = {
      owner: owner,
      shiftTypes: types.length,
      hasTemplate: tpl != null && tpl.seq.length > 0,
      overrides: ovs.length,
      courses: courses.length,
      horizonDays: horizon,
      partnerLocal: await ScheduleUseCase.hasPartnerContext()
    };
    return overview;
  }

  /** 装配某一周的班次 + 课程 + 共同计划；无模板时只显示单日覆盖。 */
  static async getWeekSchedule(owner: string, weekStart: number): Promise<WeekSchedule> {
    const params = SettingsStoreParams();
    const types = await ScheduleRepo.listShiftTypes(owner);
    const tpl: CycleTemplate | null = await ScheduleRepo.getTemplate(owner);
    const ovs: ScheduleOverride[] = await ScheduleRepo.listOverrides(weekStart, weekStart + 6, owner);
    const courses = await ScheduleRepo.listCourses(owner);
    const termStart = await ScheduleRepo.getTermStart();
    const sectionTimes = ScheduleUseCase.sectionTimesFromJson(await ScheduleRepo.getSectionTimes());
    const plans: PlanRow[] = await ScheduleRepo.listActivePlans();

    const typeMap = new Map<string, ShiftType>();
    for (let i = 0; i < types.length; i++) {
      typeMap.set(types[i].id, types[i]);
    }
    const blocks: WeekBlock[] = [];

    // ① 班次：循环模板（+单日覆盖）；无模板时仅显示覆盖班次日
    const insts: ShiftInstance[] = [];
    if (tpl != null) {
      const ex = expandCycle(tpl, ovs, weekStart, 7);
      for (let i = 0; i < ex.length; i++) {
        insts.push(ex[i]);
      }
    } else {
      for (let i = 0; i < ovs.length; i++) {
        const ov = ovs[i];
        if (ov.shiftTypeId != null && ov.epochDay >= weekStart && ov.epochDay < weekStart + 7) {
          const inst: ShiftInstance = { epochDay: ov.epochDay, typeId: ov.shiftTypeId as string };
          insts.push(inst);
        }
      }
    }
    for (let i = 0; i < insts.length; i++) {
      const cfg = typeMap.get(insts[i].typeId);
      if (cfg == null) {
        continue;
      }
      const shifted: Interval[] = shiftToBlocks(insts[i], cfg, params);
      for (let j = 0; j < shifted.length; j++) {
        const b: Interval = shifted[j];
        const isRecovery = b.tag === BlockTag.RECOVERY;
        const block: WeekBlock = {
          start: b.start, end: b.end,
          name: isRecovery ? cfg.name + '·恢复' : cfg.name,
          color: isRecovery ? RECOVERY_COLOR : cfg.color
        };
        blocks.push(block);
      }
    }

    // ② 课程：学期周次 + 单双周 + 节次模板
    if (termStart > 0) {
      for (let d = 0; d < 7; d++) {
        const ed = weekStart + d;
        const week = termWeekOf(termStart, ed);
        if (week < 1) {
          continue;
        }
        const wd = weekdayOf(ed);
        for (let i = 0; i < courses.length; i++) {
          const c = courses[i];
          if (c.weekday !== wd || week < c.weekFrom || week > c.weekTo) {
            continue;
          }
          if (c.parity === 1 && week % 2 === 0) {
            continue;
          }
          if (c.parity === 2 && week % 2 === 1) {
            continue;
          }
          const first = sectionTimes[c.sectionStart - 1];
          const last = sectionTimes[c.sectionEnd - 1];
          if (first == null || last == null) {
            continue;
          }
          const base = ed * MIN_PER_DAY;
          const block: WeekBlock = {
            start: base + first.startMin, end: base + last.endMin, name: c.name, color: COURSE_COLOR
          };
          blocks.push(block);
        }
      }
    }

    // ③ 共同计划（双方共享，双侧周视图都显示；冲突计划标红）
    for (let i = 0; i < plans.length; i++) {
      const p = plans[i];
      const block: WeekBlock = {
        start: p.start, end: p.end, name: p.title,
        color: p.status === 'CONFLICT' ? PLAN_CONFLICT_COLOR : PLAN_COLOR
      };
      blocks.push(block);
    }

    blocks.sort((a: WeekBlock, b: WeekBlock): number => a.start - b.start);
    const data: WeekSchedule = { weekStart: weekStart, blocks: blocks };
    return data;
  }
}
