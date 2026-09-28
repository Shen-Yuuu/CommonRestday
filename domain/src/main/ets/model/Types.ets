/**
 * 领域层共享类型定义。
 *
 * 时间约定（全领域统一）：
 * - 内部时间单位为「本地纪元分钟」：epochMin = epochDay * 1440 + minuteOfDay（本地时区语义）。
 * - epochDay：自 1970-01-01 本地零点起的天数。
 * - 中国无夏令时，按线性分钟运算；与 UI/持久层换算只在边界处进行。
 */

/** 一天的分钟数。 */
export const MIN_PER_DAY = 1440;

/** 班表数据归属：我。 */
export const OWNER_ME = 'ME';

/** 班表数据归属：伴侣（本机代录双人模式）。 */
export const OWNER_PARTNER = 'PARTNER';

/** 忙碌块来源标签。 */
export enum BlockTag {
  WORK = 'WORK',           // 班次（含通勤）
  RECOVERY = 'RECOVERY',   // 夜班后恢复（用户自设时长）
  COURSE = 'COURSE',       // 大学课程
  PLAN = 'PLAN',           // 已确认的共同计划
  BUSY = 'BUSY'            // 快照传入的不可用时间（对方）
}

/** 班次类型：一种可复用的"班"的定义。 */
export interface ShiftType {
  id: string;
  name: string;
  color: string;
  /** 距 00:00 的分钟数。 */
  startMin: number;
  /** 距 00:00 的分钟数；endMin <= startMin 表示跨天（结束在下一天）。 */
  endMin: number;
  /** 显式跨天标记；endMin <= startMin 时自动视为跨天。 */
  crossDay: boolean;
  commuteInMin: number;
  commuteOutMin: number;
  /** 下夜班后的恢复时长（分钟），0 表示无。 */
  recoveryMin: number;
  /** 夜班判定：0=自动（与夜班窗口相交）1=强制是 2=强制否。 */
  nightMode: number;
  /** 值班类班次允许在班内安排活动（首版不参与计算，预留）。 */
  allowActivity: boolean;
  kind: string;
}

/** 循环模板：班次序列 + 锚点（seq[0] 对应的真实 epochDay）。 */
export interface CycleTemplate {
  id: string;
  name: string;
  seq: string[];
  anchorEpochDay: number;
}

/** 单日覆盖：临时换班/请假；shiftTypeId 为 null 表示该日清空为休息。 */
export interface ScheduleOverride {
  epochDay: number;
  shiftTypeId: string | null;
}

/** 大学课程。 */
export interface Course {
  id: string;
  name: string;
  /** 1=周一 … 7=周日。 */
  weekday: number;
  sectionStart: number;
  sectionEnd: number;
  weekFrom: number;
  weekTo: number;
  /** 0=每周 1=单周 2=双周。 */
  parity: number;
  place: string;
}

/** 节次 → 时间的映射（一节的起止，距 00:00 分钟数）。 */
export interface SectionTime {
  startMin: number;
  endMin: number;
}

/** 已确认共同计划占用的时段。 */
export interface PlanBlock {
  start: number;
  end: number;
}

/** 展开产物：某天的班次实例。 */
export interface ShiftInstance {
  epochDay: number;
  typeId: string;
}

/** 基础区间（epochMin，半开区间 [start, end)，tag 为来源）。 */
export interface Interval {
  start: number;
  end: number;
  tag: string;
}

/** 共同空闲窗口（带分类标签）。 */
/**
 * 共同时间计算通道：由 CommonFreeEngine 生成窗口时一次性写入，
 * 数据层与 UI 一律不得从 tags 反推（旅行标签只是分类结果，不是通道证据）。
 */
export enum WindowChannel {
  /** 常规：睡眠计入忙集，不可在睡眠时段安排活动。 */
  REGULAR = 'REGULAR',
  /** 旅行：仅真忙+收整计入忙集，睡眠可被跨越。 */
  TRIP = 'TRIP'
}

export interface Window {
  start: number;
  end: number;
  durationMin: number;
  tags: string[];
  channel: WindowChannel;
}

/** 窗口分类标签（与 PRD F4 筛选项一一对应）。 */
export enum WindowTag {
  MEAL = 'MEAL',                 // 覆盖午/晚餐时段
  HALF_DAY = 'HALF_DAY',         // ≥4h
  FULL_DAY = 'FULL_DAY',         // 完整同休日
  TWO_DAYS = 'TWO_DAYS',         // 连续两个完整同休日
  WEEKEND = 'WEEKEND',           // 覆盖周六或周日
  OVERNIGHT_TRIP = 'OVERNIGHT_TRIP', // ≥16h 且跨零点
  TRIP = 'TRIP',                 // ≥32h 或连续两天
  STUDY = 'STUDY'                // 工作日白天 ≥studyMinMin 的共同自习窗口
}

