/**
 * 计划流程的纯口径（阶段 2 Task 2.2，阶段 6R.1 重划日历生命周期）：
 * 窗口校验、默认草稿、日历状态机、投影清理报告、提交闩。
 *
 * 这里不碰任何 @kit/RDB：设备侧只把 Calendar Kit 的结果归一成 CalendarOutcome，
 * "取消/拒绝时保留哪一份事实"这类判断留在这里，离线单测（tools/test/run.mjs）直接跑本文件。
 * 唯一的例外是 FeatureFlags：它是编译期常量而不是运行时依赖，读它不引入设备能力。
 */
import { FeatureFlags } from '../config/FeatureFlags';

/** Calendar Kit 归一后的能力结果；PlanUseCase 不直接看系统错误码。 */
export enum CalendarOutcome {
  /** 写入应用专属「同休日」日历（本应用改得动、删得掉）。 */
  WRITTEN = 'WRITTEN',
  /** editEvent 导出成功：日程交给系统日历管理，普通权限下本应用后续动不了它。 */
  EXPORTED = 'EXPORTED',
  /** 系统日程编辑页被用户取消（返回 id < 0）。 */
  CANCELED = 'CANCELED',
  /** 读写日历权限未授予。 */
  DENIED = 'DENIED',
  /** 设备没有可用日历账户/能力。 */
  UNAVAILABLE = 'UNAVAILABLE',
  /** 调用抛错（日历应用异常等）。 */
  FAILED = 'FAILED'
}

/** 删除日程的归一结果：不用布尔，因为"没删掉"必须能分成可重试与已消失两种说法。 */
export enum RemoveOutcome {
  /** 日程已不在系统日历里（删除成功，或那条本来就没有）。 */
  REMOVED = 'REMOVED',
  /** 删不动（权限被撤回/设备异常）：event id 原样留着，稍后仍可重试。 */
  FAILED = 'FAILED'
}

/**
 * plan.calendar_state 取值（DDL 默认 NOT_REQUESTED）。
 *
 * 生命周期里"日历上有没有东西"和"东西归谁管"是两件事，所以既不是布尔也不是一个 WRITTEN：
 * NOT_REQUESTED/PENDING/LOCAL_ONLY/UNSUPPORTED/FAILED 描述"没写成"的几种原因，
 * MANAGED_WRITTEN / EXTERNAL_UNMANAGED / CLEANUP_PENDING 描述写成了之后归谁管、能不能自动同步。
 */
export enum CalendarState {
  /** 尚未请求过日历。 */
  NOT_REQUESTED = 'NOT_REQUESTED',
  /** 本地计划已落库，正在等日历写入。 */
  PENDING = 'PENDING',
  /** 已写入应用专属「同休日」日历：改期与取消可以由本应用自动完成。 */
  MANAGED_WRITTEN = 'MANAGED_WRITTEN',
  /** 经 editEvent 导出：日程由系统日历管理，本应用不承诺自动删除/改期。 */
  EXTERNAL_UNMANAGED = 'EXTERNAL_UNMANAGED',
  /** 本机计划已处理，但日历日程或提醒没清掉、留着可重试的信息。 */
  CLEANUP_PENDING = 'CLEANUP_PENDING',
  /** 仅保存在应用内（取消/无权限/不可用）。 */
  LOCAL_ONLY = 'LOCAL_ONLY',
  /** 设备不支持日历能力。 */
  UNSUPPORTED = 'UNSUPPORTED',
  /** 写入失败，可稍后重试。 */
  FAILED = 'FAILED'
}

/** 日历没写成时的统一口径：计划本身仍然成立，只是没进系统日历。 */
export const LOCAL_ONLY_NOTE = '仅保存在应用内';

/** 本机已处理、系统侧还留着东西的口径：不能对用户说"已取消/已清空"就当什么都没剩。 */
export const CLEANUP_NOTE = '系统日历或提醒仍待清理';

