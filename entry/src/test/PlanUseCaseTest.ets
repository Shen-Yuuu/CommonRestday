import { describe, it, expect } from '@ohos/hypium';
import { PlanRow, ScheduleRepo } from 'data';
import {
  CONFLICT_REASON_MIXED, CONFLICT_REASON_MY_COURSE, CONFLICT_REASON_PARTNER_CHANGED,
  CONFLICT_SOURCE_BOTH, CONFLICT_SOURCE_MINE, CONFLICT_SOURCE_PARTNER, ConflictHint,
  conflictSignature, decodeConflictHint, encodeConflictHint
} from 'domain';
import {
  CalendarCapability, CalendarOutcome, CalendarState, CalendarWriteResult, CreatePlanOptions,
  CreatePlanResult, LOCAL_ONLY_NOTE, PlanUseCase, RECOMPUTE_COUNT_KEY, ReminderCapability,
  calendarBadgeOf, canRetryCalendarSync, defaultDraft, isOnSystemCalendar, planDraftError
} from 'feature';

/**
 * 窗口 → 本地计划 → 系统日历的编排（阶段 2 Task 2.2），以及冲突四动作（Task 2.3）。
 *
 * 断言只用公开 API：PlanUseCase 的返回值、ScheduleRepo.listActivePlans、以及设备侧同名广播键
 * recomputeCount。日历/提醒通过 PlanUseCase.bindCapabilities 换成确定性实现——
 * "用户点了取消""权限被拒"在真机上不可复现，但它们恰恰决定本地计划该不该留。
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

async function calendarStateOfPlan(dayOffset: number): Promise<string> {
  const row = await planOf(dayOffset);
  return row == null ? MISSING : row.calendarState;
}

async function eventIdOfPlan(dayOffset: number): Promise<string> {
  const row = await planOf(dayOffset);
  return row == null ? MISSING : row.myEventId;
}

async function reminderIdOfPlan(dayOffset: number): Promise<number> {
  const row = await planOf(dayOffset);
  return row == null ? -999 : row.reminderId;
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

/** 改期后计划还剩在原时间吗：读不到行时给出一个不可能出现的时间值。 */
async function startOf(id: string): Promise<number> {
  const row = await rowById(id);
  return row == null ? -1 : row.start;
}

async function endOf(id: string): Promise<number> {
  const row = await rowById(id);
  return row == null ? -1 : row.end;
}

async function eventIdOf(id: string): Promise<string> {
  const row = await rowById(id);
  return row == null ? MISSING : row.myEventId;
}