/**
 * 计算视界的硬上限（天）：取一整年（闰年 366 天）为止。
 *
 * 为什么停在这儿：引擎成本对视界近似线性（`docs/validation/performance-budget.md` §2 的视界扫描，
 * 开发机下界 120d=13.6ms、240d=40.0ms、366d=72.0ms），上云那份包络是 `days × 48` 个 30 分钟槽，
 * 列表投影的行数上限也直接等于它（同文档 §3）——三样都随天数线性涨。
 *
 * 这个数同时是设置页允许填的上限（feature 的 `RhythmRules.HORIZON_MAX` 由它派生）：
 * "校验放行 500、引擎只算 366"这种读数与计算各说一套的漂移，就是这么分家的（D-57）。
 */
export const HORIZON_MAX_DAYS: number = 366;

/**
 * 把任意来源的视界天数收进 [1, HORIZON_MAX_DAYS]：引擎只按这个值逐日展开。
 *
 * 来源不可全信：设置页有校验，但 Preferences 里那份 JSON 可能是备份/换机迁移从**更新的**
 * 版本带回来的（SettingsStore.assignParam 只挡 NaN，不挡取值范围），未落库的默认值也可能
 * 被调用方改写。所以每个算天数的地方都过这一道，而不是各自手写上下界。
 */
export function clampHorizonDays(days: number): number {
  return Math.max(1, Math.min(days, HORIZON_MAX_DAYS));
}

/** 引擎可调参数（PRD F4：全部可配置，无隐藏假设）。 */
export interface EngineParams {
  horizonDays: number;
  /** 起床（距 00:00 分钟）。 */
  wakeMin: number;
  /** 就寝（距 00:00 分钟）；小于 wakeMin 视为跨零点。 */
  bedMin: number;
  /** 收整缓冲：忙→闲转换后进入"可安排"前需要的分钟数。 */
  windDownMin: number;
  /** 夜班窗口 [nightStartMin, nightEndMin)，默认 00:00–05:00。 */
  nightStartMin: number;
  nightEndMin: number;
  /** 筛选下限：最小窗口（分钟）。 */
  minSlotMin: number;
  halfDayMin: number;
  fullDayAvailMin: number;
  overnightMinMin: number;
  tripMinMin: number;
  /** STUDY 判定：白天时段起点（距 00:00 分钟），默认 08:00。 */
  studyStartMin: number;
  /** STUDY 判定：白天时段终点（距 00:00 分钟），默认 21:00。 */
  studyEndMin: number;
  /** STUDY 判定：最小窗口时长（分钟），默认 2h。 */
  studyMinMin: number;
}

/**
 * 默认视界（天）。`defaultParams()` 与"从存储读回但没个可用值"两条路都念这一个数。
 *
 * 它在 D-59 之前抄在 `commons` 的 `AppConst.HORIZON_DAYS`（也是 120），于是"引擎默认算多远"
 * 和"界面/兜底说默认多远"各有各的出处：改一处，另一处照样念旧数。默认值放这儿是因为
 * 它就是引擎的属性，`commons` 那份是它下游的抄写。
 */
export const HORIZON_DEFAULT_DAYS: number = 120;

/** 默认参数（与 PRD 示例口径一致）。 */
export function defaultParams(): EngineParams {
  const p: EngineParams = {
    horizonDays: HORIZON_DEFAULT_DAYS,
    wakeMin: 420,            // 07:00
    bedMin: 1350,            // 22:30
    windDownMin: 20,
    nightStartMin: 0,
    nightEndMin: 300,        // 05:00
    minSlotMin: 120,
    halfDayMin: 240,
    fullDayAvailMin: 720,
    overnightMinMin: 960,    // 16h
    tripMinMin: 1920,        // 32h
    studyStartMin: 480,      // 08:00
    studyEndMin: 1260,       // 21:00
    studyMinMin: 120         // 2h
  };
  return p;
}

