import {
  CONFLICT_REASON_MIXED, CONFLICT_REASON_MY_COURSE, CONFLICT_REASON_MY_RHYTHM,
  CONFLICT_REASON_MY_SHIFT, CONFLICT_REASON_PARTNER_CHANGED, CONFLICT_REASON_PARTNER_TIME,
  CONFLICT_SOURCE_BOTH, CONFLICT_SOURCE_MINE, CONFLICT_SOURCE_PARTNER,
  Interval, MIN_PER_DAY, Window, WindowChannel, WindowTag, decodeConflictHint, hasTagOf, overlapMin,
  todayEpochDay
} from 'domain';
import { PAIRED as PAIR_PAIRED, PlanRow, ScheduleRepo, SettingsStore } from 'data';
import { DateLabel } from 'commons';
import { normalizeCalendarState } from '../model/PlanFlow';
import { DayViewData, ScheduleUseCase, SettingsStoreParams } from './ScheduleUseCase';
import {
  AnswerAction, AnswerKind, AnswerState, CommonTimePageData, ExperienceMode, HomeSummary,
  PlanConflictView, PlanSummary, QuickAnswer, TodaySummary, WindowDetailData, WindowFilter,
  WindowFilterKey, WindowSummary
} from '../model/PresentationModels';

/**
 * 答案优先查询服务：UI 只消费本文件产出的页面读模型，不自行拼装业务结论。
 *
 * 装配逻辑（assembleXxx / pickXxx）是纯函数，只吃已加载好的数据，便于离线单测固定三类答案口径；
 * 三个 async 入口只做仓储读取与降级判定，不含判断规则。
 */

/** 睡眠段标签：由 AvailabilityBuilder 写入，不是 BlockTag 成员。忙闲文案必须排除，否则"全天空闲"永不成立。 */
const SLEEP_TAG = 'SLEEP';

/** 副标题最多展示的标签数：长窗口标签很多，全列会把卡片撑高。 */
const MAX_SUBTITLE_TAGS = 3;

/** 副标题标签的展示顺序（即优先级），取值必须是 WindowTag。 */
const SUBTITLE_TAGS: string[] = [
  WindowTag.FULL_DAY, WindowTag.TWO_DAYS, WindowTag.TRIP, WindowTag.OVERNIGHT_TRIP,
  WindowTag.WEEKEND, WindowTag.MEAL, WindowTag.HALF_DAY, WindowTag.STUDY
];

/** 计划状态：冲突（与 ScheduleUseCase.detectAndWriteConflicts 写入值一致）。 */
const STATUS_CONFLICT = 'CONFLICT';

/** 对方数据来源（DayViewData.partnerSource 的取值）。 */
const SOURCE_LOCAL = 'LOCAL';
const SOURCE_SNAPSHOT = 'SNAPSHOT';
const SOURCE_NONE = 'NONE';

/** 筛选档"≥2 小时"的下限（分钟），与 WindowFilterKey.GTE_2H 的语义一一对应。 */
const GTE_2H_MIN = 120;

/**
 * 卡片展示标签的压缩顺序（精简版只留三档）。
 * 餐叙/自习不进卡片：它们已经在答案与筛选里出现，堆满卡片只会盖掉日期与时长。
 */
const DISPLAY_TAG_ORDER: string[] = [WindowTag.FULL_DAY, WindowTag.WEEKEND, WindowTag.TRIP];

function tagLabel(tag: string): string {
  if (tag === WindowTag.FULL_DAY) {
    return '完整同休日';
  }
  if (tag === WindowTag.TWO_DAYS) {
    return '连续两天同休';
  }
  if (tag === WindowTag.TRIP) {
    return '可出行';
  }
  if (tag === WindowTag.OVERNIGHT_TRIP) {
    return '可跨夜';
  }
  if (tag === WindowTag.WEEKEND) {
    return '含周末';
  }
  if (tag === WindowTag.MEAL) {
    return '含餐点';
  }
  if (tag === WindowTag.HALF_DAY) {
    return '半天以上';
  }
  if (tag === WindowTag.STUDY) {
    return '适合自习';
  }
  return '';
}

/** 窗口触及的自然日数（半开区间：end 恰为午夜不算新的一天）。 */
function spanDays(start: number, end: number): number {
  if (end <= start) {
    return 0;
  }
  return Math.floor((end - 1) / MIN_PER_DAY) - Math.floor(start / MIN_PER_DAY) + 1;
}

/** 与 [from, to) 有交叠的非睡眠忙碌段，按起点升序。 */
function busyWithin(busy: Interval[], from: number, to: number): Interval[] {
  const out: Interval[] = [];
  for (let i = 0; i < busy.length; i++) {
    const iv = busy[i];
    if (iv.tag === SLEEP_TAG) {
      continue;
    }
    if (iv.start < to && iv.end > from) {
      out.push(iv);
    }
  }
  out.sort((a: Interval, b: Interval): number => a.start - b.start);
  return out;
}