/**
 * 读库取值归一。
 *
 * 阶段 2 的旧实现把 editEvent 确认与直写都记成 'WRITTEN'，而普通权限下只有直写进应用专属
 * 日历的那份删得动——两者已无法区分，一律按 EXTERNAL_UNMANAGED 保守处理：
 * 宁可提示"请在系统日历里删除"，也不能把删不掉的日程标成"本应用会替你删"。
 * 认不出的值（含空串/旧版本写的任意串）回到 NOT_REQUESTED，按"日历上没有它的痕迹"处理。
 */
export function normalizeCalendarState(raw: string): string {
  if (raw === 'WRITTEN') {
    return CalendarState.EXTERNAL_UNMANAGED;
  }
  if (raw === CalendarState.NOT_REQUESTED || raw === CalendarState.PENDING
    || raw === CalendarState.MANAGED_WRITTEN || raw === CalendarState.EXTERNAL_UNMANAGED
    || raw === CalendarState.CLEANUP_PENDING || raw === CalendarState.LOCAL_ONLY
    || raw === CalendarState.UNSUPPORTED || raw === CalendarState.FAILED) {
    return raw;
  }
  return CalendarState.NOT_REQUESTED;
}

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

/** 一次日历写入的归一结果：eventId 仅在 WRITTEN（受管）/ EXPORTED（导出）时有值。 */
export interface CalendarWriteResult {
  outcome: CalendarOutcome;
  eventId: string;
}

/**
 * 计划编排要用的系统能力端口（阶段 2 Task 2.2，阶段 6R.1 按权限边界重划分）。
 *
 * 设备侧的真实现是 CalendarGateway / ReminderGateway 的静态门面；把它们收成端口，
 * 是因为"用户点了取消""权限被拒""日程删不动"这类分支在真机上不可复现，
 * 而它们恰恰决定了本地计划该不该保留——不能只靠人肉验收。
 */
export interface CalendarCapability {
  /** 受管写入：写进应用专属「同休日」日历，返回的 eventId 之后可改可删。 */
  write(title: string, startMin: number, endMin: number): Promise<CalendarWriteResult>;

  /** 导出：打开系统日程编辑页由用户当面确认，之后日程归系统日历管（本应用删不动）。 */
  exportToSystem(title: string, startMin: number, endMin: number): Promise<CalendarWriteResult>;

  /** 删除日程：结构化结果，删不动时调用方必须留着 event id 重试，不得当作已清理。 */
  remove(eventId: string): Promise<RemoveOutcome>;

  /** 整本删掉应用专属日历（全量清空用）：true = 已删除，false = 没删成，要如实报告。 */
  purgeManagedCalendar(): Promise<boolean>;
}

export interface ReminderCapability {
  /** 返回 reminderId，<0 = 未注册（通知未开启或发布失败），调用方不阻塞计划。 */
  publish(title: string, startMin: number): Promise<number>;

  /** 取消提醒：true = 已取消或本来就没有；false = 没取消掉，句柄要留着重试。 */
  cancel(reminderId: number): Promise<boolean>;
}

/**
 * 一次投影清理（日历日程 + 提醒）的结构化结果。
 *
 * 三个日程计数按"这条日程现在归谁"互斥划分：删掉了 / 删不动可重试 / 由系统日历管理只能手动删。
 * 取消、改期、清空都返回它，UI 据此决定能说"已取消"还是必须说"仍待清理"。
 */
export interface CleanupReport {
  /** 已确认不在系统日历里的日程数（删除成功，或本来就没有）。 */
  eventsRemoved: number;
  /** 删不动、event id 仍留在计划行里可重试的日程数。 */
  eventsPending: number;
  /** 由系统日历管理、本应用不代删的日程数（editEvent 导出的那批）。 */
  eventsExternal: number;
  /** 已取消的提醒数。 */
  remindersRemoved: number;
  /** 取消失败、reminder_id 仍留在计划行里可重试的提醒数。 */
  remindersPending: number;
}

export function emptyCleanupReport(): CleanupReport {
  const r: CleanupReport = {
    eventsRemoved: 0, eventsPending: 0, eventsExternal: 0, remindersRemoved: 0, remindersPending: 0
  };
  return r;
}

