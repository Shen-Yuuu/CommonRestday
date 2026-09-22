import { describe, it, expect } from '@ohos/hypium';
import { PlanRow, ScheduleRepo } from 'data';
import {
  CalendarCapability, CalendarOutcome, CalendarState, CalendarWriteResult, CreatePlanOptions,
  CreatePlanResult, PlanUseCase, RECOMPUTE_COUNT_KEY, ReminderCapability,
  defaultDraft, isOnSystemCalendar, planDraftError
} from 'feature';

/**
 * 窗口 → 本地计划 → 系统日历的编排（阶段 2 Task 2.2）。
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

function winStartOf(dayOffset: number): number {
  return (BASE_DAY + dayOffset) * DAY + 600;
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

function recomputes(): number {
  return AppStorage.get<number>(RECOMPUTE_COUNT_KEY) ?? 0;
}

/** 确定性日历能力：按预设结果应答，并记下确认那一刻本地表的形状。 */
class FakeCalendar implements CalendarCapability {
  outcome: CalendarOutcome = CalendarOutcome.WRITTEN;
  eventId: string = 'evt-9001';
  calls: number = 0;
  directFlags: boolean[] = [];
  /** confirm 被调用时，这条计划已经落在库里的 calendar_state。 */
  stateAtConfirm: string = MISSING;
  removed: string[] = [];

  async confirm(title: string, startMin: number, endMin: number, direct: boolean): Promise<CalendarWriteResult> {
    this.calls = this.calls + 1;
    this.directFlags.push(direct);
    const rows: PlanRow[] = await ScheduleRepo.listActivePlans();
    for (let i = 0; i < rows.length; i++) {
      if (rows[i].start === startMin && rows[i].end === endMin) {
        this.stateAtConfirm = rows[i].calendarState;
      }
    }
    if (this.outcome !== CalendarOutcome.WRITTEN) {
      return { outcome: this.outcome, eventId: '' };
    }
    return { outcome: CalendarOutcome.WRITTEN, eventId: this.eventId };
  }

  async remove(eventId: string): Promise<boolean> {
    this.removed.push(eventId);
    return true;
  }
}

/** 确定性提醒能力：reminderId 设成负数即模拟"通知没开启，发布失败"。 */
class FakeReminder implements ReminderCapability {
  reminderId: number = 77;
  published: number = 0;
  canceled: number[] = [];

  async publish(title: string, startMin: number): Promise<number> {
    this.published = this.published + 1;
    return this.reminderId;
  }

  async cancel(reminderId: number): Promise<void> {
    this.canceled.push(reminderId);
  }
}

function bind(capability: CalendarOutcome): FakeCalendar {
  const cal = new FakeCalendar();
  cal.outcome = capability;
  PlanUseCase.bindCapabilities(cal, new FakeReminder());
  return cal;
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
  });
}