/** 本机班表输入（本地全量细节）。 */
export interface MySchedule {
  shiftTypes: ShiftType[];
  template: CycleTemplate | null;
  overrides: ScheduleOverride[];
  courses: Course[];
  sectionTimes: SectionTime[];
  /** 学期第一周周一的 epochDay；无学期则为 -1。 */
  termStartEpochDay: number;
  plans: PlanBlock[];
  wakeMin: number;
  bedMin: number;
  windDownMin: number;
}

/** 对方共享输入：busyIntervals 已是"不可用"语义（含对方睡眠/缓冲）。 */
export interface PartnerSchedule {
  shareLevel: number;
  busyIntervals: Interval[];
  /**
   * 对方"不含睡眠"的不可用区间（忙碌块+收整缓冲，已合并）：
   * 用于完整同休日判定（当日真忙=0）与旅行窗口（睡眠可被跨越）。
   * 缺省/null 时引擎回退为 busyIntervals 剥离 SLEEP 段；L1 快照睡眠与班次不可分，
   * 剥离结果仍含睡眠 → 同休日/旅行判定自然保守（不误标），行为正确。
   */
  tripBusyIntervals?: Interval[] | null;
}

export interface EngineInput {
  my: MySchedule;
  partner: PartnerSchedule | null;
  params: EngineParams;
  /** 计算起点（通常为今天 00:00 的 epochDay）。 */
  horizonStartEpochDay: number;
}

export interface CommonFreeResult {
  windows: Window[];
  /** 完整同休日的 epochDay 列表。 */
  fullDays: number[];
  computeMs: number;
}

/** 冲突检测用的计划轻量视图（domain 不感知 data 层 PlanRow）。 */
export interface PlanLite {
  id: string;
  /** 计划开始（epochMin）。 */
  startMin: number;
  /** 计划结束（epochMin）。 */
  endMin: number;
}

/**
 * 冲突原因码（稳定契约：文案和测试都按码匹配，改文案不改码）。
 * 码里必须带"是谁的时间变了"——用户看到红点时第一个问题就是这个。
 */
export const CONFLICT_REASON_MY_COURSE = 'MY_COURSE';
export const CONFLICT_REASON_MY_SHIFT = 'MY_SHIFT';
export const CONFLICT_REASON_MY_RHYTHM = 'MY_RHYTHM';
/** 对方数据带得出班次语义（L3 快照或本机代录）时才能用这个码。 */
export const CONFLICT_REASON_PARTNER_TIME = 'PARTNER_TIME';
/** 对方只共享了粗粒度忙闲（L1/L2 位图，标签全为 BUSY）：只能说"对方时间发生变化"。 */
export const CONFLICT_REASON_PARTNER_CHANGED = 'PARTNER_CHANGED';
/** 双方时间都压上了这一段。 */
export const CONFLICT_REASON_MIXED = 'MIXED';
/** 未归因：调用方只给了合并后的忙区间并集，说不清是谁的时间。 */
export const CONFLICT_REASON_UNKNOWN = '';

/** 冲突来源级别（归因到谁）。 */
export const CONFLICT_SOURCE_MINE = 'MINE';
export const CONFLICT_SOURCE_PARTNER = 'PARTNER';
export const CONFLICT_SOURCE_BOTH = 'BOTH';

/**
 * 归因用的分侧忙区间：必须分开传，合并后的并集已经把 tag 吃掉了，
 * 拿并集反推"这是你的课还是 TA 的班"必然出错。
 */
export interface ConflictSources {
  /** 我的不可用区间（tag 指示课程 / 班次 / 作息外）。 */
  my: Interval[];
  /** 对方不可用区间；单人或拿不到对方数据时为 null。 */
  partner: Interval[] | null;
}

/** 冲突检测结果：alternative 为 0 表示无替代窗口。 */
export interface ConflictOutcome {
  planId: string;
  /** 是否与"排除计划自身占用后的双方忙区间并集"交叠。 */
  conflict: boolean;
  /** 替代窗口起点（epochMin）；0 表示无替代。 */
  alternativeStartMin: number;
  /** 替代窗口终点（epochMin）；0 表示无替代。 */
  alternativeEndMin: number;
  /** 原因码（CONFLICT_REASON_*）；无冲突或未归因为 CONFLICT_REASON_UNKNOWN。 */
  reasonCode: string;
  /** 来源级别（CONFLICT_SOURCE_*）；无冲突或未归因时空串。 */
  sourceLevel: string;
  /** 受影响区间起点（epochMin）：计划与忙区间实际交叠的那一段，不是整段计划。 */
  overlapStartMin: number;
  /** 受影响区间终点（epochMin）。 */
  overlapEndMin: number;
}