/** 把一次清理的结果并进累计结果（批量取消/清空共用一份报告口径）。 */
export function addCleanupReport(total: CleanupReport, part: CleanupReport): void {
  total.eventsRemoved += part.eventsRemoved;
  total.eventsPending += part.eventsPending;
  total.eventsExternal += part.eventsExternal;
  total.remindersRemoved += part.remindersRemoved;
  total.remindersPending += part.remindersPending;
}

/** 系统侧还有没有留下的东西（删不掉的、只能手动删的都算）。 */
export function hasCleanupLeft(report: CleanupReport): boolean {
  return report.eventsPending > 0 || report.remindersPending > 0 || report.eventsExternal > 0;
}

/**
 * 给用户的一句话口径：本机的事已经办完，系统侧还剩什么、要不要他动手。
 * 全清干净时返回空串（调用方按"成功"播报）。
 */
export function cleanupMessageOf(report: CleanupReport): string {
  if (!hasCleanupLeft(report)) {
    return '';
  }
  const parts: string[] = [];
  if (report.eventsPending > 0 || report.remindersPending > 0) {
    parts.push((report.eventsPending + report.remindersPending) + ' 项日历/提醒没清掉，可稍后重试');
  }
  if (report.eventsExternal > 0) {
    parts.push(report.eventsExternal + ' 条导出的日程由系统日历管理，请到系统日历里删除');
  }
  return parts.join('；');
}

/**
 * 「清空我的全部数据」之后给用户的一句话。
 *
 * 本机表清空了是事实，但系统侧还剩的东西一句都不能漏——把"删了本地行"说成"系统日历与提醒
 * 也干净了"是这份验收报告点名的谎报（docs/validation/2026-09-23-full-redesign-acceptance.md）。
 *
 * 这里**不复用** `cleanupMessageOf`：那句"可稍后重试"靠的是计划行里留下的句柄，
 * 而清空动作把计划行连同句柄一起删了，重试的凭据在这一步之后就不存在了。
 * 剩下只能让人自己去系统侧检查（最终验收 R2）。
 */
export function clearAllMessageOf(report: CleanupReport, calendarPurged: boolean): string {
  const parts: string[] = ['已清空本机全部数据'];
  const left = report.eventsPending + report.remindersPending;
  if (left > 0) {
    parts.push(left + ' 项系统日历/提醒可能仍在，本应用已无法再替你清理，请到系统日历/系统设置检查');
  }
  if (report.eventsExternal > 0) {
    parts.push(report.eventsExternal + ' 条导出的日程由系统日历管理，请到系统日历里删除');
  }
  if (!calendarPurged) {
    parts.push('「同休日」日历没有清空，请到系统日历里检查');
  }
  return parts.join('；');
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
    return CalendarState.MANAGED_WRITTEN;
  }
  if (outcome === CalendarOutcome.EXPORTED) {
    return CalendarState.EXTERNAL_UNMANAGED;
  }
  if (outcome === CalendarOutcome.DENIED || outcome === CalendarOutcome.CANCELED) {
    return CalendarState.LOCAL_ONLY;
  }
  if (outcome === CalendarOutcome.UNAVAILABLE) {
    return CalendarState.UNSUPPORTED;
  }
  return CalendarState.FAILED;
}

/** 系统日历里确有这条日程（不管归谁管）；false = 只在应用内，UI 必须说清楚。 */
export function isOnSystemCalendar(calendarState: string): boolean {
  const s = normalizeCalendarState(calendarState);
  return s === CalendarState.MANAGED_WRITTEN || s === CalendarState.EXTERNAL_UNMANAGED;
}

/**
 * 本机事实已经改成之后，日历状态该落到哪一格（取消、改期、重试共用这一条判断）。
 *
 * - 有删不掉的日程/提醒 → CLEANUP_PENDING：id 与句柄必须留在计划行里，这是唯一还能重试的理由；
 * - 只剩"由系统日历管理"的那类 → EXTERNAL_UNMANAGED：应用不会再动它，留着标记免得谎报干净；
 * - 全清干净 → 回调用方给的目标态（取消给 LOCAL_ONLY，改期给新写入的结果）。
 */