/** 忙碌段 → 文案主体：0 段说空闲，1 段给起止，多段给段数与最早起点。 */
function busyLabel(segs: Interval[], idle: string): string {
  if (segs.length === 0) {
    return idle;
  }
  if (segs.length === 1) {
    return DateLabel.hm(segs[0].start) + '–' + DateLabel.hm(segs[0].end) + ' 忙碌';
  }
  return segs.length + ' 段忙碌 · ' + DateLabel.hm(segs[0].start) + ' 起';
}

/**
 * 空闲措辞按实际扫描范围给：只有扫满一整天才说"全天空闲"。
 * 详情页的忙闲说明会被裁剪到窗口起始日，说"全天"会是假话。
 */
function idleWord(from: number, to: number, dayStart: number): string {
  if (to - from > MIN_PER_DAY) {
    return '整段空闲';
  }
  if (from <= dayStart && to >= dayStart + MIN_PER_DAY) {
    return '全天空闲';
  }
  return '这段时间空闲';
}

function subtitleOf(w: Window): string {
  const tripChannel = w.channel === WindowChannel.TRIP;
  const parts: string[] = [];
  if (tripChannel) {
    // 通道是引擎写入的计算事实，先声明；此时旅行类标签是重复信息，跳过
    parts.push('旅行窗口');
  }
  for (let i = 0; i < SUBTITLE_TAGS.length && parts.length < MAX_SUBTITLE_TAGS; i++) {
    const tag = SUBTITLE_TAGS[i];
    if (tripChannel && (tag === WindowTag.TRIP || tag === WindowTag.OVERNIGHT_TRIP)) {
      continue;
    }
    if (hasTagOf(w.tags, tag)) {
      parts.push(tagLabel(tag));
    }
  }
  if (parts.length === 0) {
    return '共同空闲';
  }
  return parts.join(' · ');
}

/** 筛选判定：与 PRD F4 的分类标签一一对应，出行档读标签而不是从 channel 反推。 */
function matchesFilter(w: Window, key: WindowFilterKey): boolean {
  if (key === WindowFilterKey.ALL) {
    return true;
  }
  if (key === WindowFilterKey.GTE_2H) {
    return w.durationMin >= GTE_2H_MIN;
  }
  if (key === WindowFilterKey.FULL_DAY) {
    return hasTagOf(w.tags, WindowTag.FULL_DAY);
  }
  if (key === WindowFilterKey.WEEKEND) {
    return hasTagOf(w.tags, WindowTag.WEEKEND);
  }
  return hasTagOf(w.tags, WindowTag.TRIP) || hasTagOf(w.tags, WindowTag.OVERNIGHT_TRIP);
}

/**
 * 领域标签 → 卡片展示标签：三档各由一组同义标签收敛而来，顺序固定。
 * 收敛口径与 matchesFilter 完全一致，因此"卡片上出现某个标签"与"该窗口能通过对应筛选档"
 * 始终是同一件事——用户按标签筛出来的结果，不会与卡片上看到的标签矛盾。
 * 餐叙/自习/半天不进卡片：它们只在答案与筛选里出现。
 * 导出给渲染侧复用：窗口详情半模态与卡片必须收敛到同一组标签，否则同一份数据两处口径。
 */
export function toDisplayTags(tags: string[]): string[] {
  const out: string[] = [];
  for (let i = 0; i < DISPLAY_TAG_ORDER.length; i++) {
    const key = DISPLAY_TAG_ORDER[i];
    if (key === WindowTag.TRIP) {
      if (hasTagOf(tags, WindowTag.TRIP) || hasTagOf(tags, WindowTag.OVERNIGHT_TRIP)) {
        out.push(key);
      }
    } else if (hasTagOf(tags, key)) {
      out.push(key);
    }
  }
  return out;
}

/**
 * conflict_hint 的解释文案（不是存起来的字符串）：归因 + 替代窗口。
 * 原因码是 domain 的稳定契约；对方隐私等级不足时码本身就不会是 PARTNER_TIME，
 * 所以这里不存在"不小心说出对方班次"的分支。
 */
function conflictViewOf(row: PlanRow): PlanConflictView | null {
  if (row.status !== STATUS_CONFLICT) {
    return null;
  }
  const h = decodeConflictHint(row.conflictHint);
  const altOk = h != null && h.altStartMin > 0 && h.altEndMin > h.altStartMin;
  const view: PlanConflictView = {
    reasonCode: h != null ? h.reasonCode : '',
    sourceLevel: h != null ? h.sourceLevel : '',
    reasonText: conflictReasonText(h != null ? h.reasonCode : ''),
    affectedText: h != null && h.overlapStartMin > 0 && h.overlapEndMin > h.overlapStartMin
      ? '冲突时段 ' + timeSpanText(h.overlapStartMin, h.overlapEndMin) : '',
    altStart: altOk ? h.altStartMin : 0,
    altEnd: altOk ? h.altEndMin : 0,
    altText: altOk ? '可改到 ' + timeSpanText(h.altStartMin, h.altEndMin) : '',
    kept: h != null && h.kept
  };
  return view;
}