async function existsInActiveList(id: string): Promise<boolean> {
  return (await rowById(id)) != null;
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

/** 确定性日历能力：按预设结果应答，并记下确认那一刻本地表的形状。 */
class FakeCalendar implements CalendarCapability {
  outcome: CalendarOutcome = CalendarOutcome.WRITTEN;
  /** 每次写成功依次发一个事件 id：改期后应当拿到新 id，旧 id 进 removed。 */
  eventIds: string[] = ['evt-9001'];
  /** true = 模拟日历应用整个抛错（不是"用户取消"，是没答复）。 */
  thrown: boolean = false;
  removeThrows: boolean = false;
  calls: number = 0;
  directFlags: boolean[] = [];
  /** 每次 confirm 收到的起止，用来断言日历按"新时间"被写入。 */
  confirmTimes: string[] = [];
  /** confirm 被调用时，这条计划已经落在库里的 calendar_state。 */
  stateAtConfirm: string = MISSING;
  removed: string[] = [];

  async confirm(title: string, startMin: number, endMin: number, direct: boolean): Promise<CalendarWriteResult> {
    this.calls = this.calls + 1;
    this.directFlags.push(direct);
    this.confirmTimes.push(startMin + '-' + endMin);
    const rows: PlanRow[] = await ScheduleRepo.listActivePlans();
    for (let i = 0; i < rows.length; i++) {
      if (rows[i].start === startMin && rows[i].end === endMin) {
        this.stateAtConfirm = rows[i].calendarState;
      }
    }
    if (this.thrown) {
      throw new Error('calendar app died');
    }
    if (this.outcome !== CalendarOutcome.WRITTEN) {
      return { outcome: this.outcome, eventId: '' };
    }
    const idx = this.calls <= this.eventIds.length ? this.calls - 1 : this.eventIds.length - 1;
    return { outcome: CalendarOutcome.WRITTEN, eventId: this.eventIds[idx] };
  }

  async remove(eventId: string): Promise<boolean> {
    this.removed.push(eventId);
    if (this.removeThrows) {
      throw new Error('calendar event already gone');
    }
    return true;
  }
}

/** 确定性提醒能力：reminderId 设成负数即模拟"通知没开启，发布失败"。 */
class FakeReminder implements ReminderCapability {
  reminderId: number = 77;
  published: number = 0;
  /** 每次发布收到的起始时间：改期后提醒要跟着挪到新起点。 */
  publishedStarts: number[] = [];
  canceled: number[] = [];
  throwOnPublish: boolean = false;
  throwOnCancel: boolean = false;

  async publish(title: string, startMin: number): Promise<number> {
    this.published = this.published + 1;
    this.publishedStarts.push(startMin);
    if (this.throwOnPublish) {
      throw new Error('notifications disabled');
    }
    return this.reminderId;
  }

  async cancel(reminderId: number): Promise<void> {
    this.canceled.push(reminderId);
    if (this.throwOnCancel) {
      throw new Error('reminder already fired');
    }
  }
}

function bind(capability: CalendarOutcome): FakeCalendar {
  const cal = new FakeCalendar();
  cal.outcome = capability;
  PlanUseCase.bindCapabilities(cal, new FakeReminder());
  return cal;
}

/** 改期/取消要同时盯住日历和提醒两条投影，所以两个桩都要拿到手。 */
function bindCalendar(capability: CalendarOutcome, eventIds: string[]): FakeCalendar {
  const cal = new FakeCalendar();
  cal.outcome = capability;
  cal.eventIds = eventIds;
  PlanUseCase.bindCapabilities(cal, null);
  return cal;
}

function bindReminder(): FakeReminder {
  const rem = new FakeReminder();
  PlanUseCase.bindCapabilities(null, rem);
  return rem;
}

export default function planUseCaseTest() {
  describe('planUseCase', () => {

    it('invalid_draft_writes_nothing_and_recomputes_nothing', 0, async () => {
      const cal = bind(CalendarOutcome.WRITTEN);
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
      expect(tiny.error).assertEqual('计划时长至少 15 分钟');
      // 非法草稿连系统都不该惊动
      expect(cal.calls).assertEqual(0);
      expect(recomputes()).assertEqual(before);
      expect(await calendarStateOfPlan(1)).assertEqual(MISSING);
    });

    it('local_plan_is_persisted_before_the_calendar_is_asked', 0, async () => {
      const cal = bind(CalendarOutcome.WRITTEN);
      const ws = winStartOf(2);
      const r = await PlanUseCase.createPlan(ws, ws + 180, '看电影', 'movie', ws + 30, ws + 90);
      expect(r.ok).assertTrue();
      // 请系统确认时，本地已经有了这条 PENDING 计划：日历只是它的一份投影
      expect(cal.stateAtConfirm).assertEqual(CalendarState.PENDING);
      expect(await calendarStateOfPlan(2)).assertEqual(CalendarState.WRITTEN);
      expect(await eventIdOfPlan(2)).assertEqual('evt-9001');
    });

    it('canceled_confirmation_keeps_the_local_plan', 0, async () => {
      const cal = bind(CalendarOutcome.CANCELED);
      const ws = winStartOf(3);
      const before = recomputes();
      const r = await PlanUseCase.createPlan(ws, ws + 180, '短途旅行', 'trip', ws + 30, ws + 90);
      expect(r.ok).assertTrue();
      expect(r.calendarState).assertEqual(CalendarState.LOCAL_ONLY);
      expect(isOnSystemCalendar(r.calendarState)).assertFalse();
      expect(recomputes() - before).assertEqual(1);
      expect(await calendarStateOfPlan(3)).assertEqual(CalendarState.LOCAL_ONLY);
      // 没写成的计划不留假的事件 id，否则取消/改期会去删一条不存在的日程
      expect(await eventIdOfPlan(3)).assertEqual('');
      expect(cal.calls).assertEqual(1);
    });

    it('denied_permission_and_missing_capability_both_stay_local', 0, async () => {
      const ws = winStartOf(4);
      bind(CalendarOutcome.DENIED);
      const a: CreatePlanResult = await PlanUseCase.createPlan(ws, ws + 180, '共同自习', 'study',
        ws + 30, ws + 90);
      expect(a.calendarState).assertEqual(CalendarState.LOCAL_ONLY);
      expect(await calendarStateOfPlan(4)).assertEqual(CalendarState.LOCAL_ONLY);

      bind(CalendarOutcome.UNAVAILABLE);
      const b = await PlanUseCase.createPlan(ws, ws + 180, '办证体检', 'errand', ws + 120, ws + 180);
      expect(b.ok).assertTrue();
      expect(b.calendarState).assertEqual(CalendarState.UNSUPPORTED);
      expect(isOnSystemCalendar(b.calendarState)).assertFalse();
    });

    it('direct_write_is_the_only_path_that_skips_confirmation', 0, async () => {
      const cal = bind(CalendarOutcome.WRITTEN);
      const ws = winStartOf(5);
      const direct: CreatePlanOptions = { directCalendarWrite: true };
      await PlanUseCase.createPlan(ws, ws + 180, '一起吃饭', 'meal', ws + 30, ws + 90);
      await PlanUseCase.createPlan(ws, ws + 180, '回父母家', 'parents', ws + 120, ws + 180, direct);
      expect(cal.calls).assertEqual(2);
      // 默认必须由用户当面点一次保存；只有显式高级选项才跳过
      expect(cal.directFlags[0]).assertFalse();
      expect(cal.directFlags[1]).assertTrue();
    });

    it('double_submit_persists_exactly_one_plan', 0, async () => {
      const cal = bind(CalendarOutcome.WRITTEN);
      const ws = winStartOf(6);
      // 第一次还没走完（正等系统日历），用户又点了一次
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
      const cal = bind(CalendarOutcome.WRITTEN);
      const rem = new FakeReminder();
      rem.reminderId = -1;
      PlanUseCase.bindCapabilities(cal, rem);
      const ws = winStartOf(7);
      const r = await PlanUseCase.createPlan(ws, ws + 180, '自定义', 'custom', ws + 30, ws + 90);
      expect(r.ok).assertTrue();
      expect(rem.published).assertEqual(1);
      expect(await reminderIdOfPlan(7)).assertEqual(-1);
    });

    it('reopen_gets_the_same_draft_and_never_leaves_pending_rows', 0, async () => {
      const ws = winStartOf(8);
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
      expect(planDraftError(short, ws, ws + 10)).assertEqual('计划时长至少 15 分钟');

      bind(CalendarOutcome.CANCELED);
      const created = await PlanUseCase.createPlan(ws, we, '一起吃饭', 'meal', draft.start, draft.end);
      expect(created.ok).assertTrue();
      // 返回时状态已是终值：恢复页面不会再看到"等待确认"的孤儿计划
      const rows: PlanRow[] = await ScheduleRepo.listActivePlans();
      let pending = 0;
      for (let i = 0; i < rows.length; i++) {
        if (rows[i].calendarState === CalendarState.PENDING) {
          pending = pending + 1;
        }
      }
      expect(pending).assertEqual(0);
    });

    it('reschedule_moves_the_plan_and_migrates_the_calendar_event', 0, async () => {
      const base = dayBase(12);
      const cal = bindCalendar(CalendarOutcome.WRITTEN, ['evt-new']);
      const rem = bindReminder();
      const before = recomputes();
      await mkConflictPlan('p-12', base + 600, base + 750, CalendarState.WRITTEN, 'evt-old', 77,
        hintOf(CONFLICT_REASON_MY_COURSE, CONFLICT_SOURCE_MINE, base + 690, base + 750,
          base + 1200, base + 1380, false));

      const r = await PlanUseCase.acceptAlternative('p-12');
      expect(r.ok).assertTrue();
      expect(r.calendarState).assertEqual(CalendarState.WRITTEN);
      // 时长不变、起点对齐替代窗口：改期不是"另起一段"
      expect(await startOf('p-12')).assertEqual(base + 1200);
      expect(await endOf('p-12')).assertEqual(base + 1350);
      // 旧日程删掉、新日程按新时间写入，日历徽标随之消失
      expect(cal.removed.join('|')).assertEqual('evt-old');
      expect(cal.confirmTimes.join('|')).assertEqual((base + 1200) + '-' + (base + 1350));
      expect(await eventIdOf('p-12')).assertEqual('evt-new');
      expect(calendarBadgeOf(CalendarState.WRITTEN)).assertEqual('');
      // 提醒也挪到新起点，全程只重算一次
      expect(rem.canceled.join('|')).assertEqual('77');
      expect(rem.publishedStarts.join('|')).assertEqual('' + (base + 1200));
      expect(recomputes() - before).assertEqual(1);

      // 替代窗口比计划短（检测结果已被下一次重算收窄）：新时间收缩进窗口，
      // 而不是照原时长造出一段"窗口外的共同时间"
      await mkConflictPlan('p-12b', base + 60, base + 210, CalendarState.WRITTEN, 'evt-b1', 78,
        hintOf(CONFLICT_REASON_MY_COURSE, CONFLICT_SOURCE_MINE, base + 150, base + 210,
          base + 900, base + 990, false));
      const clipped = await PlanUseCase.acceptAlternative('p-12b');
      expect(clipped.ok).assertTrue();
      expect(await startOf('p-12b')).assertEqual(base + 900);
      expect(await endOf('p-12b')).assertEqual(base + 990);
    });

    it('failed_calendar_migration_keeps_the_rescheduled_plan_retryable', 0, async () => {
      const base = dayBase(13);
      const cal = bindCalendar(CalendarOutcome.FAILED, ['evt-old', 'evt-new']);
      const before = recomputes();
      await mkConflictPlan('p-13', base + 600, base + 750, CalendarState.WRITTEN, 'evt-old', 79,
        hintOf(CONFLICT_REASON_PARTNER_CHANGED, CONFLICT_SOURCE_PARTNER, base + 690, base + 750,
          base + 1200, base + 1380, false));

      const r = await PlanUseCase.acceptAlternative('p-13');
      // 本地计划这件事实改成了；日历只是投影，投影没跟上不能谎报"改期失败"
      expect(r.ok).assertTrue();
      expect(r.error).assertEqual('');
      expect(r.calendarState).assertEqual(CalendarState.FAILED);
      expect(isOnSystemCalendar(r.calendarState)).assertFalse();
      expect(canRetryCalendarSync(r.calendarState)).assertTrue();
      // 计划留在新时间：改期不回滚，用户不需要知道日历应用的故障
      expect(await startOf('p-13')).assertEqual(base + 1200);
      expect(await endOf('p-13')).assertEqual(base + 1350);
      // 没写成的投影不留假事件 id，否则重试会去删一条不存在的日程
      expect(await eventIdOf('p-13')).assertEqual('');
      expect(calendarBadgeOf(CalendarState.FAILED)).assertEqual(LOCAL_ONLY_NOTE);
      expect(recomputes() - before).assertEqual(1);

      // 用户稍后点"写入日历"：补写走的是新时间，投影与本地计划重新对齐
      const retry = bindCalendar(CalendarOutcome.WRITTEN, ['evt-retry']);
      const s = await PlanUseCase.syncToCalendar('p-13');
      expect(s.ok).assertTrue();
      expect(s.calendarState).assertEqual(CalendarState.WRITTEN);
      expect(retry.confirmTimes.join('|')).assertEqual((base + 1200) + '-' + (base + 1350));
      expect(await eventIdOf('p-13')).assertEqual('evt-retry');
      // 补写没有改动任何时间事实，所以不该再触发一次重算
      expect(recomputes() - before).assertEqual(1);
      // 设备压根没有日历能力时不给重试入口（点了也不会成，只是打扰）
      expect(canRetryCalendarSync(CalendarState.UNSUPPORTED)).assertFalse();
    });

    it('stale_alternative_leaves_the_plan_untouched', 0, async () => {
      const base = dayBase(14);
      const cal = bindCalendar(CalendarOutcome.WRITTEN, ['evt-x']);
      const before = recomputes();
      // 下一次重算把替代窗口吃掉了（对方又加了课）：hint 里只剩零长度替代
      await mkConflictPlan('p-14a', base + 600, base + 750, CalendarState.WRITTEN, 'evt-old', 80,
        hintOf(CONFLICT_REASON_MY_COURSE, CONFLICT_SOURCE_MINE, base + 690, base + 750, 0, 0, false));
      // 替代窗口比最短时长还短：照搬会造出一个没人能约的计划的碎片
      await mkConflictPlan('p-14b', base + 300, base + 450, CalendarState.WRITTEN, 'evt-old2', 81,
        hintOf(CONFLICT_REASON_MY_COURSE, CONFLICT_SOURCE_MINE, base + 390, base + 450,
          base + 900, base + 910, false));
      // 冲突已经消失（课被删了）：不能拿旧 hint 改期
      await mkConflictPlan('p-14c', base + 60, base + 210, CalendarState.WRITTEN, 'evt-old3', 82,
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
      expect(recomputes()).assertEqual(before);
    });

    it('keep_original_plan_marks_the_conflict_and_nothing_else', 0, async () => {
      const base = dayBase(15);
      const cal = bindCalendar(CalendarOutcome.WRITTEN, ['evt-y']);
      const before = recomputes();
      const stored = hintOf(CONFLICT_REASON_MIXED, CONFLICT_SOURCE_BOTH, base + 690, base + 750,
        base + 1200, base + 1380, false);
      await mkConflictPlan('p-15', base + 600, base + 750, CalendarState.WRITTEN, 'evt-y', 83, stored);

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
      await mkConflictPlan('p-15x', base + 30, base + 180, CalendarState.NOT_REQUESTED, '', 84, '');
      expect(await PlanUseCase.keepOriginalPlan('p-15x')).assertFalse();
      expect(await PlanUseCase.keepOriginalPlan('p-15-nonexistent')).assertFalse();
    });

    it('cancel_frees_the_slot_even_when_projection_cleanup_fails', 0, async () => {
      const base = dayBase(16);
      const cal = bindCalendar(CalendarOutcome.WRITTEN, ['evt-c1', 'evt-c2']);
      const rem = bindReminder();
      const ws = base + 600;
      const first = await PlanUseCase.createPlan(ws, ws + 300, '一起看展', 'movie', ws + 60, ws + 210);
      expect(first.ok).assertTrue();
      const second = await PlanUseCase.createPlan(ws, ws + 300, '一起买菜', 'meal', ws + 240, ws + 285);
      expect(second.ok).assertTrue();
      expect(cal.removed.length).assertEqual(0);

      const before = recomputes();
      const r = await PlanUseCase.cancelPlan(first.planId);
      expect(r.ok).assertTrue();
      expect(r.error).assertEqual('');
      // 取消后不再是活动计划：这个时段重新变成共同空闲（列表读模型据此过滤）
      expect(await existsInActiveList(first.planId)).assertFalse();
      expect(await existsInActiveList(second.planId)).assertTrue();
      expect(cal.removed.join('|')).assertEqual('evt-c1');
      expect(rem.canceled.join('|')).assertEqual('77');
      expect(recomputes() - before).assertEqual(1);

      // 日历与提醒清理全抛错，也不该把用户卡在"取消失败"里：
      // 留下一条孤儿日程可以手动删，谎报失败只会换来一次重复提交
      cal.removeThrows = true;
      rem.throwOnCancel = true;
      const r2 = await PlanUseCase.cancelPlan(second.planId);
      expect(r2.ok).assertTrue();
      expect(await existsInActiveList(second.planId)).assertFalse();
    });

    it('calendar_gateway_exception_becomes_a_retryable_state', 0, async () => {
      const cal = bindCalendar(CalendarOutcome.WRITTEN, ['evt-t']);
      cal.thrown = true;
      const rem = bindReminder();
      rem.throwOnPublish = true;
      const ws = winStartOf(17);
      const r = await PlanUseCase.createPlan(ws, ws + 180, '一起吃饭', 'meal', ws + 30, ws + 90);
      // 日历应用抛错不是用户的错，更不该让刚保存的计划消失
      expect(r.ok).assertTrue();
      expect(r.calendarState).assertEqual(CalendarState.FAILED);
      expect(isOnSystemCalendar(r.calendarState)).assertFalse();
      expect(canRetryCalendarSync(r.calendarState)).assertTrue();
      expect(await calendarStateOfPlan(17)).assertEqual(CalendarState.FAILED);
      expect(await eventIdOfPlan(17)).assertEqual('');
      // 提醒发布抛错同样静默：没有留下任何"等确认"的孤儿状态
      expect(rem.published).assertEqual(1);
      expect(await reminderIdOfPlan(17)).assertEqual(-1);
      expect(cal.calls).assertEqual(1);
    });
  });
}
