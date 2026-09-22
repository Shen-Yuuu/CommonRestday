import { notificationManager } from '@kit.NotificationKit';
import { reminderAgentManager } from '@kit.BackgroundTasksKit';
import { common } from '@kit.AbilityKit';
import { ConflictHint, conflictSignature, decodeConflictHint } from 'domain';
import { PlanRow, SettingsStore } from 'data';
import { Logger } from 'commons';
import { ReminderGateway } from './ReminderGateway';

const TAG = 'Notification';

/** 计划状态：冲突（与 ScheduleUseCase.detectAndWriteConflicts 写入值一致）。 */
const STATUS_CONFLICT = 'CONFLICT';

/** 周摘要的定时口径：周日 20:00（reminderAgentManager 里 daysOfWeek 的 7 = 周日）。 */
const WEEKLY_HOUR = 20;
const WEEKLY_MINUTE = 0;
const WEEKLY_SUNDAY = 7;
const WEEKLY_TITLE = '同休日周报';
const WEEKLY_CONTENT = '本周共同空闲已更新，打开看看这周能一起休哪天';

const NOTICE_TITLE = '同休日';

/**
 * 普通通知各用固定 id：同 id 会顶掉旧的那条（SDK 口径见 @ohos.notificationManager.d.ts
 * 头部第 2 条流程），所以"每次重算都检查一遍"不会在通知中心堆成一串。
 */
const NOTICE_ID_CONFLICT = 20001;
const NOTICE_ID_REPAIR = 20002;

/** 冲突正文：只报数量，计划标题/课程名/地点这类明细一律不进通知（锁屏上谁都看得见）。 */
const NOTICE_TEXT_CONFLICT_ONE = '有一个共同计划的时间冲突了，打开同休日看看怎么处理';
const NOTICE_TEXT_CONFLICT_TAIL = ' 个共同计划的时间冲突了，打开同休日看看怎么处理';
const NOTICE_TEXT_REPAIR = 'TA 的加密日程读不了了，需要重新配对才能继续同步';

/** 已提示过的冲突签名在 Preferences 里的扁平分隔符。 */
const SIG_SEP = ';';

/**
 * 通知与提醒的策略门面（阶段 4 Task 4.3）：把"什么时候允许吵用户一次"收在一处。
 *
 * 三档口径，默认都偏安静：
 * - 系统日历优先：计划默认写进系统日历，报时由日历负责，ReminderAgent 定点提醒要用户主动开（默认关）；
 * - 周摘要默认关：周日 20:00 那条周报是可选订阅，不再跟着每次重算注册；
 * - 只推需行动的：计划冲突未处理、对方快照读不开需要重新配对，才发普通通知；同步成功一律不通知。
 *
 * 全部设备调用静默降级：通知是锦上添花，读设置失败/未授权/发布抛错都不能让重算或保存计划失败。
 * 槽位不单独 addSlot——SDK 口径：publish 时带 notificationSlotType，对应槽位不存在会自动创建。
 */
export class NotificationGateway {
  // ---------- 系统通知授权 ----------

  /** 通知是否已授权（只查询，不弹窗：重算链路里弹授权窗是打断）。 */
  static async isEnabled(): Promise<boolean> {
    try {
      return await notificationManager.isNotificationEnabled();
    } catch (e) {
      Logger.warn(TAG, 'isNotificationEnabled degraded: ' + (e as Error).message);
      return false;
    }
  }

  /** 引导用户开启通知（只在用户当面点开关/按钮时调用，弹窗由系统显示）。 */
  static async requestEnabled(ctx: common.UIAbilityContext): Promise<boolean> {
    try {
      await notificationManager.requestEnableNotification(ctx);
      return await NotificationGateway.isEnabled();
    } catch (e) {
      Logger.warn(TAG, 'requestEnableNotification rejected: ' + (e as Error).message);
      return false;
    }
  }