/** 某天的 M月d日 + 起止时刻（跨零点区间只按起点日标注，与计划列表口径一致）。 */
function timeSpanText(start: number, end: number): string {
  return DateLabel.mdw(Math.floor(start / MIN_PER_DAY)) + ' ' + DateLabel.endLabel(start, end);
}

/** 原因码 → 文案；'' 覆盖 Task 2.3 之前写入的旧 hint。 */
function conflictReasonText(code: string): string {
  if (code === CONFLICT_REASON_MY_COURSE) {
    return '与你的课程冲突';
  }
  if (code === CONFLICT_REASON_MY_SHIFT) {
    return '与你的班次冲突';
  }
  if (code === CONFLICT_REASON_MY_RHYTHM) {
    return '落在你的作息时段外';
  }
  if (code === CONFLICT_REASON_PARTNER_TIME) {
    return 'TA 的这段时间已有安排';
  }
  if (code === CONFLICT_REASON_PARTNER_CHANGED) {
    return '对方时间发生变化';
  }
  if (code === CONFLICT_REASON_MIXED) {
    return '与你的安排冲突，对方时间也发生了变化';
  }
  return '与日程冲突';
}

/** 一行式冲突摘要（首页与计划卡共用）。 */
function conflictTextOf(row: PlanRow): string {
  const view = conflictViewOf(row);
  if (view == null) {
    return '';
  }
  return view.reasonText + ' · ' + (view.altText !== '' ? view.altText : '暂无替代时段');
}

/**
 * 首页冲突归因摘要：一句话说清"该找谁"。
 * 对方数据可能只是粗粒度忙闲，所以涉及对方时一律只说"对方时间发生变化"。
 */
function conflictReasonTextOf(rows: PlanRow[]): string {
  let mine = false;
  let partner = false;
  let any = false;
  for (let i = 0; i < rows.length; i++) {
    const view = conflictViewOf(rows[i]);
    if (view == null) {
      continue;
    }
    any = true;
    const s = view.sourceLevel;
    if (s === CONFLICT_SOURCE_MINE) {
      mine = true;
    } else if (s === CONFLICT_SOURCE_PARTNER) {
      partner = true;
    } else if (s === CONFLICT_SOURCE_BOTH) {
      mine = true;
      partner = true;
    }
  }
  if (!any) {
    return '';
  }
  if (mine && partner) {
    return '你们的日程有变';
  }
  if (partner) {
    return '对方时间发生变化';
  }
  if (mine) {
    return '你的日程有变';
  }
  // 只有 Task 2.3 之前写入的未归因 hint：说不清是谁的时间，就不下结论
  return '计划时间需要确认';
}

/** 当天某一方的忙闲装配结果（getDayView 的只读投影，纯函数只依赖它）。 */
export interface DayBusy {
  epochDay: number;
  /**
   * 我的忙碌时间轴：真忙（班次 + 课程 + 计划 + 夜班恢复），不含作息与收整。
   * 这里不放含睡眠的不可用集——落在作息窗口里的块会被并进 SLEEP，
   * 文案按 SLEEP 跳过就编出"全天空闲"那句假话（D-03）。
   */
  myBusy: Interval[];
  /** 对方同口径的忙碌集合；单人或拿不到对方数据时为 null。 */
  partnerBusy: Interval[] | null;
  /** 'LOCAL' | 'SNAPSHOT' | 'NONE'。 */
  partnerSource: string;
  /** 对方隐私等级 1/2/3；无对方数据时为 0。 */
  partnerShareLevel: number;
}

/** 首页装配输入。 */
export interface HomeInput {
  mode: ExperienceMode;
  partnerName: string;
  /** 窗口缓存全量（两个通道都在内）。 */
  windows: Window[];
  plans: PlanRow[];
  day: DayBusy;
  /** 窗口缓存生成时刻（ms）；0 表示从未计算。 */
  computedAt: number;
  nowEpochMin: number;
}

/** 共同时间页装配输入。 */
export interface PageInput {
  windows: Window[];
  plans: PlanRow[];
  filter: WindowFilter;
  mode: ExperienceMode;
  partnerName: string;
  /** 当天的对方数据来源（'LOCAL' | 'SNAPSHOT' | 'NONE'）：决定页面能否宣称"共同"。 */
  partnerSource: string;
  /** 计算视界（天）：副标题里那句"未来 N 个月"的唯一来源，页面不再自己读参数。 */
  horizonDays: number;
  computedAt: number;
  nowEpochMin: number;
}

