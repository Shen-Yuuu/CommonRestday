import { PlanRow } from 'data';
import { Logger } from 'commons';
import { PlanCapabilities } from '../integration/PlanCapabilities';
import {
  CalendarState, CleanupReport, RemoveOutcome, addCleanupReport, emptyCleanupReport, normalizeCalendarState
} from '../model/PlanFlow';

const TAG = 'PlanProjectionCleanup';

/**
 * 计划投影清理（阶段 6R.1，验收报告 B2）：把"删系统日历日程 + 取消 ReminderAgent"收成一处。
 *
 * 三条口径：
 * 1. **只动本应用管得动的东西**：editEvent 导出的日程（EXTERNAL_UNMANAGED）在普通权限下删不动，
 *    拿它的 id 去试还可能删错日历里的别的条目，所以一律不试、只计数让用户自己删；
 * 2. **不吞失败**：删不掉就计入 eventsPending/remindersPending，调用方必须把 id 留在计划行里，
 *    这样"取消/改期/清空"才有重试的可能；旧实现是 catch 掉异常继续标成功，孤儿就是这么来的；
 * 3. **本服务不写库**：同一次清理之后该落哪个状态，取决于调用方在做的是取消、改期还是清空，
 *    状态判断留在 usecase（PlanFlow.calendarStateAfterCleanup），这里只给事实。
 */
export class PlanProjectionCleanupService {
  /** 单条计划的投影清理：日程 + 提醒句柄，一次走完。 */
  static async cleanupPlan(row: PlanRow): Promise<CleanupReport> {
    const report = emptyCleanupReport();
    const state = normalizeCalendarState(row.calendarState);

    if (row.myEventId !== '') {
      if (state === CalendarState.EXTERNAL_UNMANAGED) {
        report.eventsExternal = 1;
      } else if (await PlanProjectionCleanupService.removeEvent(row.myEventId)) {
        report.eventsRemoved = 1;
      } else {
        report.eventsPending = 1;
      }
    }

    if (row.reminderId >= 0) {
      if (await PlanProjectionCleanupService.cancelReminder(row.reminderId)) {
        report.remindersRemoved = 1;
      } else {
        report.remindersPending = 1;
      }
    }
    return report;
  }

  /** 批量清理（清空数据、待清理区重试）：一份合并后的报告，条数直接给用户看。 */
  static async cleanupPlanList(rows: PlanRow[]): Promise<CleanupReport> {
    const total = emptyCleanupReport();
    for (let i = 0; i < rows.length; i++) {
      addCleanupReport(total, await PlanProjectionCleanupService.cleanupPlan(rows[i]));
    }
    return total;
  }

  /**
   * 整本清空应用专属「同休日」日历：逐条 id 之外的兜底。
   * false = 没清成（权限、设备异常），调用方要如实报告"日历里可能还留着日程"。
   */
  static async purgeManagedCalendar(): Promise<boolean> {
    try {
      return await PlanCapabilities.calendar().purgeManagedCalendar();
    } catch (e) {
      Logger.warn(TAG, 'purge threw: ' + (e as Error).message);
      return false;
    }
  }

  private static async removeEvent(eventId: string): Promise<boolean> {
    try {
      return await PlanCapabilities.calendar().remove(eventId) === RemoveOutcome.REMOVED;
    } catch (e) {
      Logger.warn(TAG, 'event remove threw: ' + (e as Error).message);
      return false;
    }
  }

  private static async cancelReminder(reminderId: number): Promise<boolean> {
    try {
      return await PlanCapabilities.reminder().cancel(reminderId);
    } catch (e) {
      Logger.warn(TAG, 'reminder cancel threw: ' + (e as Error).message);
      return false;
    }
  }
}
