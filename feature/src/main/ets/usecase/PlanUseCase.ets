import { PlanRow, ScheduleRepo } from 'data';
import { decodeConflictHint, encodeConflictHint } from 'domain';
import { Logger } from 'commons';
import { ScheduleUseCase } from './ScheduleUseCase';
import { PlanProjectionCleanupService } from './PlanProjectionCleanupService';
import { FeatureFlags } from '../config/FeatureFlags';
import { PlanCapabilities } from '../integration/PlanCapabilities';
import {
  CalendarOutcome, CalendarState, CalendarWriteResult, CleanupReport, MIN_PLAN_MIN, PlanDraft,
  PlanOpResult, SubmitLatch, addCleanupReport, canExportToCalendar, calendarStateAfterCleanup,
  calendarStateOf, cleanupMessageOf, emptyCleanupReport, hasCleanupLeft, isOnSystemCalendar,
  newPlanId, planDraftError
} from '../model/PlanFlow';

/** 创建计划结果。 */
export interface CreatePlanResult {
  ok: boolean;
  planId: string;
  /** 落库后的 plan.calendar_state：非 MANAGED_WRITTEN 都意味着"日历那份没由本应用管着"。 */
  calendarState: string;
  error: string;
}

/** 创建计划的可选项。 */
export interface CreatePlanOptions {
  /**
   * 是否把计划写进应用专属「同休日」日历（受管写入：之后改期/取消由本应用自动同步）。
   * 默认 true；关掉就是"只留在应用里"，日历上一次都不请求。
   */
  writeToCalendar: boolean;
}

/** 一次重试的结果：落库后的状态 + 本次清理报告（播报口径由 UI 决定）。 */
interface RetryOutcome {
  calendarState: string;
  report: CleanupReport;
}

const TAG = 'PlanUseCase';

/** 计划状态：冲突（与 ScheduleUseCase.detectAndWriteConflicts 写入值一致）。 */
const STATUS_CONFLICT = 'CONFLICT';

/** 计划状态：已取消（取消后不再是活动计划，但残留句柄还得由清扫补删）。 */
const STATUS_CANCELLED = 'CANCELLED';

/** 计划创建闩：重复点击/手势重入时只放行第一次，避免同一条计划落两遍。 */
const CREATE_LATCH = new SubmitLatch();

/** 清理之后仍然卡在系统侧的说法（本机已经改完，只是投影没跟上）。 */
const CLEANUP_RETRY_ERROR = '系统侧还没清干净，可以稍后再试一次';

/**
 * 共同计划用例（US5 / FR-009 / FR-017 / FR-014，阶段 6R.1 按权限边界重做日历生命周期）——
 * 只做业务编排，不碰 @kit：
 * - createPlan：校验（PlanFlow 纯口径）→ 先写本地计划（calendar_state=PENDING）
 *   → 受管写入应用专属日历 → 回写 calendar_state → 注册提醒 → 一次重算；
 * - 日历没写成时本地计划照常保留，由 UI 显示"仅保存在应用内"；
 * - cancelPlan / acceptAlternative / retryProjection：**先清旧投影，再写新投影**。
 *   旧日程删不掉时绝不补写新的（那是同一天两条日程，不是改期），而是把句柄原样留在计划行里
 *   标成 CLEANUP_PENDING——留着才可能重试，静默清空就是把孤儿永远留给系统日历（验收报告 B2）。
 * - exportToCalendar：editEvent 那条路径只是"导出"，日程之后归系统日历，本应用不再自动同步它，
 *   所以日历上已经有它的痕迹时不给导出入口（否则会拿受管日程换一个删不掉的）。
 * - 取消/改期的确认弹窗由 UI 层完成，本层不弹窗。
 *
 * 系统能力走 PlanCapabilities 的端口（投影清理由 PlanProjectionCleanupService 共用同一份），
 * 单测注入确定性实现，好让"用户取消/权限拒绝/日程删不动"这些真机不可复现的分支也能被断言。
 */
export class PlanUseCase {
  /** 默认选项：写系统日历（受管）。 */
  static defaultOptions(): CreatePlanOptions {
    return { writeToCalendar: true };
  }