/** 窗口详情装配输入。 */
export interface DetailInput {
  window: Window;
  day: DayBusy;
}

export class CommonTimeQueryService {
  // ---------- 页面入口（只做 I/O 与降级判定） ----------

  /** 首页读模型：三类答案 + 下个窗口 + 今天概览 + 冲突数。 */
  static async getHomeSummary(nowEpochMin: number): Promise<HomeSummary> {
    const today = Math.floor(nowEpochMin / MIN_PER_DAY);
    const windows = await ScheduleRepo.listWindows();
    const plans = await ScheduleRepo.listActivePlans();
    const computedAt = await ScheduleRepo.windowCacheComputedAt();
    const day = await CommonTimeQueryService.loadDay(today);
    const profile = SettingsStore.getPartnerProfile();
    const input: HomeInput = {
      mode: CommonTimeQueryService.resolveMode(day.partnerSource),
      partnerName: profile != null ? profile.nick : '',
      windows: windows,
      plans: plans,
      day: day,
      computedAt: computedAt,
      nowEpochMin: nowEpochMin
    };
    return CommonTimeQueryService.assembleHome(input);
  }

  /** 共同时间页读模型：按筛选档给出窗口与未来计划，并带上"这些窗口算不算共同"的口径。 */
  static async getCommonTimePage(filter: WindowFilter, nowEpochMin: number): Promise<CommonTimePageData> {
    const today = Math.floor(nowEpochMin / MIN_PER_DAY);
    const windows = await ScheduleRepo.listWindows();
    const plans = await ScheduleRepo.listActivePlans();
    const computedAt = await ScheduleRepo.windowCacheComputedAt();
    const day = await CommonTimeQueryService.loadDay(today);
    const profile = SettingsStore.getPartnerProfile();
    const input: PageInput = {
      windows: windows,
      plans: plans,
      filter: filter,
      mode: CommonTimeQueryService.resolveMode(day.partnerSource),
      partnerName: profile != null ? profile.nick : '',
      partnerSource: day.partnerSource,
      horizonDays: SettingsStoreParams().horizonDays,
      computedAt: computedAt,
      nowEpochMin: nowEpochMin
    };
    return CommonTimeQueryService.assemblePage(input);
  }

  /**
   * 计划分段读模型：全部活动计划（含已结束的历史条目——计划列表按开始时间升序全量展示，
   * 不套用"未来窗口"那套筛选口径）。起点传 0 即只取全部，投影口径仍走 planSummaries。
   */
  static async getPlanCards(): Promise<PlanSummary[]> {
    const rows = await ScheduleRepo.listActivePlans();
    return CommonTimeQueryService.planSummaries(rows, 0);
  }

  /** 窗口详情读模型：窗口展示模型 + 双方忙闲说明 + 对方隐私等级。 */
  static async getWindowDetail(start: number, end: number): Promise<WindowDetailData> {
    const windows = await ScheduleRepo.listWindows();
    let found: Window | null = null;
    for (let i = 0; i < windows.length; i++) {
      if (windows[i].start === start && windows[i].end === end) {
        found = windows[i];
        break;
      }
    }
    if (found == null) {
      // 点开详情时缓存可能已被重算，原窗口不再存在：按起止时间兜底一个无标签窗口，
      // 页面仍能展示双方忙闲；tags 为空 → 不宣称任何分类，channel 占位为常规。
      const gone: Window = {
        start: start, end: end, durationMin: Math.max(0, end - start),
        tags: [], channel: WindowChannel.REGULAR
      };
      found = gone;
    }
    const day = await CommonTimeQueryService.loadDay(Math.floor(found.start / MIN_PER_DAY));
    const input: DetailInput = { window: found, day: day };
    return CommonTimeQueryService.assembleDetail(input);
  }

  /**
   * 体验形态：配对态优先于"今天有没有对方数据"。
   * 已配对但快照暂时拉不到属于 PAIRED，不能显示成未配对。
   */
  static resolveMode(partnerSource: string): ExperienceMode {
    if (partnerSource === SOURCE_SNAPSHOT || SettingsStore.getPairState() === PAIR_PAIRED) {
      return ExperienceMode.PAIRED;
    }
    if (partnerSource === SOURCE_LOCAL) {
      return ExperienceMode.LOCAL_PARTNER;
    }
    return ExperienceMode.SOLO;
  }

  static async loadDay(epochDay: number): Promise<DayBusy> {
    const dv: DayViewData = await ScheduleUseCase.getDayView(epochDay);
    // 忙碌文案读真忙那一份，日视图画"不可用"才读含作息的那一份（两份都在 DayViewData 上）
    const day: DayBusy = {
      epochDay: dv.epochDay,
      myBusy: dv.myTrueBusy,
      partnerBusy: dv.partnerTrueBusy,
      partnerSource: dv.partnerSource,
      partnerShareLevel: dv.partnerShareLevel
    };
    return day;
  }

