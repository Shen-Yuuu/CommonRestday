import { Logger } from 'commons';
import {
  CalendarCapability, CalendarOutcome, CalendarWriteResult, ReminderCapability, RemoveOutcome
} from '../model/PlanFlow';
import { CalendarGateway } from './CalendarGateway';
import { NotificationGateway } from './NotificationGateway';
import { ReminderGateway } from './ReminderGateway';

const TAG = 'PlanCapabilities';

/** 真机日历门面 → 端口适配（受管写入 / 导出 / 结构化删除）。 */
class DeviceCalendar implements CalendarCapability {
  write(title: string, startMin: number, endMin: number): Promise<CalendarWriteResult> {
    return CalendarGateway.writeEvent(title, startMin, endMin);
  }

  exportToSystem(title: string, startMin: number, endMin: number): Promise<CalendarWriteResult> {
    return CalendarGateway.exportEvent(title, startMin, endMin);
  }

  remove(eventId: string): Promise<RemoveOutcome> {
    return CalendarGateway.removeEvent(eventId);
  }

  purgeManagedCalendar(): Promise<boolean> {
    return CalendarGateway.purgeManagedCalendar();
  }
}

/** 真机提醒门面 → 端口适配（要不要提醒由通知策略决定，见 NotificationGateway）。 */
class DeviceReminder implements ReminderCapability {
  publish(title: string, startMin: number): Promise<number> {
    return NotificationGateway.publishPlanReminder(title, startMin);
  }

  async cancel(reminderId: number): Promise<boolean> {
    if (reminderId < 0) {
      return true;
    }
    try {
      await ReminderGateway.cancel(reminderId);
      return true;
    } catch (e) {
      Logger.warn(TAG, 'reminder cancel threw: ' + (e as Error).message);
      return false;
    }
  }
}

/**
 * 计划相关系统能力的唯一持有者（阶段 6R.1 从 PlanUseCase 里收出来）。
 *
 * 为什么单独一份：日历日程的取消/改期/清空分散在 PlanUseCase 与
 * PlanProjectionCleanupService 两处，如果各自持有实现，测试注入的假能力就只管得住一半，
 * "删不掉时留不留重试信息"这类分支反而测不到。所以：
 * - 生产默认值是这里的真机门面（CalendarGateway / NotificationGateway）；
 * - 单测用 bind() 换成确定性端口实现，两处消费者看到同一份假能力。
 */
export class PlanCapabilities {
  private static cal: CalendarCapability = new DeviceCalendar();
  private static rem: ReminderCapability = new DeviceReminder();

  /** 换掉系统能力实现（单测/后续日历后端）；不传就保持真机门面。 */
  static bind(calendar: CalendarCapability | null, reminder: ReminderCapability | null): void {
    if (calendar != null) {
      PlanCapabilities.cal = calendar;
    }
    if (reminder != null) {
      PlanCapabilities.rem = reminder;
    }
  }

  static calendar(): CalendarCapability {
    return PlanCapabilities.cal;
  }

  static reminder(): ReminderCapability {
    return PlanCapabilities.rem;
  }

  /** 没写成时的归一：端口自己抛错也不能把异常丢给 UI，统一按"写入失败、可重试"。 */
  static async writeManaged(title: string, startMin: number, endMin: number): Promise<CalendarWriteResult> {
    try {
      return await PlanCapabilities.cal.write(title, startMin, endMin);
    } catch (e) {
      Logger.warn(TAG, 'managed write threw: ' + (e as Error).message);
      return { outcome: CalendarOutcome.FAILED, eventId: '' };
    }
  }
}
