import { calendarManager } from '@kit.CalendarKit';
import { abilityAccessCtrl, common, PermissionRequestResult, Permissions } from '@kit.AbilityKit';
import { notificationManager } from '@kit.NotificationKit';
import { reminderAgentManager } from '@kit.BackgroundTasksKit';
import { util } from '@kit.ArkTS';
import { PlanRow, ScheduleRepo } from 'data';
import { Logger } from 'commons';
import { ScheduleUseCase } from './ScheduleUseCase';

/** 创建计划结果。 */
export interface CreatePlanResult {
  ok: boolean;
  planId: string;
  /** Calendar Kit 是否成功写入"同休日"日历（false = 仅本机计划，计划仍创建成功）。 */
  calendarWritten: boolean;
  error: string;
}

/** "同休日"专属日历账户名（Calendar Kit 目标账户）。 */
const CAL_NAME = '同休日';

const TAG = 'PlanUseCase';

/**
 * 共同计划用例（US5 / FR-009 / FR-017 / FR-014）：
 * - createPlan：窗口内硬限制校验 → RDB 写入 → Calendar Kit 尽力写入（权限拒绝/失败静默降级）
 *   → 本地提醒注册（通知拒绝/失败静默降级）→ 触发重算；
 * - cancelPlan：级联删除日历日程（尽力而为）→ 取消本地提醒（尽力而为）→ 状态 CANCELLED → 触发重算；
 * - 取消确认由 UI 层完成，本层不弹确认框。
 */
export class PlanUseCase {
  private static context: common.UIAbilityContext | null = null;

  /** 保存 UIAbility 上下文（权限请求与 CalendarManager 需要）；未初始化时日历写入静默降级。 */
  static init(context: common.UIAbilityContext): void {
    PlanUseCase.context = context;
  }

  /** 本地纪元分钟（epochMin）→ 13 位毫秒时间戳（本地时区语义换算）。 */
  static toUtcMs(epochMin: number): number {
    // getTimezoneOffset() = UTC - 本地（分钟，如东八区为 -480）
    return (epochMin + new Date().getTimezoneOffset()) * 60000;
  }