  // ---------- 纯装配（离线可测） ----------

  static assembleHome(input: HomeInput): HomeSummary {
    const stale = CommonTimeQueryService.isStale(input.computedAt, input.nowEpochMin);
    // 已配对/代录却拿不到对方数据时，缓存里的窗口只是"我的空闲"，不能当共同空闲作答
    const partnerKnown = CommonTimeQueryService.partnerKnownOf(input.mode, input.day.partnerSource);
    const dayStart = input.day.epochDay * MIN_PER_DAY;
    const dayEnd = dayStart + MIN_PER_DAY;
    const prefix = '今天 ';

    const tonight = !partnerKnown
      ? CommonTimeQueryService.unknownAnswer(AnswerKind.TONIGHT, '今晚的空档')
      : CommonTimeQueryService.tonightAnswer(
        CommonTimeQueryService.pickTonight(input.windows, input.nowEpochMin),
        input.nowEpochMin, input.mode, stale);
    const fullRestDay = !partnerKnown
      ? CommonTimeQueryService.unknownAnswer(AnswerKind.FULL_REST_DAY, '完整同休日')
      : CommonTimeQueryService.fullRestDayAnswer(
        CommonTimeQueryService.pickFullRestDay(input.windows, input.nowEpochMin), stale);
    const trip = !partnerKnown
      ? CommonTimeQueryService.unknownAnswer(AnswerKind.TRIP, '出行窗口')
      : CommonTimeQueryService.tripAnswer(
        CommonTimeQueryService.pickTrip(input.windows, input.nowEpochMin), input.mode, stale);

    const next = CommonTimeQueryService.nextRegular(input.windows, input.nowEpochMin);
    const today: TodaySummary = {
      myText: CommonTimeQueryService.myLabel(input.day, dayStart, dayEnd),
      partnerText: CommonTimeQueryService.partnerLabel(input.day, dayStart, dayEnd, prefix),
      // 当日共同空闲只统计常规通道：旅行通道与常规窗口在时间上重叠，一起加会重复计时
      commonText: prefix + CommonTimeQueryService.commonLabel(input.windows, dayStart, dayEnd)
    };

    const home: HomeSummary = {
      mode: input.mode,
      partnerName: input.partnerName,
      tonight: tonight,
      fullRestDay: fullRestDay,
      trip: trip,
      nextWindow: next != null ? CommonTimeQueryService.summaryOf(next) : null,
      conflictCount: CommonTimeQueryService.countConflicts(input.plans),
      conflictReason: conflictReasonTextOf(input.plans),
      today: today,
      computedAt: input.computedAt,
      stale: stale
    };
    return home;
  }

  static assemblePage(input: PageInput): CommonTimePageData {
    const kept: Window[] = [];
    for (let i = 0; i < input.windows.length; i++) {
      const w = input.windows[i];
      if (w.end <= input.filter.fromEpochMin) {
        continue;
      }
      if (!matchesFilter(w, input.filter.key)) {
        continue;
      }
      kept.push(w);
    }
    kept.sort((a: Window, b: Window): number => a.start - b.start);
    const summaries: WindowSummary[] = [];
    for (let i = 0; i < kept.length; i++) {
      summaries.push(CommonTimeQueryService.summaryOf(kept[i]));
    }
    const page: CommonTimePageData = {
      rows: CommonTimeQueryService.mergeByDay(summaries),
      windows: summaries,
      plans: CommonTimeQueryService.planSummaries(input.plans, input.filter.fromEpochMin),
      mode: input.mode,
      partnerName: input.partnerName,
      partnerKnown: CommonTimeQueryService.partnerKnownOf(input.mode, input.partnerSource),
      horizonDays: input.horizonDays,
      computedAt: input.computedAt,
      stale: CommonTimeQueryService.isStale(input.computedAt, input.nowEpochMin)
    };
    return page;
  }

  /**
   * 列表按日归并：一天只留最长的一段，被覆盖的天不再单列。
   * 常规与旅行通道在同一时段各产出一个窗口，归并顺带把重复展示去掉；
   * 归并只挑不造，输出必定是输入的子集，且每个输入窗口触及的自然日都恰好被一行覆盖。
   */
  static mergeByDay(summaries: WindowSummary[]): WindowSummary[] {
    const byDuration: WindowSummary[] = summaries.slice();
    byDuration.sort((a: WindowSummary, b: WindowSummary): number => {
      if (b.durationMin !== a.durationMin) {
        return b.durationMin - a.durationMin;
      }
      return a.start - b.start;
    });
    const covered = new Set<number>();
    const rows: WindowSummary[] = [];
    for (let i = 0; i < byDuration.length; i++) {
      const w = byDuration[i];
      const firstDay = Math.floor(w.start / MIN_PER_DAY);
      const lastDay = Math.floor((w.end - 1) / MIN_PER_DAY);
      let overlapped = false;
      for (let d = firstDay; d <= lastDay; d++) {
        if (covered.has(d)) {
          overlapped = true;
          break;
        }
      }
      if (overlapped) {
        continue;
      }
      for (let d = firstDay; d <= lastDay; d++) {
        covered.add(d);
      }
      rows.push(w);
    }
    rows.sort((a: WindowSummary, b: WindowSummary): number => a.start - b.start);
    return rows;
  }