export function calendarStateAfterCleanup(report: CleanupReport, cleanState: string): string {
  if (report.eventsPending > 0 || report.remindersPending > 0) {
    return CalendarState.CLEANUP_PENDING;
  }
  if (report.eventsExternal > 0) {
    return CalendarState.EXTERNAL_UNMANAGED;
  }
  return cleanState;
}

/**
 * 本应用能不能自动改这条日程。
 *
 * 只有写进应用专属「同休日」日历的那份能：editEvent 交出去的日程按 SDK 口径要
 * READ/WRITE_WHOLE_CALENDAR（system_basic）才动得了，普通应用拿不到（本机 SDK 26
 * @ohos.calendarManager.d.ts 的 editEvent 说明），所以绝不能对它承诺自动同步。
 */
export function isAppManagedEvent(calendarState: string): boolean {
  return normalizeCalendarState(calendarState) === CalendarState.MANAGED_WRITTEN;
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
  /** 本机已改成、系统侧还留着东西时的说明（'' = 系统侧也干净了）。 */
  cleanupNote: string;
}

/** 计划卡片的日历徽标：'' = 日程在系统日历里且由本应用管理，无需提示。 */
export function calendarBadgeOf(calendarState: string): string {
  const s = normalizeCalendarState(calendarState);
  if (s === CalendarState.MANAGED_WRITTEN) {
    return '';
  }
  if (s === CalendarState.EXTERNAL_UNMANAGED) {
    return '已在系统日历，之后由系统日历管理';
  }
  if (s === CalendarState.CLEANUP_PENDING) {
    return CLEANUP_NOTE;
  }
  if (s === CalendarState.UNSUPPORTED) {
    return '这台设备没有可用日历';
  }
  return LOCAL_ONLY_NOTE;
}

/**
 * 是否给出"写入日历"重试入口：设备压根没有日历能力时不给出（点了也不会成，只是打扰）。
 * PENDING 也放行——崩溃/杀进程会把计划留在"等写入"这一格，没有重试入口就永久卡住。
 *
 * CLEANUP_PENDING 不在内：那一格是"旧日程还挂在系统里删不动"，这时补写等于在同一天放两条日程。
 * 它自己的出口是「重新清理」（canRetryCleanup），清干净后由 PlanUseCase.retryProjection 补写。
 *
 * FeatureFlags.calendarFlow 关闭时一律不给：回退档必须让入口和链路一起退场，
 * 留一个点了不会写进日历的按钮，比没有按钮更糟（docs/release/rollout-and-rollback.md）。
 */
export function canRetryCalendarSync(calendarState: string): boolean {
  if (!FeatureFlags.calendarFlow) {
    return false;
  }
  const s = normalizeCalendarState(calendarState);
  return s === CalendarState.FAILED
    || s === CalendarState.LOCAL_ONLY
    || s === CalendarState.NOT_REQUESTED
    || s === CalendarState.PENDING;
}

/**
 * 「导出到系统日历」入口：只在日历上确实还没有它、也没挂着待清理时给。
 * 放行为 CLEANUP_PENDING/PENDING 就等于允许在旧日程旁边再放一条，那是重复日程不是重试。
 */
export function canExportToCalendar(calendarState: string): boolean {
  if (!FeatureFlags.calendarFlow) {
    return false;
  }
  const s = normalizeCalendarState(calendarState);
  return s === CalendarState.FAILED
    || s === CalendarState.LOCAL_ONLY
    || s === CalendarState.NOT_REQUESTED;
}

/** 待清理重试入口：状态是 CLEANUP_PENDING 就一直在（权限撤回后重新授权即可清掉）。 */
export function canRetryCleanup(calendarState: string): boolean {
  return normalizeCalendarState(calendarState) === CalendarState.CLEANUP_PENDING;
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
