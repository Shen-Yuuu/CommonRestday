import { PlanRow, ScheduleRepo } from 'data';
import { Logger } from 'commons';
import { ScheduleUseCase } from './ScheduleUseCase';
import { CalendarGateway } from '../integration/CalendarGateway';
import { ReminderGateway } from '../integration/ReminderGateway';
import {
  CalendarCapability, CalendarOutcome, CalendarState, CalendarWriteResult, MIN_PLAN_MIN, PlanDraft,
  ReminderCapability, SubmitLatch, calendarStateOf, newPlanId, planDraftError
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
 * - cancelPlan / acceptAlternative：级联清理日历日程与提醒（尽力而为）→ 回写状态 → 一次重算；
 * - 取消确认由 UI 层完成，本层不弹确认框。
 *
 * 系统能力走 CalendarCapability/ReminderCapability 端口，默认真机门面；
 * 单测注入确定性实现，好让"用户取消/权限拒绝"这些真机不可复现的分支也能被断言。
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
      const cal = await PlanUseCase.cal.confirm(row.title, startMin, endMin, options.directCalendarWrite);
      const state = calendarStateOf(cal.outcome);
      await ScheduleRepo.updatePlanCalendar(planId, state,
        cal.outcome === CalendarOutcome.WRITTEN ? cal.eventId : '');
      // 本地提醒（US8 / FR-014）：任何一步失败均静默降级，绝不阻塞计划创建
      const reminderId = await PlanUseCase.rem.publish(row.title, startMin);
      if (reminderId >= 0) {
        await ScheduleRepo.updatePlanReminder(planId, reminderId);
      }
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
   * 级联删除"同休日"日历日程与本地提醒（都尽力而为，失败只记日志）
   * → updatePlanStatus CANCELLED → 触发重算（该时段恢复空闲）。
   */
  static async cancelPlan(id: string): Promise<void> {
    const row = await PlanUseCase.findPlan(id);
    if (row != null) {
      await PlanUseCase.cal.remove(row.myEventId);
      await PlanUseCase.rem.cancel(row.reminderId);
    }
    await ScheduleRepo.updatePlanStatus(id, 'CANCELLED');
    await ScheduleUseCase.onScheduleChanged();
  }

  /**
   * 接受冲突替代窗口改期（PRD F7 动作一 / L11 G1）：
   * 计划时长不变、起点对齐替代窗口起点（替代窗口由冲突检测保证时长足够，越界时收缩兜底）；
   * 级联迁移系统日历日程与本地提醒（旧事件/旧提醒尽力清理，新事件按默认确认路径重写），
   * 回写新起止后触发重算——重算的冲突检测在新时段无冲突时把计划恢复为 OK。
   * 替代窗口信息缺失/非法时返回 false，UI 提示重选窗口。
   */
  static async acceptAlternative(id: string): Promise<boolean> {
    const row = await PlanUseCase.findPlan(id);
    if (row == null || row.status !== 'CONFLICT' || row.conflictHint === '') {
      return false;
    }
    let altStart = 0;
    let altEnd = 0;
    try {
      const o = JSON.parse(row.conflictHint) as Record<string, number>;
      altStart = Number(o['altStart']);
      altEnd = Number(o['altEnd']);
    } catch (e) {
      return false;
    }
    if (!(altStart > 0 && altEnd > altStart)) {
      return false;
    }
    const duration = row.end - row.start;
    const newStart = altStart;
    const newEnd = Math.min(altStart + duration, altEnd);
    if (newEnd - newStart < MIN_PLAN_MIN) {
      return false;
    }
    // 级联迁移：旧日历日程/旧提醒尽力清理（失败不阻塞改期）
    await PlanUseCase.cal.remove(row.myEventId);
    await PlanUseCase.rem.cancel(row.reminderId);
    await ScheduleRepo.updatePlanTime(id, newStart, newEnd);
    const cal = await PlanUseCase.cal.confirm(row.title, newStart, newEnd, false);
    const state = calendarStateOf(cal.outcome);
    await ScheduleRepo.updatePlanCalendar(id, state,
      cal.outcome === CalendarOutcome.WRITTEN ? cal.eventId : '');
    const reminderId = await PlanUseCase.rem.publish(row.title, newStart);
    if (reminderId >= 0) {
      await ScheduleRepo.updatePlanReminder(id, reminderId);
    }
    await ScheduleUseCase.onScheduleChanged();
    Logger.info(TAG, 'plan rescheduled to alternative: id=' + id + ' calendar=' + state);
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

  private static fail(msg: string): CreatePlanResult {
    return { ok: false, planId: '', calendarState: CalendarState.NOT_REQUESTED, error: msg };
  }
}