  /**
   * 能不能宣称"共同"：单人形态本来就只有我，算；已配对/代录却拿不到对方数据时不算。
   * 此时缓存里的窗口只是"我的空闲"，页面必须显式降级说明，不能当共同时间展示。
   */
  static partnerKnownOf(mode: ExperienceMode, partnerSource: string): boolean {
    return mode === ExperienceMode.SOLO || partnerSource !== SOURCE_NONE;
  }

  static assembleDetail(input: DetailInput): WindowDetailData {
    const w = input.window;
    const dayStart = input.day.epochDay * MIN_PER_DAY;
    const dayEnd = dayStart + MIN_PER_DAY;
    // getDayView 是单日视图：忙闲说明只覆盖窗口起始日，跨日窗口的其余日期由页面按日展开
    const from = w.start > dayStart ? w.start : dayStart;
    const to = w.end < dayEnd ? w.end : dayEnd;
    const detail: WindowDetailData = {
      window: CommonTimeQueryService.summaryOf(w),
      myBusyText: CommonTimeQueryService.myLabel(input.day, from, to),
      partnerBusyText: CommonTimeQueryService.partnerLabel(input.day, from, to, ''),
      partnerShareLevel: input.day.partnerShareLevel
    };
    return detail;
  }

  /**
   * 缓存新鲜度：computed_at 落在更早的本地日历日即过期（0 = 从未计算）。
   * 引擎视界从"重算当天"起算，跨日之后缓存里的"今天"已经不是今天。
   */
  static isStale(computedAt: number, nowEpochMin: number): boolean {
    if (computedAt <= 0) {
      return true;
    }
    return todayEpochDay(computedAt) < Math.floor(nowEpochMin / MIN_PER_DAY);
  }

  /**
   * 今晚的窗口：只取常规通道、与今天剩余时间有交叠的窗口。
   * 旅行通道的长窗口常常横跨今天，不过滤就会把"今晚"劫持成出行答案。
   * 排序键为"现在起可用的时刻"，因此正在进行的窗口优先于稍后开始的窗口。
   */
  static pickTonight(windows: Window[], nowEpochMin: number): Window | null {
    const dayEnd = (Math.floor(nowEpochMin / MIN_PER_DAY) + 1) * MIN_PER_DAY;
    let best: Window | null = null;
    let bestFrom = 0;
    for (let i = 0; i < windows.length; i++) {
      const w = windows[i];
      if (w.channel !== WindowChannel.REGULAR) {
        continue;
      }
      if (w.end <= nowEpochMin || w.start >= dayEnd) {
        continue;
      }
      const from = w.start > nowEpochMin ? w.start : nowEpochMin;
      if (best == null || from < bestFrom) {
        best = w;
        bestFrom = from;
      }
    }
    return best;
  }

  /** 完整同休日：只认 FULL_DAY 分类标签，不按时长自行推断。 */
  static pickFullRestDay(windows: Window[], nowEpochMin: number): Window | null {
    let best: Window | null = null;
    for (let i = 0; i < windows.length; i++) {
      const w = windows[i];
      if (w.end <= nowEpochMin || !hasTagOf(w.tags, WindowTag.FULL_DAY)) {
        continue;
      }
      if (best == null || w.start < best.start) {
        best = w;
      }
    }
    return best;
  }

  /** 出行窗口：优先 TRIP，其次 OVERNIGHT_TRIP；同类取最近的。 */
  static pickTrip(windows: Window[], nowEpochMin: number): Window | null {
    let trip: Window | null = null;
    let overnight: Window | null = null;
    for (let i = 0; i < windows.length; i++) {
      const w = windows[i];
      if (w.end <= nowEpochMin) {
        continue;
      }
      if (hasTagOf(w.tags, WindowTag.TRIP)) {
        if (trip == null || w.start < trip.start) {
          trip = w;
        }
      } else if (hasTagOf(w.tags, WindowTag.OVERNIGHT_TRIP)) {
        if (overnight == null || w.start < overnight.start) {
          overnight = w;
        }
      }
    }
    return trip != null ? trip : overnight;
  }

  /** 下个窗口：常规通道里最近的一个（旅行通道与其时间重叠，不作为"下个"展示）。 */
  static nextRegular(windows: Window[], nowEpochMin: number): Window | null {
    let best: Window | null = null;
    for (let i = 0; i < windows.length; i++) {
      const w = windows[i];
      if (w.channel !== WindowChannel.REGULAR || w.end <= nowEpochMin) {
        continue;
      }
      if (best == null || w.start < best.start) {
        best = w;
      }
    }
    return best;
  }