  // ---------- 计划定点提醒（ReminderAgent，需用户主动开启） ----------

  /**
   * 计划开始的定点提醒：精确提醒没开就返回 -1（调用方据此不写 reminder_id）。
   * 开关只影响之后创建/改期的计划——存量计划不回补提醒，也不因关闭而撤销，
   * 因为系统日历里那条日程才是它的报时主体。
   */
  static async publishPlanReminder(title: string, startMin: number): Promise<number> {
    if (!SettingsStore.isPreciseReminderOn()) {
      Logger.info(TAG, 'precise reminder off, calendar only');
      return -1;
    }
    return ReminderGateway.publish(title, startMin);
  }

  /** 取消定点提醒：与开关无关，历史注册过的一律清掉，不留孤儿提醒。 */
  static async cancelPlanReminder(reminderId: number): Promise<void> {
    await ReminderGateway.cancel(reminderId);
  }

  // ---------- 三个开关的写入口（读值在 SettingsStore，默认值即策略） ----------

  /** 写入返回值只说"存住了没"：没存住时调用方把开关拨回真值，这里不替用户决定重试。 */
  static async setPreciseReminder(on: boolean): Promise<boolean> {
    try {
      await SettingsStore.setPreciseReminderOn(on);
      return true;
    } catch (e) {
      Logger.warn(TAG, 'precise switch failed: ' + (e as Error).message);
      return false;
    }
  }

  /** 周摘要：开关与那条后台提醒一起收口——先写设置，再幂等同步（同步自身已在内部兜底）。 */
  static async setWeeklySummary(on: boolean): Promise<boolean> {
    try {
      await SettingsStore.setWeeklySummaryOn(on);
    } catch (e) {
      Logger.warn(TAG, 'weekly switch failed: ' + (e as Error).message);
      return false;
    }
    await NotificationGateway.syncWeeklyReminder();
    return true;
  }

  static async setActionAlerts(on: boolean): Promise<boolean> {
    try {
      await SettingsStore.setActionAlertsOn(on);
      return true;
    } catch (e) {
      Logger.warn(TAG, 'alerts switch failed: ' + (e as Error).message);
      return false;
    }
  }

  /**
   * 幂等对齐"周摘要"这条后台提醒与开关：开且未注册才注册，关且注册过才取消。
   * 每次重算都可以放心调，不会像无条件重注册那样反复取消重建。
   */
  static async syncWeeklyReminder(): Promise<void> {
    try {
      const want = SettingsStore.isWeeklySummaryOn();
      const existing = await SettingsStore.getWeeklyReminderId();
      if (!want) {
        if (existing >= 0) {
          await ReminderGateway.cancel(existing);
          await SettingsStore.setWeeklyReminderId(-1);
          Logger.info(TAG, 'weekly summary canceled');
        }
        return;
      }
      if (existing >= 0) {
        return;
      }
      if (!await NotificationGateway.isEnabled()) {
        Logger.info(TAG, 'weekly summary skipped: notification off');
        return;
      }
      const reminder: reminderAgentManager.ReminderRequestAlarm = {
        reminderType: reminderAgentManager.ReminderType.REMINDER_TYPE_ALARM,
        hour: WEEKLY_HOUR,
        minute: WEEKLY_MINUTE,
        daysOfWeek: [WEEKLY_SUNDAY],
        title: WEEKLY_TITLE,
        content: WEEKLY_CONTENT
      };
      const id = await reminderAgentManager.publishReminder(reminder);
      await SettingsStore.setWeeklyReminderId(id);
      Logger.info(TAG, 'weekly summary registered, id=' + id);
    } catch (e) {
      Logger.warn(TAG, 'weekly summary degraded: ' + (e as Error).message);
    }
  }

  // ---------- 需行动通知（冲突 / 需重新配对） ----------

