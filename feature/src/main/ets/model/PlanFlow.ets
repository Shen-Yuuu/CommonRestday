/**
 * 计划流程的纯口径（阶段 2 Task 2.2）：窗口校验、默认草稿、日历确认状态机、提交闩。
 *
 * 这里不碰任何 @kit/RDB：设备侧只把 Calendar Kit 的结果归一成 CalendarOutcome，
 * "取消/拒绝时保留哪一份事实"这类判断留在这里，离线单测（tools/test/run.mjs）直接跑本文件。
 * 唯一的例外是 FeatureFlags：它是编译期常量而不是运行时依赖，读它不引入设备能力。
 */
import { FeatureFlags } from '../config/FeatureFlags';

/** Calendar Kit 归一后的能力结果；PlanUseCase 不直接看系统错误码。 */
export enum CalendarOutcome {
  /** 用户确认并写入成功（带 eventId）。 */
  WRITTEN = 'WRITTEN',
  /** 系统日程编辑页被用户取消（返回 id < 0）。 */
  CANCELED = 'CANCELED',
  /** 读写日历权限未授予。 */
  DENIED = 'DENIED',
  /** 设备没有可用日历账户/能力。 */
  UNAVAILABLE = 'UNAVAILABLE',
  /** 调用抛错（日历应用异常等）。 */
  FAILED = 'FAILED'
}

/** plan.calendar_state 取值（DDL 默认 NOT_REQUESTED）。 */
export enum CalendarState {
  /** 尚未请求过日历。 */
  NOT_REQUESTED = 'NOT_REQUESTED',
  /** 本地计划已落库，正在等系统日历确认。 */
  PENDING = 'PENDING',
  /** 系统日历里已有这条日程。 */
  WRITTEN = 'WRITTEN',
  /** 仅保存在应用内（取消/无权限/不可用）。 */
  LOCAL_ONLY = 'LOCAL_ONLY',
  /** 设备不支持日历能力。 */
  UNSUPPORTED = 'UNSUPPORTED',
  /** 写入失败，可稍后重试。 */
  FAILED = 'FAILED'
}

/** 日历没写成时的统一口径：计划本身仍然成立，只是没进系统日历。 */
export const LOCAL_ONLY_NOTE = '仅保存在应用内';

/** 计划最短时长与默认时长（分钟）。 */
export const MIN_PLAN_MIN = 15;
export const DEFAULT_PLAN_MIN = 120;

/**
 * 计划主键：毫秒时间戳 + 随机尾巴，本地单用户场景够用。
 * 不用 util.generateRandomUUID() 是因为那要引 @kit.ArkTS，会把编排逻辑锁死在真机上。
 */
export function newPlanId(): string {
  return 'plan_' + Date.now() + '_' + Math.floor(Math.random() * 1000000);
}

/** 本地纪元分钟（epochMin）→ 13 位毫秒时间戳：系统日历与提醒都按本地时区语义换算。 */
export function epochMinToUtcMs(epochMin: number): number {
  // getTimezoneOffset() = UTC - 本地（分钟，如东八区为 -480）
  return (epochMin + new Date().getTimezoneOffset()) * 60000;
}

/** 一次日历写入的归一结果：eventId 仅在 WRITTEN 时有值。 */
export interface CalendarWriteResult {
  outcome: CalendarOutcome;
  eventId: string;
}

/**
 * 计划编排要用的系统能力端口（阶段 2 Task 2.2）。
 *
 * 设备侧的真实现是 CalendarGateway / ReminderGateway 的静态门面；把它们收成端口，
 * 是因为"用户点了取消""权限被拒"这类分支在真机上不可复现，
 * 而它们恰恰决定了本地计划该不该保留——不能只靠人肉验收。
 */
export interface CalendarCapability {
  /** direct=true 走"跳过系统确认页直接写入"的高级路径，默认由用户当面确认。 */
  confirm(title: string, startMin: number, endMin: number, direct: boolean): Promise<CalendarWriteResult>;

  remove(eventId: string): Promise<boolean>;
}

export interface ReminderCapability {
  /** 返回 reminderId，<0 = 未注册（通知未开启或发布失败），调用方不阻塞计划。 */
  publish(title: string, startMin: number): Promise<number>;

  cancel(reminderId: number): Promise<void>;
}

/** 计划草稿（窗口内起止 + 类型 + 标题）。 */
export interface PlanDraft {
  title: string;
  kind: string;
  start: number;
  end: number;
}