  static summaryOf(w: Window): WindowSummary {
    const summary: WindowSummary = {
      start: w.start,
      end: w.end,
      durationMin: w.durationMin,
      tags: w.tags,
      displayTags: toDisplayTags(w.tags),
      channel: w.channel,
      title: DateLabel.mdw(Math.floor(w.start / MIN_PER_DAY)) + ' ' + DateLabel.hm(w.start)
        + ' 起 ' + DateLabel.duration(w.durationMin),
      subtitle: subtitleOf(w)
    };
    return summary;
  }

  static filterWindows(windows: Window[], filter: WindowFilter): Window[] {
    const out: Window[] = [];
    for (let i = 0; i < windows.length; i++) {
      const w = windows[i];
      if (w.end > filter.fromEpochMin && matchesFilter(w, filter.key)) {
        out.push(w);
      }
    }
    out.sort((a: Window, b: Window): number => a.start - b.start);
    return out;
  }

  /** 未来计划（已结束的不进列表），按开始时间升序。 */
  static planSummaries(rows: PlanRow[], fromEpochMin: number): PlanSummary[] {
    const out: PlanSummary[] = [];
    for (let i = 0; i < rows.length; i++) {
      const r = rows[i];
      if (r.end <= fromEpochMin) {
        continue;
      }
      const p: PlanSummary = {
        id: r.id, title: r.title, kind: r.kind, start: r.start, end: r.end,
        status: r.status, conflictText: conflictTextOf(r), conflict: conflictViewOf(r),
        // 读边界归一：库里可能还写着阶段 2 的 'WRITTEN'（那时 editEvent 与直写没分家），
        // 不归一就会把删不掉的日程显示成"本应用会替你同步"。
        calendarState: normalizeCalendarState(r.calendarState)
      };
      out.push(p);
    }
    return out;
  }

  static countConflicts(rows: PlanRow[]): number {
    let n = 0;
    for (let i = 0; i < rows.length; i++) {
      if (rows[i].status === STATUS_CONFLICT) {
        n++;
      }
    }
    return n;
  }

  /** 窗口跨了几个自然日（答案文案里必须明确天数）。 */
  static daysSpan(start: number, end: number): number {
    return spanDays(start, end);
  }

  static myLabel(day: DayBusy, from: number, to: number): string {
    const dayStart = day.epochDay * MIN_PER_DAY;
    return CommonTimeQueryService.dayPrefix(from, day.epochDay)
      + busyLabel(busyWithin(day.myBusy, from, to), idleWord(from, to, dayStart));
  }

  static partnerLabel(day: DayBusy, from: number, to: number, prefix: string): string {
    if (day.partnerBusy == null) {
      return prefix + 'TA 的忙碌未知';
    }
    const segs = busyWithin(day.partnerBusy, from, to);
    if (day.partnerShareLevel <= 1) {
      // L1 快照只有 30 分钟位图：给段数不给时刻，避免把粗粒度数据当精确事实展示
      return prefix + 'TA ' + (segs.length === 0 ? '大致空闲' : '约 ' + segs.length + ' 段忙碌');
    }
    return prefix + 'TA ' + busyLabel(segs, idleWord(from, to, day.epochDay * MIN_PER_DAY));
  }

  static commonLabel(windows: Window[], from: number, to: number): string {
    let min = 0;
    for (let i = 0; i < windows.length; i++) {
      const w = windows[i];
      if (w.channel !== WindowChannel.REGULAR) {
        continue;
      }
      min += overlapMin(w.start, w.end, from, to);
    }
    if (min <= 0) {
      return '暂无共同空闲';
    }
    return '共同空闲 ' + DateLabel.duration(min);
  }

  // ---------- 答案文案 ----------

  /**
   * 今晚答案的补充行：时长只报窗口本身有多长，等待另说一句。
   * 未开始的窗口若用「现在到结束」，会把两小时空档说成四小时半——那是等待时长，不是共同空闲。
   */
  static tonightSupport(w: Window, nowEpochMin: number): string {
    const total = w.end - w.start;
    if (nowEpochMin < w.start) {
      return DateLabel.duration(w.start - nowEpochMin) + '后开始 · 共 ' + DateLabel.duration(total);
    }
    return '还剩 ' + DateLabel.duration(w.end - nowEpochMin) + ' · 共 ' + DateLabel.duration(total);
  }