  /**
   * 创建共同计划：
   * 1) 草稿校验（标题、起止、必须完全落在窗口内）——非法不写库也不重算；
   * 2) 本地计划先落库（status=OK，calendar_state=PENDING）：计划是本机事实，
   *    系统日历只是它的一份投影，投影失败不该让计划消失；
   * 3) 默认受管写入应用专属日历；显式关掉「写入系统日历」时一次日历请求都不发；
   * 4) 写入结果写回 calendar_state，提醒尽力注册，全程只触发一次重算。
   */
  static async createPlan(winStart: number, winEnd: number, title: string, kind: string,
    startMin: number, endMin: number, opts?: CreatePlanOptions): Promise<CreatePlanResult> {
    const draft: PlanDraft = { title: title, kind: kind, start: startMin, end: endMin };
    const invalid = planDraftError(draft, winStart, winEnd);
    if (invalid !== '') {
      return PlanUseCase.fail(invalid);
    }
    if (!CREATE_LATCH.tryBegin()) {
      return PlanUseCase.fail('正在创建，请稍候');
    }
    try {
      const options: CreatePlanOptions = opts == null ? PlanUseCase.defaultOptions() : opts;
      const planId = newPlanId();
      const winRef: Record<string, number> = { 's': winStart, 'e': winEnd };
      const row: PlanRow = {
        id: planId,
        title: title.trim(),
        kind: kind,
        start: startMin,
        end: endMin,
        status: 'OK',
        createdBy: 'ME',
        windowRef: JSON.stringify(winRef),
        conflictHint: '',
        myEventId: '',
        reminderId: -1,
        updatedAt: 0,
        calendarState: CalendarState.PENDING,
        syncState: 'LOCAL_ONLY'
      };
      await ScheduleRepo.upsertPlan(row);
      let state: string = CalendarState.NOT_REQUESTED;
      if (options.writeToCalendar) {
        state = await PlanUseCase.writeManaged(planId, row.title, startMin, endMin);
      } else {
        // 用户自己选了"只留在应用里"：从没请求过日历，跟"请求了但没写成"不是一回事
        await ScheduleRepo.updatePlanCalendar(planId, CalendarState.NOT_REQUESTED, '');
      }
      await PlanUseCase.publishReminder(planId, row.title, startMin);
      await ScheduleUseCase.onScheduleChanged();
      Logger.info(TAG, 'plan created id=' + planId + ' calendar=' + state);
      return { ok: true, planId: planId, calendarState: state, error: '' };
    } catch (e) {
      Logger.warn(TAG, 'createPlan failed: ' + (e as Error).message);
      return PlanUseCase.fail('创建失败，请重试');
    } finally {
      CREATE_LATCH.release();
    }
  }

  /**
   * 取消计划（确认弹窗由 UI 层负责）：
   * 先清系统侧投影（日程 + 提醒），再把本机事实标成 CANCELLED，最后落一次投影回写。
   * 顺序不能反：清完再改状态，才会把"删不动"的句柄留在还看得见的行里；
   * 反过来一标 CANCELLED，列表就不返回它了，那个孤儿再也没人重试。
   *
   * 本机事实一定改成（清理失败不回滚取消），残留部分如实写进 cleanupNote 交给 UI 播报。
   */
  static async cancelPlan(id: string): Promise<PlanOpResult> {
    const row = await PlanUseCase.findPlan(id);
    if (row == null) {
      return { ok: false, calendarState: CalendarState.NOT_REQUESTED, error: '计划已不存在', cleanupNote: '' };
    }
    const report = await PlanProjectionCleanupService.cleanupPlan(row);
    let state: string = CalendarState.LOCAL_ONLY;
    try {
      await ScheduleRepo.updatePlanStatus(id, STATUS_CANCELLED);
      state = await PlanUseCase.persistCleanup(row, report, CalendarState.LOCAL_ONLY);
    } catch (e) {
      Logger.warn(TAG, 'cancelPlan persist failed: ' + (e as Error).message);
      return {
        ok: false, calendarState: row.calendarState,
        error: '取消失败，计划仍在列表里', cleanupNote: cleanupMessageOf(report)
      };
    }
    await PlanUseCase.recomputeQuietly();
    return {
      ok: true, calendarState: state, error: '',
      cleanupNote: cleanupMessageOf(report)
    };
  }