  /**
   * 冲突提示：只报"有几个待处理冲突"，同一次冲突不重复提示。
   * 去重键是 计划 id + 冲突签名（原因 + 受影响区间），每轮重算整体覆写，
   * 所以冲突消解后键自然清空，同一个冲突换个原因再犯会重新提示一次。
   * 由重算链路 fire-and-forget 调用，内部全捕获。
   */
  static async notifyConflicts(rows: PlanRow[]): Promise<void> {
    try {
      if (!SettingsStore.isActionAlertsOn()) {
        return;
      }
      const current = NotificationGateway.actionableSigs(rows);
      const seen = SettingsStore.getNotifiedConflictSigs();
      const flat = current.join(SIG_SEP);
      if (current.length === 0) {
        // 本轮没有待处理冲突：清空记录，同一个冲突再犯时还要能再说一次
        if (seen !== '') {
          await SettingsStore.setNotifiedConflictSigs('');
        }
        return;
      }
      if (!await NotificationGateway.isEnabled()) {
        // 通知没开：不记签名，用户开启后下一次重算就会补上这句提示
        return;
      }
      let fresh = 0;
      const known = seen.split(SIG_SEP);
      for (let i = 0; i < current.length; i++) {
        if (known.indexOf(current[i]) < 0) {
          fresh++;
        }
      }
      if (fresh > 0) {
        const text = fresh === 1 ? NOTICE_TEXT_CONFLICT_ONE : '' + fresh + NOTICE_TEXT_CONFLICT_TAIL;
        await NotificationGateway.publishNotice(NOTICE_ID_CONFLICT, text);
      }
      if (flat !== seen) {
        // 整体覆写即自我修剪：只留本轮还存在的签名，不随历史堆积
        await SettingsStore.setNotifiedConflictSigs(flat);
      }
    } catch (e) {
      Logger.warn(TAG, 'conflict notice degraded: ' + (e as Error).message);
    }
  }

  /**
   * "需要重新配对"提示：对方快照解密/解码失败时用户才有事可做，一次配对状态只说一次。
   * 标记存在 SettingsStore，配对状态一变即清（见 SettingsStore.setPairState）。
   */
  static async notifyRepairNeeded(): Promise<void> {
    try {
      if (!SettingsStore.isActionAlertsOn() || SettingsStore.isRepairNoticeSent()) {
        return;
      }
      if (!await NotificationGateway.isEnabled()) {
        return;
      }
      await NotificationGateway.publishNotice(NOTICE_ID_REPAIR, NOTICE_TEXT_REPAIR);
      await SettingsStore.setRepairNoticeSent(true);
    } catch (e) {
      Logger.warn(TAG, 'repair notice degraded: ' + (e as Error).message);
    }
  }

  /** 待处理冲突的签名集合：处于 CONFLICT 且用户没点过"保留原计划"。 */
  private static actionableSigs(rows: PlanRow[]): string[] {
    const out: string[] = [];
    for (let i = 0; i < rows.length; i++) {
      const row = rows[i];
      if (row.status !== STATUS_CONFLICT) {
        continue;
      }
      const hint: ConflictHint | null = decodeConflictHint(row.conflictHint);
      if (hint == null || hint.kept) {
        continue;
      }
      out.push(row.id + '|' + conflictSignature(hint));
    }
    return out;
  }

  /** 发一条普通通知（服务提示类）。发布失败只记日志：用户看不到这条通知，本机状态照旧。 */
  private static async publishNotice(id: number, text: string): Promise<void> {
    try {
      const request: notificationManager.NotificationRequest = {
        id: id,
        notificationSlotType: notificationManager.SlotType.SERVICE_INFORMATION,
        content: { normal: { title: NOTICE_TITLE, text: text } }
      };
      await notificationManager.publish(request);
      Logger.info(TAG, 'notice published id=' + id);
    } catch (e) {
      Logger.warn(TAG, 'publish degraded: ' + (e as Error).message);
    }
  }
}