  static tonightAnswer(w: Window | null, nowEpochMin: number,
    mode: ExperienceMode, stale: boolean): QuickAnswer {
    const subject = mode === ExperienceMode.SOLO ? '我' : '我们';
    if (w == null) {
      return CommonTimeQueryService.absentAnswer(AnswerKind.TONIGHT, '今晚的空档', stale,
        '今晚没有' + subject + '共同的空档', '看看明天，或调整就寝时间');
    }
    if (nowEpochMin >= w.end) {
      // 选取环节已排除已结束窗口，走到这里只可能是缓存里的旧结果：给事实，不谎报有空
      return CommonTimeQueryService.absentAnswer(AnswerKind.TONIGHT, '今晚的空档', stale,
        '今晚的共同空档已结束', '看看明天，或调整就寝时间');
    }
    const answer: QuickAnswer = {
      kind: AnswerKind.TONIGHT,
      state: AnswerState.AVAILABLE,
      headline: '今晚 ' + DateLabel.endLabel(w.start, w.end) + ' ' + subject + '都有空',
      supportingText: CommonTimeQueryService.tonightSupport(w, nowEpochMin),
      windowStart: w.start,
      windowEnd: w.end,
      action: AnswerAction.OPEN_WINDOW
    };
    return answer;
  }

  static fullRestDayAnswer(w: Window | null, stale: boolean): QuickAnswer {
    // 同一概念只有一个名字：单人态也念「完整同休日」，与窗口标签、首页那一问一致（D-14）。
    const noun = '完整同休日';
    if (w == null) {
      return CommonTimeQueryService.absentAnswer(AnswerKind.FULL_REST_DAY, noun, stale,
        '近期没有' + noun, '放宽起床/就寝时间，或看更长的窗口');
    }
    const days = spanDays(w.start, w.end);
    const answer: QuickAnswer = {
      kind: AnswerKind.FULL_REST_DAY,
      state: AnswerState.AVAILABLE,
      headline: DateLabel.mdw(Math.floor(w.start / MIN_PER_DAY)) + ' 是' + noun,
      supportingText: (days > 1 ? '连续 ' + days + ' 天 · ' : '') + DateLabel.duration(w.durationMin)
        + ' 可安排',
      windowStart: w.start,
      windowEnd: w.end,
      action: AnswerAction.OPEN_WINDOW
    };
    return answer;
  }

  static tripAnswer(w: Window | null, mode: ExperienceMode, stale: boolean): QuickAnswer {
    const noun = mode === ExperienceMode.SOLO ? '可出行时段' : '出行窗口';
    if (w == null) {
      return CommonTimeQueryService.absentAnswer(AnswerKind.TRIP, noun, stale,
        '近期凑不出' + noun, '需要连续两天以上的共同空闲');
    }
    const days = spanDays(w.start, w.end);
    const overnightOnly = !hasTagOf(w.tags, WindowTag.TRIP);
    const answer: QuickAnswer = {
      kind: AnswerKind.TRIP,
      state: AnswerState.AVAILABLE,
      headline: (overnightOnly ? '能跨夜出行 ' : '能安排出行 ') + days + ' 天',
      supportingText: DateLabel.mdw(Math.floor(w.start / MIN_PER_DAY)) + ' '
        + DateLabel.endLabel(w.start, w.end) + ' · 共 ' + DateLabel.duration(w.durationMin),
      windowStart: w.start,
      windowEnd: w.end,
      action: AnswerAction.OPEN_WINDOW
    };
    return answer;
  }

  /**
   * 无候选窗口时的答案。缓存过期时不能断言"没有"，只能断言"待重新计算"：
   * STALE 与 UNAVAILABLE 是两种事实，文案不得合并。
   */
  static absentAnswer(kind: AnswerKind, noun: string, stale: boolean,
    headline: string, hint: string): QuickAnswer {
    const answer: QuickAnswer = {
      kind: kind,
      state: stale ? AnswerState.STALE : AnswerState.UNAVAILABLE,
      headline: stale ? noun + '待重新计算' : headline,
      supportingText: stale ? '班表可能已变化，重算后再确认' : hint,
      windowStart: 0,
      windowEnd: 0,
      action: AnswerAction.OPEN_SCHEDULE
    };
    return answer;
  }

  /** 缺少对方数据：不给结论，指向配对/代录入口。 */
  static unknownAnswer(kind: AnswerKind, noun: string): QuickAnswer {
    const answer: QuickAnswer = {
      kind: kind,
      state: AnswerState.UNKNOWN,
      headline: '还不知道 TA 的日程',
      supportingText: '配对或代录 TA 的班表后，' + noun + '会自动出现',
      windowStart: 0,
      windowEnd: 0,
      action: AnswerAction.OPEN_PARTNER
    };
    return answer;
  }

  /** 忙碌文案的日期前缀：当天说"今天"，其余说月日。 */
  static dayPrefix(fromEpochMin: number, epochDay: number): string {
    if (Math.floor(fromEpochMin / MIN_PER_DAY) === epochDay) {
      return '今天 ';
    }
    return DateLabel.md(Math.floor(fromEpochMin / MIN_PER_DAY)) + ' ';
  }
}