  /**
   * 采用替代时间（冲突动作一 / L11 G1）：
   * 计划时长不变、起点对齐替代窗口起点（替代窗口由冲突检测保证时长足够，越界时收缩兜底）；
   * 本地计划先改到新时间，再清旧投影——
   * 旧日程/旧提醒没清掉时**不补写新投影**，计划留在新时间 + CLEANUP_PENDING，由重试入口或
   * 启动清扫补完；清干净了才按新时间受管写入并挪提醒。
   * 任何一支都不把计划拉回原时间（本机事实已经改成，回滚只会让用户再点一次）。
   * 替代窗口信息缺失/非法（已被新一次重算覆盖）时 ok=false，UI 提示重选窗口。
   */
  static async acceptAlternative(id: string): Promise<PlanOpResult> {
    const row = await PlanUseCase.findPlan(id);
    const hint = row != null ? decodeConflictHint(row.conflictHint) : null;
    if (row == null || row.status !== STATUS_CONFLICT || hint == null
      || !(hint.altStartMin > 0 && hint.altEndMin > hint.altStartMin)) {
      return {
        ok: false, calendarState: CalendarState.NOT_REQUESTED,
        error: '替代窗口已失效，请重新选择时间', cleanupNote: ''
      };
    }
    const newStart = hint.altStartMin;
    const newEnd = Math.min(newStart + (row.end - row.start), hint.altEndMin);
    if (newEnd - newStart < MIN_PLAN_MIN) {
      return {
        ok: false, calendarState: CalendarState.NOT_REQUESTED,
        error: '替代窗口太短，请重新选择时间', cleanupNote: ''
      };
    }
    try {
      await ScheduleRepo.updatePlanTime(id, newStart, newEnd);
    } catch (e) {
      Logger.warn(TAG, 'reschedule persist failed: ' + (e as Error).message);
      return {
        ok: false, calendarState: row.calendarState,
        error: '改期失败，计划仍在原时间', cleanupNote: ''
      };
    }
    // 到这里本地计划已经是新时间：后面的日历与提醒只做投影，失败都不把计划拉回去
    const report = await PlanProjectionCleanupService.cleanupPlan(row);
    let state: string = CalendarState.LOCAL_ONLY;
    if (hasCleanupLeft(report)) {
      state = await PlanUseCase.persistCleanup(row, report, CalendarState.LOCAL_ONLY);
      Logger.info(TAG, 'reschedule blocked by undeletable projection: id=' + id);
    } else {
      state = await PlanUseCase.writeManaged(id, row.title, newStart, newEnd);
      await PlanUseCase.publishReminder(id, row.title, newStart);
    }
    await PlanUseCase.recomputeQuietly();
    Logger.info(TAG, 'plan rescheduled to alternative: id=' + id + ' calendar=' + state);
    return { ok: true, calendarState: state, error: '', cleanupNote: cleanupMessageOf(report) };
  }

  /**
   * 把"仅保存在应用内"的计划补写到系统日历（创建/改期时没写成的重试入口）。
   * ok 说的是日历这次有没有写成；本地计划内容一个字都不改，所以不触发重算。
   */
  static async syncToCalendar(id: string): Promise<PlanOpResult> {
    const row = await PlanUseCase.findPlan(id);
    if (row == null) {
      return { ok: false, calendarState: CalendarState.NOT_REQUESTED, error: '计划已不存在', cleanupNote: '' };
    }
    const state = await PlanUseCase.writeManaged(id, row.title, row.start, row.end);
    const written = isOnSystemCalendar(state);
    return {
      ok: written, calendarState: state,
      error: written ? '' : '日历仍未写入，稍后可以再试一次', cleanupNote: ''
    };
  }

  /**
   * 导出到系统日历（editEvent，验收报告 B0 的降级出口）：
   * 用户在系统日程编辑页当面保存，日程之后由系统日历管理——本应用改不动也删不掉它。
   * 所以这里只在"日历上还没有它、也没挂着待清理句柄"时放行（canExportToCalendar）：
   * 已经有一条受管日程时再导出，等于拿能管的换一条不能管的，正是本次要修的孤儿来源。
   */
  static async exportToCalendar(id: string): Promise<PlanOpResult> {
    const row = await PlanUseCase.findPlan(id);
    if (row == null) {
      return { ok: false, calendarState: CalendarState.NOT_REQUESTED, error: '计划已不存在', cleanupNote: '' };
    }
    if (!canExportToCalendar(row.calendarState)) {
      return {
        ok: false, calendarState: row.calendarState,
        error: '这条计划已经在系统日历里了', cleanupNote: ''
      };
    }
    let result: CalendarWriteResult = { outcome: CalendarOutcome.FAILED, eventId: '' };
    try {
      result = await PlanCapabilities.calendar().exportToSystem(row.title, row.start, row.end);
    } catch (e) {
      Logger.warn(TAG, 'export threw: ' + (e as Error).message);
    }
    const state = await PlanUseCase.persistWrite(id, result);
    const exported = result.outcome === CalendarOutcome.EXPORTED;
    return {
      ok: exported, calendarState: state,
      error: exported ? '' : '没有导出到系统日历，稍后可以再试一次',
      cleanupNote: exported ? '日程已交给系统日历，之后请在系统日历里修改或删除' : ''
    };
  }

