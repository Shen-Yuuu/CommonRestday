import { PlanRow, ScheduleRepo } from 'data';
import { decodeConflictHint, encodeConflictHint } from 'domain';
import { Logger } from 'commons';
import { ScheduleUseCase } from './ScheduleUseCase';
import { CalendarGateway } from '../integration/CalendarGateway';
import { ReminderGateway } from '../integration/ReminderGateway';
import {
  CalendarCapability, CalendarOutcome, CalendarState, CalendarWriteResult, MIN_PLAN_MIN, PlanDraft,
  PlanOpResult, ReminderCapability, SubmitLatch, calendarStateOf, isOnSystemCalendar, newPlanId,
  planDraftError
} from '../model/PlanFlow';

/** 创建计划结果。 */
export interface CreatePlanResult {
  ok: boolean;
  planId: string;
  /** 落库后的 plan.calendar_state：非 WRITTEN 都意味着"仅保存在应用内"。 */
  calendarState: string;
  error: string;
}

/** 创建计划的可选项。 */
export interface CreatePlanOptions {
  /**
   * 高级选项：跳过系统日历确认，直接 addEvent。
   * 默认 false——写别人也会看到的日历，理当由用户当面点一次"保存"。
   */
  directCalendarWrite: boolean;
}

const TAG = 'PlanUseCase';

/** 计划状态：冲突（与 ScheduleUseCase.detectAndWriteConflicts 写入值一致）。 */
const STATUS_CONFLICT = 'CONFLICT';

/** 计划创建闩：重复点击/手势重入时只放行第一次，避免同一条计划落两遍。 */
const CREATE_LATCH = new SubmitLatch();

/** 真机日历门面 → 端口适配。 */
class DeviceCalendar implements CalendarCapability {
  confirm(title: string, startMin: number, endMin: number, direct: boolean): Promise<CalendarWriteResult> {
    return direct ? CalendarGateway.writeEvent(title, startMin, endMin)
      : CalendarGateway.confirmEvent(title, startMin, endMin);
  }

  remove(eventId: string): Promise<boolean> {
    return CalendarGateway.removeEvent(eventId);
  }
}

/** 真机提醒门面 → 端口适配。 */
class DeviceReminder implements ReminderCapability {
  publish(title: string, startMin: number): Promise<number> {
    return ReminderGateway.publish(title, startMin);
  }

  cancel(reminderId: number): Promise<void> {
    return ReminderGateway.cancel(reminderId);
  }
}

/**
 * 共同计划用例（US5 / FR-009 / FR-017 / FR-014）——只做业务编排，不碰 @kit：
 * - createPlan：校验（PlanFlow 纯口径）→ 先写本地计划（calendar_state=PENDING）
 *   → 请系统日历确认 → 回写 calendar_state → 注册提醒 → 一次重算；
 * - 日历被取消/无权限/不可用时本地计划照常保留，由 UI 显示"仅保存在应用内"；
 * - acceptAlternative / keepOriginalPlan / cancelPlan：冲突四动作（阶段 2 Task 2.3），
 *   本地计划先落地，日历与提醒只是它的投影，投影失败一律降级成"待重试"而不是回滚；
 * - 取消/改期的确认弹窗由 UI 层完成，本层不弹窗。
 *
 * 系统能力走 CalendarCapability/ReminderCapability 端口，默认真机门面；
 * 单测注入确定性实现，好让"用户取消/权限拒绝/写入抛错"这些真机不可复现的分支也能被断言。
 */
export class PlanUseCase {
  private static cal: CalendarCapability = new DeviceCalendar();
  private static rem: ReminderCapability = new DeviceReminder();

  /** 默认选项：走系统日历确认路径。 */
  static defaultOptions(): CreatePlanOptions {
    return { directCalendarWrite: false };
  }

  /** 换掉系统能力实现（单测/后续日历后端）；不传就保持真机门面。 */
  static bindCapabilities(calendar: CalendarCapability | null, reminder: ReminderCapability | null): void {
    if (calendar != null) {
      PlanUseCase.cal = calendar;
    }
    if (reminder != null) {
      PlanUseCase.rem = reminder;
    }
  }

  /**
   * 创建共同计划：
   * 1) 草稿校验（标题、起止、必须完全落在窗口内）——非法不写库也不重算；
   * 2) 本地计划先落库（status=OK，calendar_state=PENDING）：计划是本机事实，
   *    系统日历只是它的一份投影，投影失败不该让计划消失；
   * 3) 默认由用户在系统日历确认；显式高级选项才直写；
   * 4) 确认结果写回 calendar_state，提醒尽力注册，全程只触发一次重算。
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
      const state = await PlanUseCase.writeCalendar(planId, row.title, startMin, endMin,
        options.directCalendarWrite);
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
   * 级联清理"同休日"日历日程与本地提醒（尽力而为，失败只记日志：留下孤儿日程比谎报取消失败更轻）
   * → updatePlanStatus CANCELLED → 一次重算（该时段恢复空闲）。
   */
  static async cancelPlan(id: string): Promise<PlanOpResult> {
    const row = await PlanUseCase.findPlan(id);
    if (row != null) {
      await PlanUseCase.clearProjection(row);
    }
    try {
      await ScheduleRepo.updatePlanStatus(id, 'CANCELLED');
    } catch (e) {
      Logger.warn(TAG, 'cancelPlan persist failed: ' + (e as Error).message);
      return { ok: false, calendarState: CalendarState.NOT_REQUESTED, error: '取消失败，计划仍在列表里' };
    }
    await PlanUseCase.recomputeQuietly();
    return { ok: true, calendarState: row != null ? row.calendarState : CalendarState.NOT_REQUESTED, error: '' };
  }

