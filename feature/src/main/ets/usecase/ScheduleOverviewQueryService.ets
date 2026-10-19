import {
  BlockTag, CycleTemplate, Interval, MIN_PER_DAY, OWNER_ME, ScheduleOverride, ShiftType,
  buildAvailability, expandCycle, shiftToBlocks, termWeekOf, todayEpochDay, weekdayOf, intersects, rosterDayOf,
  ROSTER_LOOKBACK_DAYS, ROSTER_LOOKAHEAD_DAYS
} from 'domain';
import { PlanRow, ScheduleRepo } from 'data';
import { Logger } from 'commons';
import { ScheduleUseCase, SettingsStoreParams } from './ScheduleUseCase';
import { AgendaSource, TodayAgendaItem, buildTodayAgenda } from '../model/TodayAgenda';

const TAG = 'ScheduleOverviewQueryService';

/** 周视图跨度：一周七天，泳道与日程块都按它装配，不多算一天。 */
const WEEK_DAYS = 7;

/** 周日程块配色：班次用班次自带色，其余三类是数据语义色，集中在这里避免页面散落常量。
 *  课程/计划这两条与 ScheduleEditor 的调色板同族，跟着 02 的糖果档一起换；
 *  冲突与恢复两色不在那八色里，保持原值。 */
const COURSE_COLOR = '#4E97DB';
const PLAN_COLOR = '#F0568C';
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

export interface WeekBlock extends AgendaSource {
  color: string;
  conflicted?: boolean;
}