  /**
   * 重试系统侧清理（UI 的「重新清理」入口）：清旧句柄 → 清干净了再补写新投影。
   * ok 说的是"系统侧还剩没剩东西"，不是本机事实——那条早就改成用户要的样子了。
   */
  static async retryProjection(id: string): Promise<PlanOpResult> {
    const rows = await ScheduleRepo.listOrphanProjectionPlans();
    for (let i = 0; i < rows.length; i++) {
      if (rows[i].id === id) {
        const out = await PlanUseCase.retryProjectionOf(rows[i]);
        const clean = !hasCleanupLeft(out.report);
        return {
          ok: clean, calendarState: out.calendarState,
          error: clean ? '' : CLEANUP_RETRY_ERROR, cleanupNote: cleanupMessageOf(out.report)
        };
      }
    }
    return {
      ok: true, calendarState: CalendarState.NOT_REQUESTED,
      error: '', cleanupNote: '没有待清理的系统日程或提醒'
    };
  }

  /**
   * 保留原计划（冲突动作三）：冲突事实和状态都留着，只是不再催用户改期。
   * 标记写进 conflict_hint，由重算在同一冲突签名（原因 + 受影响区间）下结转；
   * 日程再变动就是新冲突，提示会重新出现。不触发重算——没有任何时间事实发生变化。
   */
  static async keepOriginalPlan(id: string): Promise<boolean> {
    const row = await PlanUseCase.findPlan(id);
    const hint = row != null ? decodeConflictHint(row.conflictHint) : null;
    if (row == null || hint == null) {
      return false;
    }
    if (!hint.kept) {
      hint.kept = true;
      await ScheduleRepo.updatePlanConflict(id, row.status, encodeConflictHint(hint));
    }
    Logger.info(TAG, 'plan kept despite conflict: id=' + id);
    return true;
  }

  /**
   * 清扫带残留句柄的计划（EntryAbility 回前台时调用，不阻塞界面）。
   *
   * 为什么需要它：取消时删不动的日程只留在 CANCELLED 行里，计划列表根本不显示它，
   * 于是"稍后重试"是一句没有主语的话——没人会再点，权限恢复后也没人去清。
   * 这一趟把那种行重新走一遍清理，才是 B2 真正的收尾。返回 null = 没有需要清理的行。
   */
  static async sweepPendingProjections(): Promise<CleanupReport | null> {
    let rows: PlanRow[] = [];
    try {
      rows = await ScheduleRepo.listOrphanProjectionPlans();
    } catch (e) {
      Logger.warn(TAG, 'sweep skipped: ' + (e as Error).message);
      return null;
    }
    if (rows.length === 0) {
      return null;
    }
    const total = emptyCleanupReport();
    for (let i = 0; i < rows.length; i++) {
      addCleanupReport(total, (await PlanUseCase.retryProjectionOf(rows[i])).report);
    }
    Logger.info(TAG, 'projection sweep done: removed=' + total.eventsRemoved
      + ' pending=' + total.eventsPending + ' external=' + total.eventsExternal);
    return total;
  }

  /** 按 id 取活动计划（CANCELLED 不在内：它已经不在用户的列表里了）。 */
  private static async findPlan(id: string): Promise<PlanRow | null> {
    const rows = await ScheduleRepo.listActivePlans();
    for (let i = 0; i < rows.length; i++) {
      if (rows[i].id === id) {
        return rows[i];
      }
    }
    return null;
  }

