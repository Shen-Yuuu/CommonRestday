import { describe, it, expect } from '@ohos/hypium';
import { PlanRow, ScheduleRepo } from 'data';
import {
  CONFLICT_REASON_MIXED, CONFLICT_REASON_MY_COURSE, CONFLICT_REASON_PARTNER_CHANGED,
  CONFLICT_SOURCE_BOTH, CONFLICT_SOURCE_MINE, CONFLICT_SOURCE_PARTNER, ConflictHint,
  conflictSignature, decodeConflictHint, encodeConflictHint, Interval
} from 'domain';
import {
  CalendarCapability, CalendarOutcome, CalendarState, CalendarWriteResult, CleanupReport,
  CreatePlanOptions, CreatePlanResult, DEFAULT_PLAN_MIN, LOCAL_ONLY_NOTE, MIN_PLAN_MIN, PlanCapabilities,
  PlanUseCase, RECOMPUTE_COUNT_KEY, ReminderCapability, RemoveOutcome,
  addCleanupReport, calendarBadgeOf, calendarStateAfterCleanup, canExportToCalendar,
  canRetryCalendarSync, canRetryCleanup, clearAllMessageOf, cleanupMessageOf, defaultDraft, emptyCleanupReport,
  hasCleanupLeft, isAppManagedEvent, isOnSystemCalendar, normalizeCalendarState, planDraftError
} from 'feature';

/**
 * 窗口 → 本地计划 → 系统日历的编排（阶段 2 Task 2.2 + 冲突四动作 Task 2.3），
 * 以及阶段 6R.1 的日历生命周期口径：
 *
 * 1. 受管写入（应用专属「同休日」日历）才是默认路径，editEvent 只是"导出"；
 * 2. 取消/改期/清空**不吞失败**：删不动的日程与提醒句柄必须留在计划行里，状态标成
 *    CLEANUP_PENDING，重试（手动入口或启动清扫）才有对象可清；
 * 3. 旧投影没清掉就不写新的——同一天两条日程不是"改期成功"；
 * 4. 导出的日程本应用删不动，所以既不试删（可能删错别人的日历），也不自动补第二次导出。
 *
 * 断言只用公开 API：PlanUseCase 的返回值、ScheduleRepo 的三个列表读模型、设备侧同名广播键
 * recomputeCount。日历/提醒通过 PlanCapabilities.bind 换成确定性实现——"日程删不动"
 * "用户拒绝写日历"在真机上不可复现，但它们恰恰决定本地计划该留什么、该说什么。
 * 读不到行时返回 'MISSING'：它不等于任何合法状态，所以断言会响，而不是悄悄跳过。
 */

const DAY = 1440;
/** 各用例占一天，避免共享计划表互相串台。 */
const BASE_DAY = 20000;
/** 读不到计划行时的哨兵值。 */
const MISSING = 'MISSING';

function dayBase(dayOffset: number): number {
  return (BASE_DAY + dayOffset) * DAY;
}

function winStartOf(dayOffset: number): number {
  return dayBase(dayOffset) + 600;
}

/** 按"起点 = 窗口起 + 30 分钟"找回这条用例创建的计划。 */
async function planOf(dayOffset: number): Promise<PlanRow | null> {
  const start = winStartOf(dayOffset) + 30;
  const rows: PlanRow[] = await ScheduleRepo.listActivePlans();
  for (let i = 0; i < rows.length; i++) {
    if (rows[i].start === start) {
      return rows[i];
    }
  }
  return null;
}

async function rowById(id: string): Promise<PlanRow | null> {
  const rows: PlanRow[] = await ScheduleRepo.listActivePlans();
  for (let i = 0; i < rows.length; i++) {
    if (rows[i].id === id) {
      return rows[i];
    }
  }
  return null;
}

/**
 * 从公开读模型里找回一行：活动计划（listActivePlans）+ 带着句柄的行（含 CANCELLED）。
 * 读模型只暴露这两份 + 待清理那份，所以"取消且已经清干净"的行会同时从三份里消失——
 * 那种情况改用 rowGone() 断言，而不是假装还读得到它的状态。
 */
async function anyRowById(id: string): Promise<PlanRow | null> {
  const active: PlanRow[] = await ScheduleRepo.listActivePlans();
  for (let i = 0; i < active.length; i++) {
    if (active[i].id === id) {
      return active[i];
    }
  }
  const withHandles: PlanRow[] = await ScheduleRepo.listPlansCarryingHandles();
  for (let i = 0; i < withHandles.length; i++) {
    if (withHandles[i].id === id) {
      return withHandles[i];
    }
  }
  return null;
}

/** 系统侧什么都不剩的行：三份读模型都再也点不到它，清扫与重试因此都没有对象。 */
async function rowGone(id: string): Promise<boolean> {
  if ((await rowById(id)) != null) {
    return false;
  }
  const lists: PlanRow[][] = [await ScheduleRepo.listPlansCarryingHandles(),
    await ScheduleRepo.listOrphanProjectionPlans()];
  for (let i = 0; i < lists.length; i++) {
    const rows: PlanRow[] = lists[i];
    for (let j = 0; j < rows.length; j++) {
      if (rows[j].id === id) {
        return false;
      }
    }
  }
  return true;
}

async function calendarStateOf(id: string): Promise<string> {
  const row = await anyRowById(id);
  return row == null ? MISSING : row.calendarState;
}

async function eventIdOf(id: string): Promise<string> {
  const row = await anyRowById(id);
  return row == null ? MISSING : row.myEventId;
}

async function reminderIdOf(id: string): Promise<number> {
  const row = await anyRowById(id);
  return row == null ? -999 : row.reminderId;
}

async function existsInActiveList(id: string): Promise<boolean> {
  return (await rowById(id)) != null;
}

/** 改期后计划还剩在原时间吗：读不到行时给出一个不可能出现的时间值。 */
async function startOf(id: string): Promise<number> {
  const row = await anyRowById(id);
  return row == null ? -1 : row.start;
}

