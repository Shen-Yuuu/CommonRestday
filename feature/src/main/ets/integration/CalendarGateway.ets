import { calendarManager } from '@kit.CalendarKit';
import { abilityAccessCtrl, common, PermissionRequestResult, Permissions } from '@kit.AbilityKit';
import { Logger } from 'commons';
import {
  CalendarOutcome, CalendarWriteResult, epochMinToUtcMs
} from '../model/PlanFlow';

/** 取日历的结果：cal 为 null 时 outcome 说明为什么没拿到。 */
interface OpenedCalendar {
  cal: calendarManager.Calendar | null;
  outcome: CalendarOutcome;
}

/** 取管理器的结果：mgr 为 null 时 outcome 说明为什么没拿到。 */
interface OpenedManager {
  mgr: calendarManager.CalendarManager | null;
  outcome: CalendarOutcome;
}

/** "同休日"专属日历账户名（本应用唯一的写入目标）。 */
const CAL_NAME = '同休日';

const TAG = 'CalendarGateway';

function missed(outcome: CalendarOutcome): CalendarWriteResult {
  return { outcome: outcome, eventId: '' };
}

function written(eventId: number): CalendarWriteResult {
  return { outcome: CalendarOutcome.WRITTEN, eventId: '' + eventId };
}

/**
 * 系统日历能力门面（阶段 2 Task 2.2）：PlanUseCase 只做业务编排，设备调用与错误码归一在这里。
 *
 * 默认走 CalendarManager.editEvent（API 12）——它打开系统日程编辑页，由用户当面确认后才落库，
 * 所以"日历里有这条安排"是用户点头的结果，不是应用偷偷写进去的；
 * addEvent 保留为显式的高级路径（不弹确认直接写），不作为默认。
 * 任何一步失败都归一成 CalendarOutcome，绝不向调用方抛设备异常。
 */
export class CalendarGateway {
  private static context: common.UIAbilityContext | null = null;

  /** 保存 UIAbility 上下文（权限请求与 CalendarManager 都需要）；未初始化时能力视为不可用。 */
  static init(context: common.UIAbilityContext): void {
    CalendarGateway.context = context;
  }

  /** 默认路径：请用户在系统日历的日程编辑页确认后写入。 */
  static async confirmEvent(title: string, startMin: number, endMin: number): Promise<CalendarWriteResult> {
    const opened = await CalendarGateway.manager();
    if (opened.mgr == null) {
      return missed(opened.outcome);
    }
    try {
      // editEvent 挂在 CalendarManager 上：它不需要先建好账户，日程落在系统选定的日历里
      const id = await opened.mgr.editEvent(CalendarGateway.eventOf(title, startMin, endMin));
      // 接口口径：<0 = 用户在编辑页取消；0 不会返回；抛错另有其态
      if (id > 0) {
        Logger.info(TAG, 'event confirmed, id=' + id);
        return written(id);
      }
      Logger.info(TAG, 'event edit canceled by user');
      return missed(CalendarOutcome.CANCELED);
    } catch (e) {
      Logger.warn(TAG, 'editEvent failed: ' + (e as Error).message);
      return missed(CalendarOutcome.FAILED);
    }
  }

  /** 高级路径：跳过系统确认直接写入（仅在用户显式选择时使用）。 */
  static async writeEvent(title: string, startMin: number, endMin: number): Promise<CalendarWriteResult> {
    const opened = await CalendarGateway.open();
    if (opened.cal == null) {
      return missed(opened.outcome);
    }
    try {
      const id = await opened.cal.addEvent(CalendarGateway.eventOf(title, startMin, endMin));
      Logger.info(TAG, 'event written directly, id=' + id);
      return written(id);
    } catch (e) {
      Logger.warn(TAG, 'addEvent failed: ' + (e as Error).message);
      return missed(CalendarOutcome.FAILED);
    }
  }

  /** 尽力删除日程（计划取消/改期迁移）；空 id 视为已达成，失败只记日志不抛出。 */
  static async removeEvent(eventId: string): Promise<boolean> {
    if (eventId === '') {
      return true;
    }
    const opened = await CalendarGateway.open();
    if (opened.cal == null) {
      return false;
    }
    try {
      await opened.cal.deleteEvent(Number(eventId));
      return true;
    } catch (e) {
      // 权限被撤销或日程已被用户删掉：日历侧降级，本机操作照常进行
      Logger.warn(TAG, 'deleteEvent degraded: ' + (e as Error).message);
      return false;
    }
  }

  private static eventOf(title: string, startMin: number, endMin: number): calendarManager.Event {
    return {
      type: calendarManager.EventType.NORMAL,
      title: title,
      startTime: epochMinToUtcMs(startMin),
      endTime: epochMinToUtcMs(endMin),
      description: '同休日共同计划'
    };
  }

  /** 上下文与权限都到位才有管理器；拿不到时 outcome 说明是"没初始化"还是"用户没给权限"。 */
  private static async manager(): Promise<OpenedManager> {
    const ctx = CalendarGateway.context;
    if (ctx == null) {
      return { mgr: null, outcome: CalendarOutcome.UNAVAILABLE };
    }
    if (!await CalendarGateway.requestPermissions()) {
      return { mgr: null, outcome: CalendarOutcome.DENIED };
    }
    return { mgr: calendarManager.getCalendarManager(ctx), outcome: CalendarOutcome.WRITTEN };
  }

  /** 取"同休日"专属日历：直写与删除都需要它，账户不存在就建一次。 */
  private static async open(): Promise<OpenedCalendar> {
    const opened = await CalendarGateway.manager();
    if (opened.mgr == null) {
      return { cal: null, outcome: opened.outcome };
    }
    const account: calendarManager.CalendarAccount = {
      name: CAL_NAME, type: calendarManager.CalendarType.LOCAL, displayName: CAL_NAME
    };
    try {
      return { cal: await opened.mgr.getCalendar(account), outcome: CalendarOutcome.WRITTEN };
    } catch (e) {
      // 账户不存在（23900003）→ 创建专属日历
      try {
        return { cal: await opened.mgr.createCalendar(account), outcome: CalendarOutcome.WRITTEN };
      } catch (e2) {
        Logger.warn(TAG, 'createCalendar failed: ' + (e2 as Error).message);
        return { cal: null, outcome: CalendarOutcome.UNAVAILABLE };
      }
    }
  }

  /**
   * 请求日历读写权限：全部授予返回 true；任一拒绝或请求异常返回 false
   * （调用方降级为"仅保存在应用内"，不崩溃）。
   */
  static async requestPermissions(): Promise<boolean> {
    const ctx = CalendarGateway.context;
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
}