  /**
   * 单行的重试：清旧句柄 → 清干净了才补写新投影（已取消的计划不补写，它要的就是消失）。
   * 时间事实一律不动，所以调用方不需要重算。
   */
  private static async retryProjectionOf(row: PlanRow): Promise<RetryOutcome> {
    const report = await PlanProjectionCleanupService.cleanupPlan(row);
    const cleanState = row.status === STATUS_CANCELLED ? CalendarState.LOCAL_ONLY : CalendarState.NOT_REQUESTED;
    let state = await PlanUseCase.persistCleanup(row, report, cleanState);
    if (!hasCleanupLeft(report) && row.status !== STATUS_CANCELLED && !isOnSystemCalendar(state)) {
      state = await PlanUseCase.writeManaged(row.id, row.title, row.start, row.end);
      await PlanUseCase.publishReminder(row.id, row.title, row.start);
    }
    const out: RetryOutcome = { calendarState: state, report: report };
    return out;
  }

  /**
   * 受管写入（应用专属「同休日」日历）并回写状态；结果归一见 calendarStateOf。
   *
   * FeatureFlags.calendarFlow 关闭时这里就是回退点：一条日历调用都不发，状态归一成
   * NOT_REQUESTED（"从没请求过日历"，与"请求了但没写成"是两件事），my_event_id 留空。
   * 取消/清理路径不受本档影响——开档时写进去的日程，关档后照样清得掉，不留没人认领的孤儿。
   */
  private static async writeManaged(id: string, title: string, startMin: number,
    endMin: number): Promise<string> {
    if (!FeatureFlags.calendarFlow) {
      await ScheduleRepo.updatePlanCalendar(id, CalendarState.NOT_REQUESTED, '');
      Logger.info(TAG, 'calendar flow off, plan stays local only id=' + id);
      return CalendarState.NOT_REQUESTED;
    }
    const result = await PlanCapabilities.writeManaged(title, startMin, endMin);
    return PlanUseCase.persistWrite(id, result);
  }

  /**
   * 写入结果落库。
   * 只有确实存在日程的两条路径留 event id：受管那条（之后要能改删）与导出的那条
   * （改删不了，但取消时要如实告诉用户"系统日历里还有一条要你手动删"）；
   * 其余结果一律留空串，否则重试会拿着不存在的 id 去删日历。
   */
  private static async persistWrite(id: string, result: CalendarWriteResult): Promise<string> {
    const state = calendarStateOf(result.outcome);
    const hasEvent = result.outcome === CalendarOutcome.WRITTEN || result.outcome === CalendarOutcome.EXPORTED;
    await ScheduleRepo.updatePlanCalendar(id, state, hasEvent ? result.eventId : '');
    return state;
  }

  /**
   * 清理结果落库：删得动的句柄清空，删不动的原样留着（这是唯一还能重试的理由）。
   * 返回落库后的 calendar_state。
   */
  private static async persistCleanup(row: PlanRow, report: CleanupReport,
    cleanState: string): Promise<string> {
    const state = calendarStateAfterCleanup(report, cleanState);
    await ScheduleRepo.updatePlanProjection(row.id, state,
      report.eventsPending > 0 ? row.myEventId : '',
      report.remindersPending > 0 ? row.reminderId : -1);
    return state;
  }

  /** 本地提醒（US8 / FR-014）：任何失败都静默降级，绝不阻塞计划本身。
   * 要不要注册由 NotificationGateway 的"精确提醒"开关决定，这里不问策略，只管回写 id。 */
  private static async publishReminder(id: string, title: string, startMin: number): Promise<void> {
    try {
      const reminderId = await PlanCapabilities.reminder().publish(title, startMin);
      if (reminderId >= 0) {
        await ScheduleRepo.updatePlanReminder(id, reminderId);
      }
    } catch (e) {
      Logger.warn(TAG, 'reminder publish failed: ' + (e as Error).message);
    }
  }

  /**
   * 重算失败只记日志：计划已经落库，重算慢一拍会让列表短暂陈旧，
   * 但把"保存失败"喊给用户只会换来一次重复提交。
   */
  private static async recomputeQuietly(): Promise<void> {
    try {
      await ScheduleUseCase.onScheduleChanged();
    } catch (e) {
      Logger.warn(TAG, 'recompute after plan change failed: ' + (e as Error).message);
    }
  }

  private static fail(msg: string): CreatePlanResult {
    return { ok: false, planId: '', calendarState: CalendarState.NOT_REQUESTED, error: msg };
  }
}
