import { notificationManager } from '@kit.NotificationKit';
import { reminderAgentManager } from '@kit.BackgroundTasksKit';
import { common } from '@kit.AbilityKit';
import { Logger } from 'commons';
import { epochMinToUtcMs } from '../model/PlanFlow';

const TAG = 'ReminderGateway';

/**
 * 本地提醒能力门面（阶段 2 Task 2.2 从 PlanUseCase 拆出）：
 * 通知授权 + reminderAgentManager 都是设备侧行为，用例编排不该带着 @kit 依赖，
 * 所以这里只对外暴露"成 / 不成"两个数，业务层据此决定 reminder_id 是否回写。
 */
export class ReminderGateway {
  private static context: common.UIAbilityContext | null = null;

  /** 保存 UIAbility 上下文（requestEnableNotification 需要）；未初始化时提醒静默不可用。 */
  static init(context: common.UIAbilityContext): void {
    ReminderGateway.context = context;
  }

  /**
   * 注册计划开始时刻的后台代理提醒（REMINDER_TYPE_CALENDAR，US8 / FR-014）：
   * 通知未开启（用户拒绝或系统异常）→ -1；发布失败 → -1。一律不抛出，绝不阻塞计划创建。
   */
  static async publish(title: string, startMin: number): Promise<number> {
    const ctx = ReminderGateway.context;
    if (ctx == null) {
      return -1;
    }
    try {
      if (!await ReminderGateway.ensureNotificationEnabled(ctx)) {
        Logger.info(TAG, 'notification not enabled, skip reminder');
        return -1;
      }
      // epochMin（本地纪元分钟）→ UTC 毫秒 → 本地日期时间字段
      const d = new Date(epochMinToUtcMs(startMin));
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
      Logger.warn(TAG, 'publish degraded: ' + (e as Error).message);
      return -1;
    }
  }

  /** 取消提醒（尽力而为；-1 视为无需取消，失败静默——过期后系统会自行清理）。 */
  static async cancel(reminderId: number): Promise<void> {
    if (reminderId < 0) {
      return;
    }
    try {
      await reminderAgentManager.cancelReminder(reminderId);
    } catch (e) {
      Logger.warn(TAG, 'cancel degraded: ' + (e as Error).message);
    }
  }

  /** 引导开启通知授权（弹窗由系统显示）：已开启/用户同意 → true，拒绝或异常 → false。 */
  private static async ensureNotificationEnabled(ctx: common.UIAbilityContext): Promise<boolean> {
    try {
      await notificationManager.requestEnableNotification(ctx);
      return true;
    } catch (e) {
      Logger.warn(TAG, 'requestEnableNotification rejected: ' + (e as Error).message);
      return false;
    }
  }
}