  /**
   * 采用替代时间（冲突动作一 / L11 G1）：
   * 计划时长不变、起点对齐替代窗口起点（替代窗口由冲突检测保证时长足够，越界时收缩兜底）；
   * 本地计划先改到新时间，再级联迁移日历日程与提醒——
   * 迁移失败时计划仍在新时间（不丢），只把 calendar_state 落到"待重试"，UI 给出补写入口。
   * 替代窗口信息缺失/非法（已被新一次重算覆盖）时 ok=false，UI 提示重选窗口。
   */
  static async acceptAlternative(id: string): Promise<PlanOpResult> {
    const row = await PlanUseCase.findPlan(id);
    const hint = row != null ? decodeConflictHint(row.conflictHint) : null;
    if (row == null || row.status !== STATUS_CONFLICT || hint == null
      || !(hint.altStartMin > 0 && hint.altEndMin > hint.altStartMin)) {
      return { ok: false, calendarState: CalendarState.NOT_REQUESTED, error: '替代窗口已失效，请重新选择时间' };
    }
    const newStart = hint.altStartMin;
    const newEnd = Math.min(newStart + (row.end - row.start), hint.altEndMin);
    if (newEnd - newStart < MIN_PLAN_MIN) {
      return { ok: false, calendarState: CalendarState.NOT_REQUESTED, error: '替代窗口太短，请重新选择时间' };
    }
    try {
      await ScheduleRepo.updatePlanTime(id, newStart, newEnd);
    } catch (e) {
      Logger.warn(TAG, 'reschedule persist failed: ' + (e as Error).message);
      return { ok: false, calendarState: row.calendarState, error: '改期失败，计划仍在原时间' };
    }
    // 到这里本地计划已经是新时间：后面的日历与提醒只做投影，失败都不把计划拉回去
    const state = await PlanUseCase.migrateCalendar(row, newStart, newEnd);
    await PlanUseCase.publishReminder(id, row.title, newStart);
    await PlanUseCase.recomputeQuietly();
    Logger.info(TAG, 'plan rescheduled to alternative: id=' + id + ' calendar=' + state);
    return { ok: true, calendarState: state, error: '' };
  }

  /**
   * 把"仅保存在应用内"的计划补写到系统日历（改期/创建时没写成的重试入口）。
   * ok 说的是日历这次有没有写成；本地计划内容一个字都不改，所以不触发重算。
   */
  static async syncToCalendar(id: string): Promise<PlanOpResult> {
    const row = await PlanUseCase.findPlan(id);
    if (row == null) {
      return { ok: false, calendarState: CalendarState.NOT_REQUESTED, error: '计划已不存在' };
    }
    const state = await PlanUseCase.writeCalendar(id, row.title, row.start, row.end, false);
    const written = isOnSystemCalendar(state);
    return {
      ok: written, calendarState: state,
      error: written ? '' : '日历仍未写入，稍后可以再试一次'
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

  /** 按 id 取活动计划（含 CANCELLED 之外的全部状态）。 */
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
   * 请系统日历写入并回写 calendar_state。
   * 异常一律归一成 FAILED：调用方据此把计划标成"待重试"，而不是让整条链路抛出去。
   */
  private static async writeCalendar(id: string, title: string, startMin: number, endMin: number,
    direct: boolean): Promise<string> {
    let result: CalendarWriteResult = { outcome: CalendarOutcome.FAILED, eventId: '' };
    try {
      result = await PlanUseCase.cal.confirm(title, startMin, endMin, direct);
    } catch (e) {
      Logger.warn(TAG, 'calendar write threw: ' + (e as Error).message);
    }
    const state = calendarStateOf(result.outcome);
    await ScheduleRepo.updatePlanCalendar(id, state,
      result.outcome === CalendarOutcome.WRITTEN ? result.eventId : '');
    return state;
  }

  /** 改期时的日历迁移：先尽力清掉旧日程，再按默认确认路径写新日程。 */
  private static async migrateCalendar(row: PlanRow, newStart: number, newEnd: number): Promise<string> {
    await PlanUseCase.removeEventQuietly(row.myEventId);
    await PlanUseCase.cancelReminderQuietly(row.reminderId);
    return PlanUseCase.writeCalendar(row.id, row.title, newStart, newEnd, false);
  }

  /** 取消计划时的投影清理（日历日程 + 本地提醒），失败只记日志不阻塞取消。 */
  private static async clearProjection(row: PlanRow): Promise<void> {
    await PlanUseCase.removeEventQuietly(row.myEventId);
    await PlanUseCase.cancelReminderQuietly(row.reminderId);
  }

  private static async removeEventQuietly(eventId: string): Promise<void> {
    if (eventId === '') {
      return;
    }
    try {
      await PlanUseCase.cal.remove(eventId);
    } catch (e) {
      Logger.warn(TAG, 'calendar event cleanup failed: ' + (e as Error).message);
    }
  }

  private static async cancelReminderQuietly(reminderId: number): Promise<void> {
    if (reminderId < 0) {
      return;
    }
    try {
      await PlanUseCase.rem.cancel(reminderId);
    } catch (e) {
      Logger.warn(TAG, 'reminder cancel failed: ' + (e as Error).message);
    }
  }

  /** 本地提醒（US8 / FR-014）：任何失败都静默降级，绝不阻塞计划本身。 */
  private static async publishReminder(id: string, title: string, startMin: number): Promise<void> {
    try {
      const reminderId = await PlanUseCase.rem.publish(title, startMin);
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