async function endOf(id: string): Promise<number> {
  const row = await anyRowById(id);
  return row == null ? -1 : row.end;
}

/** 库里那条 conflict_hint 解不开时，用 MISSING 当原因码，让断言响。 */
async function hintOfPlan(id: string): Promise<ConflictHint> {
  const row = await rowById(id);
  const empty: ConflictHint = {
    reasonCode: MISSING, sourceLevel: '', overlapStartMin: 0, overlapEndMin: 0,
    altStartMin: 0, altEndMin: 0, kept: false
  };
  if (row == null) {
    return empty;
  }
  const h = decodeConflictHint(row.conflictHint);
  return h == null ? empty : h;
}

/** 造一条"已经带上冲突检测结果"的计划：重算落库后的真实形状，动作分支才好复现。 */
async function mkConflictPlan(id: string, start: number, end: number, calendarState: string,
  eventId: string, reminderId: number, hint: string, status?: string): Promise<void> {
  const row: PlanRow = {
    id: id, title: '一起看电影', kind: 'movie', start: start, end: end,
    status: status == null ? 'CONFLICT' : status, createdBy: 'ME', windowRef: '',
    conflictHint: hint, myEventId: eventId, reminderId: reminderId, updatedAt: 0,
    calendarState: calendarState, syncState: 'LOCAL_ONLY'
  };
  await ScheduleRepo.upsertPlan(row);
}

/** 按持久格式写一条冲突记录（原因 + 受影响区间 + 替代窗口 + 是否已"保留原计划"）。 */
function hintOf(reasonCode: string, sourceLevel: string, overlapStart: number, overlapEnd: number,
  altStart: number, altEnd: number, kept: boolean): string {
  const h: ConflictHint = {
    reasonCode: reasonCode, sourceLevel: sourceLevel,
    overlapStartMin: overlapStart, overlapEndMin: overlapEnd,
    altStartMin: altStart, altEndMin: altEnd, kept: kept
  };
  return encodeConflictHint(h);
}

function recomputes(): number {
  return AppStorage.get<number>(RECOMPUTE_COUNT_KEY) ?? 0;
}

/** 确定性日历能力：按预设结果应答，并记下写入那一刻本地表的形状。 */
class FakeCalendar implements CalendarCapability {
  /** 受管写入的预设结果。 */
  writeOutcome: CalendarOutcome = CalendarOutcome.WRITTEN;
  /** 导出的预设结果。 */
  exportOutcome: CalendarOutcome = CalendarOutcome.EXPORTED;
  /** 删除的预设结果：FAILED = 权限被撤回/日程归系统日历管，句柄必须留着重试。 */
  removeOutcome: RemoveOutcome = RemoveOutcome.REMOVED;
  /** 整本清空专属日历的结果。 */
  purgeResult: boolean = true;
  /** 每次写成功依次发一个事件 id：改期后应当拿到新 id，旧 id 进 removed。 */
  eventIds: string[] = ['evt-9001'];
  /** true = 模拟日历应用整个抛错（不是"用户拒绝"，是没答复）。 */
  thrown: boolean = false;
  calls: number = 0;
  /** 每次受管写入收到的起止，用来断言日历按"新时间"被写入。 */
  writeTimes: string[] = [];
  /** 写入被调用时，这条计划已经落在库里的 calendar_state。 */
  stateAtWrite: string = MISSING;
  removed: string[] = [];
  exports: number = 0;
  exportTimes: string[] = [];
  purges: number = 0;

  async write(title: string, startMin: number, endMin: number): Promise<CalendarWriteResult> {
    this.calls = this.calls + 1;
    this.writeTimes.push(startMin + '-' + endMin);
    const rows: PlanRow[] = await ScheduleRepo.listActivePlans();
    for (let i = 0; i < rows.length; i++) {
      if (rows[i].start === startMin && rows[i].end === endMin) {
        this.stateAtWrite = rows[i].calendarState;
      }
    }
    if (this.thrown) {
      throw new Error('calendar app died');
    }
    if (this.writeOutcome !== CalendarOutcome.WRITTEN) {
      return { outcome: this.writeOutcome, eventId: '' };
    }
    const idx = this.calls <= this.eventIds.length ? this.calls - 1 : this.eventIds.length - 1;
    return { outcome: CalendarOutcome.WRITTEN, eventId: this.eventIds[idx] };
  }

  async exportToSystem(title: string, startMin: number, endMin: number): Promise<CalendarWriteResult> {
    this.exports = this.exports + 1;
    this.exportTimes.push(startMin + '-' + endMin);
    if (this.exportOutcome !== CalendarOutcome.EXPORTED) {
      return { outcome: this.exportOutcome, eventId: '' };
    }
    return { outcome: CalendarOutcome.EXPORTED, eventId: 'ext-7001' };
  }

  async remove(eventId: string): Promise<RemoveOutcome> {
    this.removed.push(eventId);
    return this.removeOutcome;
  }

  async purgeManagedCalendar(): Promise<boolean> {
    this.purges = this.purges + 1;
    return this.purgeResult;
  }
}

/** 确定性提醒能力：reminderId 设成负数即模拟"通知没开启，发布失败"。 */
class FakeReminder implements ReminderCapability {
  reminderId: number = 77;
  published: number = 0;
  /** 每次发布收到的起始时间：改期后提醒要跟着挪到新起点。 */
  publishedStarts: number[] = [];
  canceled: number[] = [];
  /** true = 取消失败（提醒句柄已失效/系统异常）：句柄得留着，不能当已经取消。 */
  cancelFails: boolean = false;
  throwOnPublish: boolean = false;

  async publish(title: string, startMin: number): Promise<number> {
    this.published = this.published + 1;
    this.publishedStarts.push(startMin);
    if (this.throwOnPublish) {
      throw new Error('notifications disabled');
    }
    return this.reminderId;
  }

  async cancel(reminderId: number): Promise<boolean> {
    this.canceled.push(reminderId);
    return !this.cancelFails;
  }
}