/**
 * 打开窗口时的默认草稿：从窗口起点排 DEFAULT_PLAN_MIN 分钟，
 * 超出窗口则收缩到窗口止点；整段窗口不足最短时长时按窗口原样给出，
 * 由 planDraftError 判非法——这样 sheet 恢复/换窗口重开都得到同一结果。
 */
export function defaultDraft(winStart: number, winEnd: number, title: string, kind: string): PlanDraft {
  let end = Math.min(winStart + DEFAULT_PLAN_MIN, winEnd);
  if (end - winStart < MIN_PLAN_MIN) {
    end = Math.min(winStart + MIN_PLAN_MIN, winEnd);
  }
  return { title: title, kind: kind, start: winStart, end: end };
}

/**
 * 草稿合法性校验，返回给用户的文案（'' = 合法）。
 * 计划区间必须完全落在窗口内：窗口外的"共同时间"并不共同，写进日历会误导对方。
 */
export function planDraftError(draft: PlanDraft, winStart: number, winEnd: number): string {
  if (draft.title.trim() === '') {
    return '请填写计划标题';
  }
  if (draft.start >= draft.end) {
    return '计划开始需早于结束';
  }
  if (draft.start < winStart || draft.end > winEnd) {
    return '计划时间需在窗口范围内';
  }
  if (draft.end - draft.start < MIN_PLAN_MIN) {
    return '计划时长至少 ' + MIN_PLAN_MIN + ' 分钟';
  }
  return '';
}

/** 能力结果 → 落库的 calendar_state。 */
export function calendarStateOf(outcome: CalendarOutcome): string {
  if (outcome === CalendarOutcome.WRITTEN) {
    return CalendarState.WRITTEN;
  }
  if (outcome === CalendarOutcome.DENIED || outcome === CalendarOutcome.CANCELED) {
    return CalendarState.LOCAL_ONLY;
  }
  if (outcome === CalendarOutcome.UNAVAILABLE) {
    return CalendarState.UNSUPPORTED;
  }
  return CalendarState.FAILED;
}

/** 是否已在系统日历里（false = 只在本应用内，UI 必须说清楚）。 */
export function isOnSystemCalendar(calendarState: string): boolean {
  return calendarState === CalendarState.WRITTEN;
}

/**
 * 计划写操作的结果：ok 说的是"本地计划这件事实有没有改成"，
 * calendarState 说的是"系统日历那份投影跟上了没有"——两件事必须分开报，
 * 否则改期成功但日历没写成时，UI 只能谎报失败、诱使用户再点一次。
 */
export interface PlanOpResult {
  ok: boolean;
  calendarState: string;
  /** 失败原因文案；ok 为真时是空串。 */
  error: string;
}

/** 计划卡片的日历徽标：'' = 已在系统日历里，无需提示。 */
export function calendarBadgeOf(calendarState: string): string {
  if (calendarState === CalendarState.WRITTEN) {
    return '';
  }
  if (calendarState === CalendarState.UNSUPPORTED) {
    return '这台设备没有可用日历';
  }
  return LOCAL_ONLY_NOTE;
}

/**
 * 是否给出"写入日历"重试入口：设备压根没有日历能力时不给出（点了也不会成，只是打扰）。
 * PENDING 也放行——崩溃/杀进程会把计划留在"等确认"这一格，没有重试入口就永久卡住。
 *
 * FeatureFlags.calendarFlow 关闭时一律不给：回退档必须让入口和链路一起退场，
 * 留一个点了不会写进日历的按钮，比没有按钮更糟（docs/release/rollout-and-rollback.md）。
 */
export function canRetryCalendarSync(calendarState: string): boolean {
  if (!FeatureFlags.calendarFlow) {
    return false;
  }
  return calendarState === CalendarState.FAILED
    || calendarState === CalendarState.LOCAL_ONLY
    || calendarState === CalendarState.NOT_REQUESTED
    || calendarState === CalendarState.PENDING;
}

/**
 * 提交闩：重复点击/手势重入时只允许第一次通过。
 * 释放只在真正结束（成功或失败）后发生；异常路径由调用方 finally 兜底，否则会把按钮锁死。
 */
export class SubmitLatch {
  private busy: boolean = false;

  tryBegin(): boolean {
    if (this.busy) {
      return false;
    }
    this.busy = true;
    return true;
  }

  release(): void {
    this.busy = false;
  }

  isBusy(): boolean {
    return this.busy;
  }
}