  /**
   * 创建共同计划：
   * 1) 硬限制校验：计划区间 [startMin, endMin) 必须完全落在窗口 [winStart, winEnd) 内；
   * 2) RDB 写入（status = OK）；
   * 3) Calendar Kit 尽力写入"同休日"日历并记录 my_event_id；
   *    权限拒绝（requestPermissionsFromUser 结果非 0）或调用失败 → 静默降级（仅本机计划），不阻塞创建；
   * 4) 触发 onScheduleChanged()（计划占用忙碌时间 + 冲突检测回写）。
   */
  static async createPlan(winStart: number, winEnd: number, title: string, kind: string,
    startMin: number, endMin: number): Promise<CreatePlanResult> {
    if (title.trim() === '') {
      return PlanUseCase.fail('请填写计划标题');
    }
    if (startMin >= endMin) {
      return PlanUseCase.fail('计划开始需早于结束');
    }
    if (startMin < winStart || endMin > winEnd) {
      return PlanUseCase.fail('计划时间需在窗口范围内');
    }
    const planId = util.generateRandomUUID();
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
      reminderId: -1
    };
    await ScheduleRepo.upsertPlan(row);
    let calendarWritten = false;
    try {
      const eventId = await PlanUseCase.writeCalendarEvent(row.title, startMin, endMin);
      if (eventId >= 0) {
        await ScheduleRepo.updatePlanEventId(planId, '' + eventId);
        calendarWritten = true;
      }
    } catch (e) {
      Logger.warn(TAG, 'calendar write degraded: ' + (e as Error).message);
    }
    // 本地提醒（US8 / FR-014）：任何一步失败均静默降级，绝不阻塞计划创建
    try {
      const reminderId = await PlanUseCase.registerReminder(row.title, startMin);
      if (reminderId >= 0) {
        await ScheduleRepo.updatePlanReminder(planId, reminderId);
      }
    } catch (e) {
      Logger.warn(TAG, 'register reminder degraded: ' + (e as Error).message);
    }
    await ScheduleUseCase.onScheduleChanged();
    const r: CreatePlanResult = {
      ok: true, planId: planId, calendarWritten: calendarWritten, error: ''
    };
    return r;
  }

  /**
   * 取消计划（确认弹窗由 UI 层负责）：
   * 级联删除"同休日"日历日程（my_event_id 存在时；权限被撤销/无账号 → try-catch 静默跳过）
   * → 取消本地提醒（reminder_id 存在时；失败静默跳过）
   * → updatePlanStatus CANCELLED → 触发重算（该时段恢复空闲）。
   */
  static async cancelPlan(id: string): Promise<void> {
    const rows = await ScheduleRepo.listActivePlans();
    let eventId = '';
    let reminderId = -1;
    for (let i = 0; i < rows.length; i++) {
      if (rows[i].id === id) {
        eventId = rows[i].myEventId;
        reminderId = rows[i].reminderId;
        break;
      }
    }
    if (eventId !== '') {
      try {
        const ctx = PlanUseCase.context;
        if (ctx != null) {
          const mgr = calendarManager.getCalendarManager(ctx);
          const account: calendarManager.CalendarAccount = {
            name: CAL_NAME, type: calendarManager.CalendarType.LOCAL
          };
          const cal = await mgr.getCalendar(account);
          await cal.deleteEvent(Number(eventId));
        }
      } catch (e) {
        // 权限被撤销/日历不存在：日历侧删除降级，本机取消照常进行
        Logger.warn(TAG, 'deleteEvent degraded: ' + (e as Error).message);
      }
    }
    // 取消本地提醒（尽力而为，失败静默：提醒过期后系统自动清理）
    if (reminderId >= 0) {
      try {
        await reminderAgentManager.cancelReminder(reminderId);
      } catch (e) {
        Logger.warn(TAG, 'cancelReminder degraded: ' + (e as Error).message);
      }
    }
    await ScheduleRepo.updatePlanStatus(id, 'CANCELLED');
    await ScheduleUseCase.onScheduleChanged();
  }

  /**
   * 尝试注册计划开始时间的本地提醒（后台代理提醒 REMINDER_TYPE_CALENDAR，US8 / FR-014）：
   * 1) requestEnableNotification 引导用户开启通知（已开启则直接通过）；拒绝/失败 → 返回 -1 降级；
   * 2) publishReminder 发布日历型提醒，时间取计划开始时刻（本地时区语义）；
   * 3) 任何一步抛错 → Logger.warn 降级返回 -1，不阻塞计划创建。
   */
  static async registerReminder(title: string, startMin: number): Promise<number> {
    const ctx = PlanUseCase.context;
    if (ctx == null) {
      return -1;
    }
    try {
      const enabled = await PlanUseCase.ensureNotificationEnabled(ctx);
      if (!enabled) {
        Logger.info(TAG, 'notification not enabled, skip reminder');
        return -1;
      }
      // epochMin（本地纪元分钟）→ UTC 毫秒 → 本地日期时间字段
      const d = new Date(PlanUseCase.toUtcMs(startMin));
      const reminder: reminderAgentManager.ReminderRequestCalendar = {
        reminderType: reminderAgentManager.ReminderType.REMINDER_TYPE_CALENDAR,
        dateTime: {
          year: d.getFullYear(),
          month: d.getMonth() + 1, // LocalDateTime 为 1-12 日历月（JS getMonth() 从 0 起，需 +1）
          day: d.getDate(),
          hour: d.getHours(),
          minute: d.getMinutes(),
          second: 0
        },
        title: title,
        content: '同休日计划即将开始'
      };
      const reminderId = await reminderAgentManager.publishReminder(reminder);
      Logger.info(TAG, 'reminder published, id=' + reminderId);
      return reminderId;
    } catch (e) {
      Logger.warn(TAG, 'registerReminder degraded: ' + (e as Error).message);
      return -1;
    }
  }

  /**
   * 引导开启通知授权（弹窗由系统显示）：
   * 已开启/用户同意 → true；用户拒绝或请求异常 → false（调用方静默降级，无系统通知但不崩溃）。
   */
  static async ensureNotificationEnabled(ctx: common.UIAbilityContext): Promise<boolean> {
    try {
      await notificationManager.requestEnableNotification(ctx);
      return true;
    } catch (e) {
      Logger.warn(TAG, 'requestEnableNotification rejected: ' + (e as Error).message);
      return false;
    }
  }

  /** 尽力写入"同休日"日历日程；成功返回日程 id（≥0），降级返回 -1。 */
  static async writeCalendarEvent(title: string, startMin: number, endMin: number): Promise<number> {
    const ctx = PlanUseCase.context;
    if (ctx == null) {
      return -1;
    }
    const granted = await PlanUseCase.requestCalendarPerms();
    if (!granted) {
      Logger.info(TAG, 'calendar permission denied, plan stays local');
      return -1;
    }
    const mgr = calendarManager.getCalendarManager(ctx);
    const account: calendarManager.CalendarAccount = {
      name: CAL_NAME,
      type: calendarManager.CalendarType.LOCAL,
      displayName: CAL_NAME
    };
    let cal: calendarManager.Calendar | null = null;
    try {
      cal = await mgr.getCalendar(account);
    } catch (e) {
      // 账户不存在（23900003）→ 创建专属日历
      try {
        cal = await mgr.createCalendar(account);
      } catch (e2) {
        Logger.warn(TAG, 'createCalendar failed: ' + (e2 as Error).message);
        return -1;
      }
    }
    if (cal == null) {
      return -1;
    }
    const event: calendarManager.Event = {
      type: calendarManager.EventType.NORMAL,
      title: title,
      startTime: PlanUseCase.toUtcMs(startMin),
      endTime: PlanUseCase.toUtcMs(endMin),
      description: '同休日共同计划'
    };
    const id = await cal.addEvent(event);
    Logger.info(TAG, 'calendar event written, id=' + id);
    return id;
  }

  /**
   * 请求日历读写权限：全部授予返回 true；
   * 任一拒绝或请求异常返回 false（调用方静默降级为仅本机计划，不崩溃）。
   */
  static async requestCalendarPerms(): Promise<boolean> {
    const ctx = PlanUseCase.context;
    if (ctx == null) {
      return false;
    }
    try {
      const atManager = abilityAccessCtrl.createAtManager();
      const perms: Permissions[] = ['ohos.permission.READ_CALENDAR', 'ohos.permission.WRITE_CALENDAR'];
      const result: PermissionRequestResult = await atManager.requestPermissionsFromUser(ctx, perms);
      for (let i = 0; i < result.authResults.length; i++) {
        if (result.authResults[i] !== 0) {
          return false;
        }
      }
      return true;
    } catch (e) {
      Logger.warn(TAG, 'requestPermissionsFromUser failed: ' + (e as Error).message);
      return false;
    }
  }

  private static fail(msg: string): CreatePlanResult {
    const r: CreatePlanResult = { ok: false, planId: '', calendarWritten: false, error: msg };
    return r;
  }
}
