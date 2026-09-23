import { calendarManager } from '@kit.CalendarKit';
import { abilityAccessCtrl, common, PermissionRequestResult, Permissions } from '@kit.AbilityKit';
import { Logger } from 'commons';
import {
  CalendarOutcome, CalendarWriteResult, RemoveOutcome, epochMinToUtcMs
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

/** "同休日"专属日历账户名（本应用唯一受管写入目标）。 */
const CAL_NAME = '同休日';

const TAG = 'CalendarGateway';

/** 没写成的三种说法都不带 eventId。 */
function missed(outcome: CalendarOutcome): CalendarWriteResult {
  return { outcome: outcome, eventId: '' };
}

function written(eventId: number): CalendarWriteResult {
  return { outcome: CalendarOutcome.WRITTEN, eventId: '' + eventId };
}

function exported(eventId: number): CalendarWriteResult {
  return { outcome: CalendarOutcome.EXPORTED, eventId: '' + eventId };
}

/**
 * 系统日历能力门面（阶段 6R.1 按权限边界重写）。
 *
 * 为什么不再是"默认 editEvent"：本机 SDK 26 的 @ohos.calendarManager.d.ts 在 editEvent 上写明
 * "Third-party applications can obtain and modify the events after they requested the
 * READ_WHOLE_CALENDAR permission and the WRITE_WHOLE_CALENDAR permission"，而这两项是 system_basic，
 * 普通应用拿不到。也就是说 editEvent 创建的那份日程，本应用之后既读不到也删不掉——
 * 拿它当"可自动同步的受管日程"用，取消/改期就会留下删不掉的孤儿。
 *
 * 于是分工：
 * - writeEvent：受管写入，addEvent 进应用专属「同休日」日历（普通 WRITE_CALENDAR 即可增删改），
 *   这条是默认路径，"要不要写进系统日历"由用户在应用内的开关当面决定；
 * - exportEvent：editEvent 只是"导出"，日程之后归系统日历，本应用不承诺再动它；
 * - removeEvent/purgeManagedCalendar：返回结构化结果，删不动就让调用方留着重试信息。
 *
 * 任何一步失败都归一成枚举，绝不向调用方抛设备异常。
 */
export class CalendarGateway {
  private static context: common.UIAbilityContext | null = null;

  /** 保存 UIAbility 上下文（权限请求与 CalendarManager 都需要）；未初始化时能力视为不可用。 */
  static init(context: common.UIAbilityContext): void {
    CalendarGateway.context = context;
  }

  /** 受管写入：写进应用专属「同休日」日历，返回的 id 之后可改可删。 */
  static async writeEvent(title: string, startMin: number, endMin: number): Promise<CalendarWriteResult> {
    const opened = await CalendarGateway.open();
    if (opened.cal == null) {
      return missed(opened.outcome);
    }
    try {
      const id = await opened.cal.addEvent(CalendarGateway.eventOf(title, startMin, endMin));
      Logger.info(TAG, 'managed event written, id=' + id);
      return written(id);
    } catch (e) {
      Logger.warn(TAG, 'addEvent failed: ' + (e as Error).message);
      return missed(CalendarOutcome.FAILED);
    }
  }

  /**
   * 导出到系统日历：打开系统日程编辑页由用户当面保存。
   * 之后的日程由系统日历管理，本应用只能记住它、改不动它（见类注释的权限口径）。
   */
  static async exportEvent(title: string, startMin: number, endMin: number): Promise<CalendarWriteResult> {
    const opened = await CalendarGateway.manager();
    if (opened.mgr == null) {
      return missed(opened.outcome);
    }
    try {
      // editEvent 挂在 CalendarManager 上：不需要先建好账户，日程落在用户选定的日历里
      const id = await opened.mgr.editEvent(CalendarGateway.eventOf(title, startMin, endMin));
      // 接口口径：<0 = 用户在编辑页取消；0 不会返回；抛错另有其态
      if (id > 0) {
        Logger.info(TAG, 'event exported to system calendar, id=' + id);
        return exported(id);
      }
      Logger.info(TAG, 'event export canceled by user');
      return missed(CalendarOutcome.CANCELED);
    } catch (e) {
      Logger.warn(TAG, 'editEvent failed: ' + (e as Error).message);
      return missed(CalendarOutcome.FAILED);
    }
  }

  /**
   * 删除日程：空 id 视为已经干净；抛错（权限撤回、日程已被用户删掉、id 不归本应用）一律
   * 回 FAILED，由调用方保留 event id 作为重试信息——静默当成删掉了，就是把孤儿留给下一次。
   */
  static async removeEvent(eventId: string): Promise<RemoveOutcome> {
    if (eventId === '') {
      return RemoveOutcome.REMOVED;
    }
    const opened = await CalendarGateway.open();
    if (opened.cal == null) {
      return RemoveOutcome.FAILED;
    }
    try {
      await opened.cal.deleteEvent(Number(eventId));
      return RemoveOutcome.REMOVED;
    } catch (e) {
      Logger.warn(TAG, 'deleteEvent degraded: ' + (e as Error).message);
      return RemoveOutcome.FAILED;
    }
  }

  /**
   * 清空应用专属日历里的全部日程（"清空我的全部数据"用）。
   *
   * 逐条 deleteEvents 而不是 deleteCalendar 整本账户：SDK 只写明 deleteCalendar 删除
   * "指定的 Calendar 对象"，是否连带删掉其中日程缺证据，不能拿用户的清理承诺赌它。
   * 日历账户本身留着（下次写入还要用），所以 true 只表示"日程已清空或本来就没有"。
   */
  static async purgeManagedCalendar(): Promise<boolean> {
    const opened = await CalendarGateway.open();
    if (opened.cal == null) {
      return false;
    }
    try {
      const events = await opened.cal.getEvents();
      const ids: number[] = [];
      for (let i = 0; i < events.length; i++) {
        const evId: number | undefined = events[i].id;
        if (evId != null && evId > 0) {
          ids.push(evId);
        }
      }
      if (ids.length === 0) {
        return true;
      }
      await opened.cal.deleteEvents(ids);
      Logger.info(TAG, 'managed calendar purged, events=' + ids.length);
      return true;
    } catch (e) {
      Logger.warn(TAG, 'purgeManagedCalendar degraded: ' + (e as Error).message);
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

  /** 受管写入与删除都需要「同休日」日历，账户不存在就建一次。 */
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
   *
   * 只申请 READ/WRITE_CALENDAR（normal 级）：应用专属日历的增删改这两条就够了。
   * READ/WRITE_WHOLE_CALENDAR 是 system_basic，普通应用申请不到，所以设计上不依赖它们。
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