/** 周历双泳道：本周双方各自的"真忙"区间，与日详情的 myTrueBusy / partnerTrueBusy 同一口径。 */
export interface WeekLanes {
  weekStart: number;
  /** Confirmed local projections, separate from merged busy lanes for display only. */
  plans: WeekBlock[];
  /** 我的忙碌（班次 + 课程 + 计划 + 夜班恢复，不含作息与收整）。 */
  mine: Interval[];
  /**
   * TA 的忙碌；没有 TA 的数据时为 null（页面据此决定右半泳道与图例怎么说）。
   * 云端快照按对方隐私等级降维后是有粒度的区间，画出来就是对方允许被看到的那份。
   */
  partner: Interval[] | null;
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
  /** 只读我侧及本机计划，复用现有展开口径，不请求 TA 的云端快照。 */
  static async getTodayAgenda(epochDay: number): Promise<TodayAgendaItem[]> {
    // 从前一天展开，保留昨天开始、今天仍在进行的夜班/课程。
    const schedule = await ScheduleOverviewQueryService.getWeekSchedule(OWNER_ME, epochDay - 1);
    return buildTodayAgenda(schedule.blocks, epochDay);
  }
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
    let partnerLocal = false;
    try {
      partnerLocal = await ScheduleUseCase.hasPartnerContext();
    } catch (e) {
      // 伴侣侧只影响「我 / TA」分段要不要出现，读失败不能把已经读到的四项一起抹成 0（D-22）
      Logger.warn(TAG, 'partner context degraded: ' + (e as Error).message);
    }
    const overview: ScheduleOverview = {
      owner: owner,
      shiftTypes: types.length,
      hasTemplate: tpl != null && tpl.seq.length > 0,
      overrides: ovs.length,
      courses: courses.length,
      horizonDays: horizon,
      partnerLocal: partnerLocal
    };
    return overview;
  }

  /** 装配某一周的班次 + 课程 + 共同计划；无模板时只显示单日覆盖。 */
  static async getWeekSchedule(owner: string, weekStart: number): Promise<WeekSchedule> {
    const params = SettingsStoreParams();
    const courses = await ScheduleRepo.listCourses(owner);
    const termStart = await ScheduleRepo.getTermStart();
    const sectionTimes = ScheduleUseCase.sectionTimesFromJson(await ScheduleRepo.getSectionTimes());
    const plans: PlanRow[] = await ScheduleRepo.listActivePlans();

    const blocks: WeekBlock[] = [];

    const calendarParams = ScheduleUseCase.dayParamsOf(params, WEEK_DAYS+ROSTER_LOOKBACK_DAYS+ROSTER_LOOKAHEAD_DAYS);
    const calendar = await ScheduleUseCase.loadMySchedule(weekStart-ROSTER_LOOKBACK_DAYS, calendarParams, owner);
    for(let date=weekStart-ROSTER_LOOKBACK_DAYS; date<weekStart+WEEK_DAYS+ROSTER_LOOKAHEAD_DAYS; date++) {
      const day = rosterDayOf(calendar,date);
      for(const cfg of day.entries) {
      const shifted: Interval[] = shiftToBlocks({epochDay:date,typeId:cfg.id}, cfg, params);
      for (let j = 0; j < shifted.length; j++) {
        const b: Interval = shifted[j];
        const isRecovery = b.tag === BlockTag.RECOVERY;
        const block: WeekBlock = {
          id: 'shift-' + date + '-' + cfg.id + '-' + j,
          kind: isRecovery ? 'RECOVERY' : (cfg.commuteInMin > 0 || cfg.commuteOutMin > 0 ? 'SHIFT_COMMUTE' : 'SHIFT'),
          start: b.start, end: b.end,
          name: isRecovery ? cfg.name + '·恢复' : cfg.name,
          color: isRecovery ? RECOVERY_COLOR : cfg.color
        };
        blocks.push(block);
      }
      }
    }
    for(const entry of calendar.personalEntries ?? []) {
      blocks.push({id:entry.id,kind:'PERSONAL',start:entry.start,end:entry.end,name:entry.title,color:'#9B82C0'});
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
            id: 'course-' + c.id + '-' + ed, kind: 'COURSE',
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
        id: 'plan-' + p.id, kind: 'PLAN',
        start: p.start, end: p.end, name: p.title,
        color: p.status === 'CONFLICT' ? PLAN_CONFLICT_COLOR : PLAN_COLOR,
        conflicted: p.status === 'CONFLICT'
      };
      blocks.push(block);
    }

    blocks.sort((a: WeekBlock, b: WeekBlock): number => a.start - b.start);
    const data: WeekSchedule = { weekStart: weekStart, blocks: blocks };
    return data;
  }

  /**
   * 装配某一周的双方忙碌泳道（共同页周历用）。
   * 只取"真忙"：作息与收整画进泳道会把整段夜间涂成忙碌色，而夜间本来就不在共同空闲里，
   * 读起来只会重复。口径与日详情半模态的明细行一致（同一处事实只有一种说法，D-23）。
   */
  static async getWeekLanes(weekStart: number): Promise<WeekLanes> {
    const params = ScheduleUseCase.dayParamsOf(SettingsStoreParams(), WEEK_DAYS);
    const my = await ScheduleUseCase.loadMySchedule(weekStart, params);
    const mine = buildAvailability(my, params, weekStart, WEEK_DAYS).trueBusy;
    const partner = await ScheduleUseCase.partnerBusyWithoutNetwork(weekStart, params);
    const start = weekStart * MIN_PER_DAY;
    const end = start + WEEK_DAYS * MIN_PER_DAY;
    const plans: WeekBlock[] = (await ScheduleRepo.listActivePlans())
      .filter((p: PlanRow): boolean => intersects(p.start, p.end, start, end))
      .map((p: PlanRow): WeekBlock => ({ id: p.id, kind: 'PLAN', start: p.start, end: p.end,
        name: p.title, color: p.status === 'CONFLICT' ? PLAN_CONFLICT_COLOR : PLAN_COLOR,
        conflicted: p.status === 'CONFLICT' }));
    const lanes: WeekLanes = {
      weekStart: weekStart,
      plans: plans,
      mine: mine,
      partner: partner != null ? partner.tripBusy : null
    };
    return lanes;
  }
}