/** 装上确定性能力，返回两个桩（清理路径与编排路径共用同一份，注入一次就够）。 */
function bind(): [FakeCalendar, FakeReminder] {
  const cal = new FakeCalendar();
  const rem = new FakeReminder();
  PlanCapabilities.bind(cal, rem);
  return [cal, rem];
}

export default function planUseCaseTest() {
  describe('planUseCase', () => {

    it('invalid_draft_writes_nothing_and_recomputes_nothing', 0, async () => {
      const pair = bind();
      const cal = pair[0];
      const ws = winStartOf(1);
      const we = ws + 180;
      const before = recomputes();
      // 越界：起点落在窗口之前
      const out = await PlanUseCase.createPlan(ws, we, '吃饭', 'meal', ws - 60, ws + 30);
      // 空标题
      const blank = await PlanUseCase.createPlan(ws, we, '   ', 'meal', ws + 30, ws + 90);
      // 短于最短时长
      const tiny = await PlanUseCase.createPlan(ws, we, '吃饭', 'meal', ws + 30, ws + 40);
      expect(out.ok).assertFalse();
      expect(out.error).assertEqual('计划时间需在窗口范围内');
      expect(blank.error).assertEqual('请填写计划标题');
      expect(tiny.error).assertEqual('计划时长至少 ' + MIN_PLAN_MIN + ' 分钟');
      // 非法草稿连系统都不该惊动
      expect(cal.calls).assertEqual(0);
      expect(recomputes()).assertEqual(before);
    });

    it('local_plan_is_persisted_before_the_calendar_is_written', 0, async () => {
      const pair = bind();
      const cal = pair[0];
      const ws = winStartOf(2);
      const r = await PlanUseCase.createPlan(ws, ws + 180, '看电影', 'movie', ws + 30, ws + 90);
      expect(r.ok).assertTrue();
      // 请日历写入时，本地已经有了这条 PENDING 计划：日历只是它的一份投影
      expect(cal.stateAtWrite).assertEqual(CalendarState.PENDING);
      // 受管写入：状态是 MANAGED_WRITTEN（改期/取消由本应用自动同步），并且留住了 event id
      expect(r.calendarState).assertEqual(CalendarState.MANAGED_WRITTEN);
      expect(calendarBadgeOf(r.calendarState)).assertEqual('');
      expect(isAppManagedEvent(r.calendarState)).assertTrue();
      const id = r.planId;
      expect(await calendarStateOf(id)).assertEqual(CalendarState.MANAGED_WRITTEN);
      expect(await eventIdOf(id)).assertEqual('evt-9001');
    });

    it('refused_or_missing_calendar_keeps_the_local_plan', 0, async () => {
      const ws = winStartOf(3);
      const pair = bind();
      const cal = pair[0];
      cal.writeOutcome = CalendarOutcome.CANCELED;
      const a = await PlanUseCase.createPlan(ws, ws + 180, '短途旅行', 'trip', ws + 30, ws + 90);
      expect(a.ok).assertTrue();
      expect(a.calendarState).assertEqual(CalendarState.LOCAL_ONLY);
      expect(isOnSystemCalendar(a.calendarState)).assertFalse();
      // 没写成的计划不留假的事件 id，否则取消/改期会去删一条不存在的日程
      expect(await eventIdOf(a.planId)).assertEqual('');
      expect(cal.calls).assertEqual(1);

      cal.writeOutcome = CalendarOutcome.DENIED;
      const b = await PlanUseCase.createPlan(ws, ws + 180, '共同自习', 'study', ws + 120, ws + 180);
      expect(b.calendarState).assertEqual(CalendarState.LOCAL_ONLY);

      cal.writeOutcome = CalendarOutcome.UNAVAILABLE;
      const c = await PlanUseCase.createPlan(ws, ws + 300, '办证体检', 'errand', ws + 240, ws + 285);
      expect(c.ok).assertTrue();
      expect(c.calendarState).assertEqual(CalendarState.UNSUPPORTED);
      expect(calendarBadgeOf(c.calendarState)).assertEqual('这台设备没有可用日历');
      // 设备压根没有日历能力时不给重试入口（点了也不会成，只是打扰）
      expect(canRetryCalendarSync(CalendarState.UNSUPPORTED)).assertFalse();
    });

    it('opting_out_of_the_calendar_never_touches_it', 0, async () => {
      const pair = bind();
      const cal = pair[0];
      const ws = winStartOf(4);
      const off: CreatePlanOptions = { writeToCalendar: false };
      const r = await PlanUseCase.createPlan(ws, ws + 180, '回父母家', 'parents', ws + 30, ws + 90, off);
      expect(r.ok).assertTrue();
      expect(cal.calls).assertEqual(0);
      // "从没请求过日历"与"请求了但没写成"是两件事，徽标说法也一样
      expect(r.calendarState).assertEqual(CalendarState.NOT_REQUESTED);
      expect(await calendarStateOf(r.planId)).assertEqual(CalendarState.NOT_REQUESTED);
      expect(calendarBadgeOf(r.calendarState)).assertEqual(LOCAL_ONLY_NOTE);
      // 但补写与导出的入口都还在：用户改主意时不该被卡住
      expect(canRetryCalendarSync(r.calendarState)).assertTrue();
      expect(canExportToCalendar(r.calendarState)).assertTrue();
    });

    it('double_submit_persists_exactly_one_plan', 0, async () => {
      const pair = bind();
      const cal = pair[0];
      const ws = winStartOf(5);
      // 第一次还没走完（正等日历写入），用户又点了一次
      const first = PlanUseCase.createPlan(ws, ws + 180, '接送孩子', 'pickup', ws + 30, ws + 90);
      const second = await PlanUseCase.createPlan(ws, ws + 180, '接送孩子', 'pickup', ws + 30, ws + 90);
      expect(second.ok).assertFalse();
      expect(second.error).assertEqual('正在创建，请稍候');
      const r1 = await first;
      expect(r1.ok).assertTrue();
      expect(cal.calls).assertEqual(1);
      const rows: PlanRow[] = await ScheduleRepo.listActivePlans();
      let hits = 0;
      for (let i = 0; i < rows.length; i++) {
        if (rows[i].start === ws + 30) {
          hits = hits + 1;
        }
      }
      expect(hits).assertEqual(1);
      // 闩释放后还能再创建：不能把按钮永久锁死
      const again = await PlanUseCase.createPlan(ws, ws + 180, '一起吃饭', 'meal', ws + 120, ws + 180);
      expect(again.ok).assertTrue();
    });

    it('reminder_publish_failure_does_not_block_the_plan', 0, async () => {
      const pair = bind();
      const rem = pair[1];
      rem.reminderId = -1;
      const ws = winStartOf(6);
      const r = await PlanUseCase.createPlan(ws, ws + 180, '自定义', 'custom', ws + 30, ws + 90);
      expect(r.ok).assertTrue();
      expect(rem.published).assertEqual(1);
      expect(await reminderIdOf(r.planId)).assertEqual(-1);
    });

    it('reopen_gets_the_same_draft_and_never_leaves_pending_rows', 0, async () => {
      const ws = winStartOf(7);
      const we = ws + 180;
      const draft = defaultDraft(ws, we, '一起吃饭', 'meal');
      const again = defaultDraft(ws, we, '一起吃饭', 'meal');
      // 页面被回收后重开、或换窗口再回来，都不该沿用上一次的起止
      expect(draft.start).assertEqual(again.start);
      expect(draft.end).assertEqual(again.end);
      expect(draft.end - draft.start).assertEqual(120);
      // 整段窗口不足最短时长：按窗口原样给出，由校验判非法（而不是造出一段窗口外的计划）
      const short = defaultDraft(ws, ws + 10, '一起吃饭', 'meal');
      expect(short.end).assertEqual(ws + 10);
      expect(planDraftError(short, ws, ws + 10)).assertEqual('计划时长至少 ' + MIN_PLAN_MIN + ' 分钟');

      const pair = bind();
      pair[0].writeOutcome = CalendarOutcome.CANCELED;
      const created = await PlanUseCase.createPlan(ws, we, '一起吃饭', 'meal', draft.start, draft.end);
      expect(created.ok).assertTrue();
      // 返回时状态已是终值：恢复页面不会再看到"等写入"的孤儿计划
      const rows: PlanRow[] = await ScheduleRepo.listActivePlans();
      let pending = 0;
      for (let i = 0; i < rows.length; i++) {
        if (rows[i].calendarState === CalendarState.PENDING) {
          pending = pending + 1;
        }
      }
      expect(pending).assertEqual(0);
    });

    it('default_draft_start_steps_out_of_my_own_rhythm', 0, () => {
      const base = dayBase(9);
      const we = base + 3 * DAY;
      // 旅行通道口径：这三天没有班次，所以窗口从 00:00 就开始，但睡觉时间仍然不能安排
      const sleep: Interval[] = [
        { start: base, end: base + 420, tag: 'SLEEP' },
        { start: base + 1350, end: base + DAY, tag: 'SLEEP' },
        { start: base + DAY, end: base + DAY + 420, tag: 'SLEEP' },
        { start: base + DAY + 1350, end: base + 2 * DAY, tag: 'SLEEP' },
        { start: base + 2 * DAY, end: base + 2 * DAY + 420, tag: 'SLEEP' },
        { start: base + 2 * DAY + 1350, end: we, tag: 'SLEEP' }
      ];
      const d = defaultDraft(base, we, '一起吃饭', 'meal', sleep);
      // 起点落到起床时刻，而不是 00:00——否则"选窗口 → 不改动参数直接保存"必然自己跟自己冲突
      expect(d.start).assertEqual(base + 420);
      expect(d.end - d.start).assertEqual(DEFAULT_PLAN_MIN);
      expect(planDraftError(d, base, we)).assertEqual('');
      // 作息之外还压着一段已有计划时继续向后找，不是只避第一段
      const withPlan: Interval[] = sleep.concat([{ start: base + 420, end: base + 480, tag: 'PLAN' }]);
      expect(defaultDraft(base, we, '一起吃饭', 'meal', withPlan).start).assertEqual(base + 480);
      // 整段窗口都在作息里：退回窗口起点，交给既有的冲突解释链，不造一段窗口外的计划
      const shortDraft = defaultDraft(base, base + 60, '一起吃饭', 'meal', sleep);
      expect(shortDraft.start).assertEqual(base);
      expect(shortDraft.end).assertEqual(base + 60);
      // 拿不到不可用集（离线/取数失败）时口径与改动前完全一致
      expect(defaultDraft(base, we, '一起吃饭', 'meal', null).start).assertEqual(base);
    });

    it('calendar_gateway_exception_becomes_a_retryable_state', 0, async () => {
      const pair = bind();
      pair[0].thrown = true;
      pair[1].throwOnPublish = true;
      const ws = winStartOf(8);
      const r = await PlanUseCase.createPlan(ws, ws + 180, '一起吃饭', 'meal', ws + 30, ws + 90);
      // 日历应用抛错不是用户的错，更不该让刚保存的计划消失
      expect(r.ok).assertTrue();
      expect(r.calendarState).assertEqual(CalendarState.FAILED);
      expect(isOnSystemCalendar(r.calendarState)).assertFalse();
      expect(canRetryCalendarSync(r.calendarState)).assertTrue();
      expect(await eventIdOf(r.planId)).assertEqual('');
      // 提醒发布抛错同样静默：没有留下任何"等确认"的孤儿状态
      expect(pair[1].published).assertEqual(1);
      expect(await reminderIdOf(r.planId)).assertEqual(-1);
      expect(pair[0].calls).assertEqual(1);
    });

    it('reschedule_moves_the_plan_and_migrates_the_calendar_event', 0, async () => {
      const base = dayBase(11);
      const pair = bind();
      const cal = pair[0];
      const rem = pair[1];
      cal.eventIds = ['evt-new'];
      const before = recomputes();
      await mkConflictPlan('p-11', base + 600, base + 750, CalendarState.MANAGED_WRITTEN, 'evt-old', 77,
        hintOf(CONFLICT_REASON_MY_COURSE, CONFLICT_SOURCE_MINE, base + 690, base + 750,
          base + 1200, base + 1380, false));

      const r = await PlanUseCase.acceptAlternative('p-11');
      expect(r.ok).assertTrue();
      expect(r.cleanupNote).assertEqual('');
      expect(r.calendarState).assertEqual(CalendarState.MANAGED_WRITTEN);
      // 时长不变、起点对齐替代窗口：改期不是"另起一段"
      expect(await startOf('p-11')).assertEqual(base + 1200);
      expect(await endOf('p-11')).assertEqual(base + 1350);
      // 旧日程删掉、新日程按新时间写入，日历徽标随之消失
      expect(cal.removed.join('|')).assertEqual('evt-old');
      expect(cal.writeTimes.join('|')).assertEqual((base + 1200) + '-' + (base + 1350));
      expect(await eventIdOf('p-11')).assertEqual('evt-new');
      expect(calendarBadgeOf(CalendarState.MANAGED_WRITTEN)).assertEqual('');
      // 提醒也挪到新起点，全程只重算一次
      expect(rem.canceled.join('|')).assertEqual('77');
      expect(rem.publishedStarts.join('|')).assertEqual('' + (base + 1200));
      expect(recomputes() - before).assertEqual(1);

      // 替代窗口比计划短（检测结果已被下一次重算收窄）：新时间收缩进窗口，
      // 而不是照原时长造出一段"窗口外的共同时间"
      await mkConflictPlan('p-11b', base + 60, base + 210, CalendarState.MANAGED_WRITTEN, 'evt-b1', 78,
        hintOf(CONFLICT_REASON_MY_COURSE, CONFLICT_SOURCE_MINE, base + 150, base + 210,
          base + 900, base + 990, false));
      const clipped = await PlanUseCase.acceptAlternative('p-11b');
      expect(clipped.ok).assertTrue();
      expect(await startOf('p-11b')).assertEqual(base + 900);
      expect(await endOf('p-11b')).assertEqual(base + 990);
    });

    it('undeletable_old_event_blocks_the_new_one_and_stays_retryable', 0, async () => {
      const base = dayBase(12);
      const pair = bind();
      const cal = pair[0];
      const rem = pair[1];
      // 权限被撤回：日程删不动、提醒也取消不掉——两个句柄都得留在行里等下一次重试
      cal.removeOutcome = RemoveOutcome.FAILED;
      rem.cancelFails = true;
      const before = recomputes();
      await mkConflictPlan('p-12', base + 600, base + 750, CalendarState.MANAGED_WRITTEN, 'evt-old', 79,
        hintOf(CONFLICT_REASON_PARTNER_CHANGED, CONFLICT_SOURCE_PARTNER, base + 690, base + 750,
          base + 1200, base + 1380, false));

      const r = await PlanUseCase.acceptAlternative('p-12');
      // 本机改期这件事仍然成立；卡住的只是投影
      expect(r.ok).assertTrue();
      expect(r.error).assertEqual('');
      expect(await startOf('p-12')).assertEqual(base + 1200);
      expect(await endOf('p-12')).assertEqual(base + 1350);
      // 关键一条：旧日程没让开，就绝不在旁边写第二条——那是重复日程不是改期
      expect(cal.calls).assertEqual(0);
      expect(r.calendarState).assertEqual(CalendarState.CLEANUP_PENDING);
      // 句柄一个都不能丢：丢了就再也没人清得掉（验收报告 B2 的孤儿来源）
      expect(await eventIdOf('p-12')).assertEqual('evt-old');
      expect(await reminderIdOf('p-12')).assertEqual(79);
      expect(rem.canceled.length).assertEqual(1);
      expect(r.cleanupNote).assertEqual('2 项日历/提醒没清掉，可稍后重试');
      expect(calendarBadgeOf(r.calendarState)).assertEqual('系统日历或提醒仍待清理');
      expect(canRetryCleanup(r.calendarState)).assertTrue();
      expect(canRetryCalendarSync(r.calendarState)).assertFalse();
      expect(recomputes() - before).assertEqual(1);

      // 权限恢复后重试：先删旧的，再补上被挡住的新写入
      cal.removeOutcome = RemoveOutcome.REMOVED;
      cal.eventIds = ['evt-retry'];
      rem.cancelFails = false;
      const t = await PlanUseCase.retryProjection('p-12');
      expect(t.ok).assertTrue();
      expect(t.calendarState).assertEqual(CalendarState.MANAGED_WRITTEN);
      expect(cal.removed.join('|')).assertEqual('evt-old|evt-old');
      expect(cal.writeTimes.join('|')).assertEqual((base + 1200) + '-' + (base + 1350));
      expect(await eventIdOf('p-12')).assertEqual('evt-retry');
      expect(rem.canceled.join('|')).assertEqual('79|79');
      expect(rem.publishedStarts.join('|')).assertEqual('' + (base + 1200));
    });

    it('failed_calendar_write_keeps_the_rescheduled_plan_retryable', 0, async () => {
      const base = dayBase(13);
      const pair = bind();
      const cal = pair[0];
      const rem = pair[1];
      cal.writeOutcome = CalendarOutcome.FAILED;
      const before = recomputes();
      await mkConflictPlan('p-13', base + 600, base + 750, CalendarState.MANAGED_WRITTEN, 'evt-old', 81,
        hintOf(CONFLICT_REASON_MY_COURSE, CONFLICT_SOURCE_MINE, base + 690, base + 750,
          base + 1200, base + 1380, false));

      const r = await PlanUseCase.acceptAlternative('p-13');
      // 旧日程删掉了（清理成功），新日程没写成 → 计划没有系统投影，但不谎报失败
      expect(r.ok).assertTrue();
      expect(r.error).assertEqual('');
      expect(cal.removed.join('|')).assertEqual('evt-old');
      expect(r.calendarState).assertEqual(CalendarState.FAILED);
      expect(isOnSystemCalendar(r.calendarState)).assertFalse();
      expect(await eventIdOf('p-13')).assertEqual('');
      expect(canRetryCalendarSync(r.calendarState)).assertTrue();
      expect(recomputes() - before).assertEqual(1);

      // 用户稍后点"写入日历"：补写走的是新时间，投影与本地计划重新对齐
      cal.writeOutcome = CalendarOutcome.WRITTEN;
      cal.eventIds = ['evt-late'];
      const s = await PlanUseCase.syncToCalendar('p-13');
      expect(s.ok).assertTrue();
      expect(s.calendarState).assertEqual(CalendarState.MANAGED_WRITTEN);
      // 两趟写入都在新时间上：第一趟失败不等于改期没发生
      const newTime = (base + 1200) + '-' + (base + 1350);
      expect(cal.writeTimes.join('|')).assertEqual(newTime + '|' + newTime);
      expect(await eventIdOf('p-13')).assertEqual('evt-late');
      // 补写没有改动任何时间事实，所以不该再触发一次重算
      expect(recomputes() - before).assertEqual(1);
    });

    it('stale_alternative_leaves_the_plan_untouched', 0, async () => {
      const base = dayBase(14);
      const pair = bind();
      const cal = pair[0];
      const before = recomputes();
      // 下一次重算把替代窗口吃掉了（对方又加了课）：hint 里只剩零长度替代
      await mkConflictPlan('p-14a', base + 600, base + 750, CalendarState.MANAGED_WRITTEN, 'evt-old', 82,
        hintOf(CONFLICT_REASON_MY_COURSE, CONFLICT_SOURCE_MINE, base + 690, base + 750, 0, 0, false));
      // 替代窗口比最短时长还短：照搬会造出一个没人能约的计划的碎片
      await mkConflictPlan('p-14b', base + 300, base + 450, CalendarState.MANAGED_WRITTEN, 'evt-old2', 83,
        hintOf(CONFLICT_REASON_MY_COURSE, CONFLICT_SOURCE_MINE, base + 390, base + 450,
          base + 900, base + 910, false));
      // 冲突已经消失（课被删了）：不能拿旧 hint 改期
      await mkConflictPlan('p-14c', base + 60, base + 210, CalendarState.MANAGED_WRITTEN, 'evt-old3', 84,
        '', 'OK');

      const a = await PlanUseCase.acceptAlternative('p-14a');
      const b = await PlanUseCase.acceptAlternative('p-14b');
      const c = await PlanUseCase.acceptAlternative('p-14c');
      const gone = await PlanUseCase.acceptAlternative('p-14-nonexistent');
      const why = '替代窗口已失效，请重新选择时间';
      expect(a.ok).assertFalse();
      expect(c.ok).assertFalse();
      expect(gone.ok).assertFalse();
      expect(a.error).assertEqual(why);
      expect(c.error).assertEqual(why);
      expect(gone.error).assertEqual(why);
      expect(b.error).assertEqual('替代窗口太短，请重新选择时间');
      // 三种"点不动"都留在原时间，系统日历一次也没被打扰
      expect(await startOf('p-14a')).assertEqual(base + 600);
      expect(await endOf('p-14a')).assertEqual(base + 750);
      expect(await startOf('p-14b')).assertEqual(base + 300);
      expect(cal.calls).assertEqual(0);
      expect(cal.removed.length).assertEqual(0);
      expect(recomputes()).assertEqual(before);
    });

    it('keep_original_plan_marks_the_conflict_and_nothing_else', 0, async () => {
      const base = dayBase(15);
      const pair = bind();
      const cal = pair[0];
      const before = recomputes();
      const stored = hintOf(CONFLICT_REASON_MIXED, CONFLICT_SOURCE_BOTH, base + 690, base + 750,
        base + 1200, base + 1380, false);
      await mkConflictPlan('p-15', base + 600, base + 750, CalendarState.MANAGED_WRITTEN, 'evt-y', 85, stored);

      expect(await PlanUseCase.keepOriginalPlan('p-15')).assertTrue();
      const h = await hintOfPlan('p-15');
      expect(h.kept).assertTrue();
      // 只加了一个标记：原因、受影响区间、替代窗口、时间、状态全都不动
      const prev = decodeConflictHint(stored);
      expect(prev != null).assertTrue();
      expect(conflictSignature(h)).assertEqual(conflictSignature(prev as ConflictHint));
      expect(await startOf('p-15')).assertEqual(base + 600);
      expect(await endOf('p-15')).assertEqual(base + 750);
      // "保留"没有任何时间事实变化：不惊动日历，也不触发重算（标记由检测侧按签名结转）
      expect(cal.calls).assertEqual(0);
      expect(recomputes()).assertEqual(before);
      // 再点一次是幂等的
      expect(await PlanUseCase.keepOriginalPlan('p-15')).assertTrue();
      // 没有冲突记录的计划无从标记：返回 false，UI 不该报"已保留"
      await mkConflictPlan('p-15x', base + 30, base + 180, CalendarState.NOT_REQUESTED, '', 86, '');
      expect(await PlanUseCase.keepOriginalPlan('p-15x')).assertFalse();
      expect(await PlanUseCase.keepOriginalPlan('p-15-nonexistent')).assertFalse();
    });

    it('cancel_removes_the_managed_event_and_the_reminder', 0, async () => {
      const base = dayBase(16);
      const pair = bind();
      const cal = pair[0];
      const rem = pair[1];
      const ws = base + 600;
      const first = await PlanUseCase.createPlan(ws, ws + 300, '一起看展', 'movie', ws + 60, ws + 210);
      expect(first.ok).assertTrue();
      const second = await PlanUseCase.createPlan(ws, ws + 300, '一起买菜', 'meal', ws + 240, ws + 285);
      expect(second.ok).assertTrue();
      expect(cal.removed.length).assertEqual(0);
      // 取消前先确认它真的在日历上：否则"删掉了"这句话没有指涉对象
      expect(await calendarStateOf(first.planId)).assertEqual(CalendarState.MANAGED_WRITTEN);
      expect(await eventIdOf(first.planId)).assertEqual('evt-9001');
      expect(await reminderIdOf(first.planId)).assertEqual(77);

      const before = recomputes();
      const r = await PlanUseCase.cancelPlan(first.planId);
      expect(r.ok).assertTrue();
      expect(r.error).assertEqual('');
      expect(r.cleanupNote).assertEqual('');
      // 取消后不再是活动计划：这个时段重新变成共同空闲（列表读模型据此过滤）
      expect(await existsInActiveList(first.planId)).assertFalse();
      expect(await existsInActiveList(second.planId)).assertTrue();
      expect(cal.removed.join('|')).assertEqual('evt-9001');
      expect(rem.canceled.join('|')).assertEqual('77');
      // 清干净之后这条行再从所有读模型里消失：日程与提醒都没有残留可被认领（B2 的口径）
      expect(await rowGone(first.planId)).assertTrue();
      expect(recomputes() - before).assertEqual(1);
    });

    it('cancel_reports_leftovers_and_keeps_the_handles_for_the_sweep', 0, async () => {
      const base = dayBase(17);
      const pair = bind();
      const cal = pair[0];
      const rem = pair[1];
      cal.removeOutcome = RemoveOutcome.FAILED;
      rem.cancelFails = true;
      const ws = base + 600;
      const created = await PlanUseCase.createPlan(ws, ws + 300, '一起看展', 'movie', ws + 60, ws + 210);
      expect(created.ok).assertTrue();

      const r = await PlanUseCase.cancelPlan(created.planId);
      // 本机一定取消：谎报"取消失败"只会换来一次重复提交
      expect(r.ok).assertTrue();
      expect(await existsInActiveList(created.planId)).assertFalse();
      // 但系统侧这两样还在，句柄必须留着——CANCELLED 行不在列表里，只有清扫会再试
      expect(r.calendarState).assertEqual(CalendarState.CLEANUP_PENDING);
      expect(await eventIdOf(created.planId)).assertEqual('evt-9001');
      expect(await reminderIdOf(created.planId)).assertEqual(77);
      expect(r.cleanupNote).assertEqual('2 项日历/提醒没清掉，可稍后重试');

      // 权限恢复后的启动清扫把它带走
      cal.removeOutcome = RemoveOutcome.REMOVED;
      rem.cancelFails = false;
      const report = await PlanUseCase.sweepPendingProjections();
      expect(report != null).assertTrue();
      const rep = report as CleanupReport;
      expect(rep.eventsPending).assertEqual(0);
      expect(rep.remindersPending).assertEqual(0);
      expect(rep.eventsRemoved).assertEqual(1);
      // 扫干净后句柄归零、行也退出所有读模型：下次启动没有对象可清
      expect(await rowGone(created.planId)).assertTrue();
      // 第二趟没有残留可清：清扫不会反复惊动日历
      expect(await PlanUseCase.sweepPendingProjections()).assertNull();
    });

    it('exported_events_are_never_auto_deleted_but_are_reported', 0, async () => {
      const base = dayBase(18);
      const pair = bind();
      const cal = pair[0];
      // editEvent 交出去的日程（普通权限删不动）：试删可能删错别人日历里的条目，所以一律不试
      await mkConflictPlan('p-18', base + 600, base + 750, CalendarState.EXTERNAL_UNMANAGED, 'ext-7001', -1,
        '', 'OK');
      expect(isOnSystemCalendar(CalendarState.EXTERNAL_UNMANAGED)).assertTrue();
      expect(isAppManagedEvent(CalendarState.EXTERNAL_UNMANAGED)).assertFalse();
      expect(calendarBadgeOf(CalendarState.EXTERNAL_UNMANAGED))
        .assertEqual('已在系统日历，之后由系统日历管理');

      const r = await PlanUseCase.cancelPlan('p-18');
      expect(r.ok).assertTrue();
      expect(cal.removed.length).assertEqual(0);
      expect(r.cleanupNote).assertEqual('1 条导出的日程由系统日历管理，请到系统日历里删除');
      // 状态如实留"由系统日历管理"，但 id 不再留着重试（重试也删不动，只会每趟都报一次）：
      // 于是这条取消后的行退出所有读模型，只有给用户的那句话还留着这件事
      expect(await rowGone('p-18')).assertTrue();
      expect(await PlanUseCase.sweepPendingProjections()).assertNull();

      // 受管日程已经在日历上时不给导出入口：那等于拿能管的换一条不能管的
      const ws = base + 2000;
      const managed = await PlanUseCase.createPlan(ws, ws + 300, '一起吃饭', 'meal', ws + 60, ws + 210);
      expect(managed.calendarState).assertEqual(CalendarState.MANAGED_WRITTEN);
      const refused = await PlanUseCase.exportToCalendar(managed.planId);
      expect(refused.ok).assertFalse();
      expect(refused.error).assertEqual('这条计划已经在系统日历里了');
      expect(cal.exports).assertEqual(0);
      expect(await eventIdOf(managed.planId)).assertEqual('evt-9001');

      // 没写进日历的计划才允许导出：导出后状态换成"归系统日历管"，并记下 id 只为如实播报
      const local = await PlanUseCase.createPlan(ws, ws + 300, '一起遛弯', 'custom', ws + 240, ws + 285,
        { writeToCalendar: false });
      const ex = await PlanUseCase.exportToCalendar(local.planId);
      expect(ex.ok).assertTrue();
      expect(ex.calendarState).assertEqual(CalendarState.EXTERNAL_UNMANAGED);
      expect(cal.exportTimes.join('|')).assertEqual((ws + 240) + '-' + (ws + 285));
      expect(await eventIdOf(local.planId)).assertEqual('ext-7001');
      // 导出过的那条不再给第二次导出（也不给受管补写：两条会同时留在日历上）
      expect(canExportToCalendar(ex.calendarState)).assertFalse();
      expect(canRetryCalendarSync(ex.calendarState)).assertFalse();
    });

    it('sweep_only_touches_leftovers_never_live_projections', 0, async () => {
      const base = dayBase(19);
      const pair = bind();
      const cal = pair[0];
      // 一条正常在日历上的活动计划 + 一条"待清理"的活动计划
      await mkConflictPlan('p-19-live', base + 600, base + 750, CalendarState.MANAGED_WRITTEN, 'evt-live', 90,
        '', 'OK');
      await mkConflictPlan('p-19-pending', base + 2000, base + 2150, CalendarState.CLEANUP_PENDING,
        'evt-stuck', 91, '', 'OK');
      cal.eventIds = ['evt-refill'];

      const report = await PlanUseCase.sweepPendingProjections();
      expect(report != null).assertTrue();
      // 只清那一条待清理的：正常投影被误删就是"日程凭空消失"的事故
      expect(cal.removed.join('|')).assertEqual('evt-stuck');
      // 待清理的活动计划清干净后要补上它欠的那条日程（改期被挡住的那一次）
      expect(cal.writeTimes.join('|')).assertEqual((base + 2000) + '-' + (base + 2150));
      expect(await calendarStateOf('p-19-pending')).assertEqual(CalendarState.MANAGED_WRITTEN);
      expect(await eventIdOf('p-19-pending')).assertEqual('evt-refill');
      expect(await calendarStateOf('p-19-live')).assertEqual(CalendarState.MANAGED_WRITTEN);
      expect(await eventIdOf('p-19-live')).assertEqual('evt-live');
      expect((report as CleanupReport).eventsRemoved).assertEqual(1);
    });

    it('cleanup_report_states_are_a_single_source_of_truth', 0, async () => {
      // 旧版本把 editEvent 与直写都记成 'WRITTEN'：如今只能保守归一成"归系统日历管"
      expect(normalizeCalendarState('WRITTEN')).assertEqual(CalendarState.EXTERNAL_UNMANAGED);
      expect(normalizeCalendarState('DECLINED')).assertEqual(CalendarState.NOT_REQUESTED);
      expect(normalizeCalendarState(CalendarState.CLEANUP_PENDING)).assertEqual(CalendarState.CLEANUP_PENDING);
      expect(calendarBadgeOf('WRITTEN')).assertEqual('已在系统日历，之后由系统日历管理');

      const none = emptyCleanupReport();
      expect(hasCleanupLeft(none)).assertFalse();
      expect(cleanupMessageOf(none)).assertEqual('');
      // 全清干净 → 回调用方给的目标态（取消给 LOCAL_ONLY）
      expect(calendarStateAfterCleanup(none, CalendarState.LOCAL_ONLY)).assertEqual(CalendarState.LOCAL_ONLY);
      // 只剩删不掉的"外部日程" → 不谎报干净，标成由系统日历管理
      const external = emptyCleanupReport();
      external.eventsExternal = 2;
      expect(calendarStateAfterCleanup(external, CalendarState.LOCAL_ONLY))
        .assertEqual(CalendarState.EXTERNAL_UNMANAGED);
      expect(cleanupMessageOf(external)).assertEqual('2 条导出的日程由系统日历管理，请到系统日历里删除');
      // 删不动的句柄优先：那才是还能挽回的那部分
      const pending = emptyCleanupReport();
      pending.eventsPending = 1;
      pending.remindersRemoved = 1;
      expect(calendarStateAfterCleanup(pending, CalendarState.LOCAL_ONLY))
        .assertEqual(CalendarState.CLEANUP_PENDING);
      expect(cleanupMessageOf(pending)).assertEqual('1 项日历/提醒没清掉，可稍后重试');
      // 批量清理合并计数（清空数据那趟走的就是这条口径）
      const total = emptyCleanupReport();
      addCleanupReport(total, external);
      addCleanupReport(total, pending);
      expect(total.eventsExternal).assertEqual(2);
      expect(total.eventsPending).assertEqual(1);
      expect(total.remindersRemoved).assertEqual(1);
      expect(hasCleanupLeft(total)).assertTrue();
    });

    /**
     * 「清空我的全部数据」给用户的那句话（ProfileSettingsService.clearAllData 的返回口径）。
     *
     * 清空动作本身是删用户真机数据的破坏性操作，离线跑不了、插桩也不该在用户设备上执行一次，
     * 所以这里钉住"能被谎报的那一半"：本机表清了就等于系统侧清了没有。
     */
    it('clear_all_message_never_claims_the_system_side_is_clean', 0, async () => {
      const clean = emptyCleanupReport();
      expect(clearAllMessageOf(clean, true)).assertEqual('已清空本机全部数据');
      // 删不动 + 专属日历也没清成：两句都必须出现，一句都不能替用户"当没事"
      const dirty = emptyCleanupReport();
      dirty.eventsPending = 1;
      dirty.remindersPending = 1;
      const dirtyMsg = clearAllMessageOf(dirty, false);
      expect(dirtyMsg).assertEqual('已清空本机全部数据'
        + '；2 项系统日历/提醒可能仍在，本应用已无法再替你清理，请到系统日历/系统设置检查'
        + '；「同休日」日历没有清空，请到系统日历里检查');
      // 最终验收 R2：清库把句柄一起删了，"可稍后重试"在这条路径上承诺的是做不到的事。
      expect(dirtyMsg.indexOf('稍后重试') < 0).assertTrue();
      // 反过来钉住普通取消/改期：那条路径留着 tombstone，重试是真的可兑现，不许被顺手改掉。
      expect(cleanupMessageOf(dirty).indexOf('稍后重试') >= 0).assertTrue();
      // 只有导出那种删不动的：说清"归系统日历管"，但不说日历没清空（专属那一本确实清了）
      const ext = emptyCleanupReport();
      ext.eventsExternal = 1;
      expect(clearAllMessageOf(ext, true))
        .assertEqual('已清空本机全部数据；1 条导出的日程由系统日历管理，请到系统日历里删除');
    });
  });
}
