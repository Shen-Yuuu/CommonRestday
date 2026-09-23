import { hilog } from '@kit.PerformanceAnalysisKit';
import { abilityDelegatorRegistry, Driver } from '@kit.TestKit';
import { Want } from '@kit.AbilityKit';
import { afterAll, beforeAll, describe, expect, it } from '@ohos/hypium';
import {
  CONFLICT_REASON_MY_SHIFT, CONFLICT_SOURCE_MINE, MIN_PER_DAY, OWNER_ME, todayEpochDay
} from 'domain';
import { Db, PlanRow, ScheduleRepo, SettingsStore } from 'data';
import {
  CalendarCapability, CalendarOutcome, CalendarState, CalendarWriteResult, CommonTimeQueryService,
  MIN_PLAN_MIN, PlanCapabilities, PlanConflictView, PlanSummary, ReminderCapability, RemoveOutcome,
  ScheduleCommandService, ScheduleUseCase, WindowChannel, WindowFilter, WindowFilterKey,
  WindowSummary, PlanUseCase, isAppManagedEvent, isOnSystemCalendar
} from 'feature';

/**
 * 阶段 2 端到端验收（真机 Instrument Test）：把"首页答案 → 共同窗口 → 创建计划 →
 * 系统日历确认 → 共同计划出现 → 日程变更制造冲突 → 采用替代时间 → 取消并恢复窗口"
 * 整条链路跑在真实的 RDB / Preferences / 引擎与读模型上。
 *
 * 与离线单测的分工：离线用例（entry/src/test）证明编排与口径，这里证明
 * "落到设备上的数据，真的能被下一次查询按同一口径读回来"。两边都只驱动公开 API。
 *
 * 两处刻意不依赖真机系统能力：
 * - 系统日历写入要弹确认页，自动化里换成按次发号的确定性端口（PlanCapabilities.bind）；
 *   真机确认页本身列在 docs/testing-checklist.md 的手工项里。
 * - 提醒端口恒返回 -1：验收不该往通知栏塞东西。
 *
 * 造冲突用"临时班次类型 + 单日覆盖"而不是改课程：课程展开依赖学期锚点与节次表，
 * 那两处都是本机真实数据，测试不该动；整天班次只影响这一天，跑完清掉即可。
 * 计划只取最短的 15 分钟，是为了让"视界里存在更晚的替代窗口"这个前提对任何真实班表都成立。
 */

const DOMAIN = 0x0000;
const TAG = 'stage2e2e';
/** 计划标题：跑完会以 CANCELLED 留在库里，一眼能认出是验收数据。 */
const PLAN_TITLE = 'E2E 阶段2验收计划';
/** 临时班次类型 id：整天占用，afterAll 删除。 */
const FIXTURE_SHIFT = 'test-e2e-fullday';

/** 确定性日历端口：每次受管写入发一个新事件 id，改期时旧 id 进 removed。 */
class E2eCalendar implements CalendarCapability {
  calls: number = 0;
  removed: string[] = [];
  exports: number = 0;
  purges: number = 0;

  async write(title: string, startMin: number, endMin: number): Promise<CalendarWriteResult> {
    this.calls = this.calls + 1;
    return { outcome: CalendarOutcome.WRITTEN, eventId: 'e2e-evt-' + this.calls };
  }

  async exportToSystem(title: string, startMin: number, endMin: number): Promise<CalendarWriteResult> {
    this.exports = this.exports + 1;
    return { outcome: CalendarOutcome.EXPORTED, eventId: 'e2e-ext-' + this.exports };
  }

  async remove(eventId: string): Promise<RemoveOutcome> {
    this.removed.push(eventId);
    return RemoveOutcome.REMOVED;
  }

  async purgeManagedCalendar(): Promise<boolean> {
    this.purges = this.purges + 1;
    return true;
  }
}

/** 提醒端口：恒 -1 = 不注册系统提醒（也就没有句柄要取消）。 */
class E2eReminder implements ReminderCapability {
  async publish(title: string, startMin: number): Promise<number> {
    return -1;
  }

  async cancel(reminderId: number): Promise<boolean> {
    return true;
  }
}

const CAL = new E2eCalendar();

function nowEpochMin(): number {
  const d = new Date();
  return todayEpochDay() * MIN_PER_DAY + d.getHours() * 60 + d.getMinutes();
}

/** 共同时间页的全量窗口（未归并）：与首页答案同源，只是没按通道筛。 */
async function pageWindows(from: number): Promise<WindowSummary[]> {
  const f: WindowFilter = { key: WindowFilterKey.ALL, fromEpochMin: from };
  const page = await CommonTimeQueryService.getCommonTimePage(f, from);
  return page.windows;
}

/**
 * 某个时刻还被窗口覆盖吗。按通道各查一次：同一时段常规与旅行通道各产出一个窗口，
 * 计划占用会把两边一起切开，但只有同通道的覆盖才说明"这段共同时间确实没了"。
 */
function covered(windows: WindowSummary[], at: number, channel: WindowChannel): boolean {
  for (let i = 0; i < windows.length; i++) {
    const w = windows[i];
    if (w.channel === channel && w.start <= at && at < w.end) {
      return true;
    }
  }
  return false;
}

/** 视界里最早的一段常规空闲（与首页"下一段共同时间"同一口径：end > now 且 channel=REGULAR）。 */
function firstRegularAfter(windows: WindowSummary[], now: number): WindowSummary | null {
  let best: WindowSummary | null = null;
  for (let i = 0; i < windows.length; i++) {
    const w = windows[i];
    if (w.channel !== WindowChannel.REGULAR || w.end <= now) {
      continue;
    }
    if (best == null || w.start < best.start) {
      best = w;
    }
  }
  return best;
}

async function planRowOf(id: string): Promise<PlanRow | null> {
  const rows: PlanRow[] = await ScheduleRepo.listActivePlans();
  for (let i = 0; i < rows.length; i++) {
    if (rows[i].id === id) {
      return rows[i];
    }
  }
  return null;
}

/** 读不到卡片时给一张可辨识的假卡片：断言会响，而不是悄悄跳过。 */
function cardOf(cards: PlanSummary[], id: string): PlanSummary {
  for (let i = 0; i < cards.length; i++) {
    if (cards[i].id === id) {
      return cards[i];
    }
  }
  const missing: PlanSummary = {
    id: id, title: 'MISSING', kind: '', start: -1, end: -1, status: 'MISSING',
    conflictText: '', conflict: null, calendarState: ''
  };
  return missing;
}

async function delay(ms: number): Promise<void> {
  await Driver.create().delayMs(ms);
}

export default function abilityTest() {
  describe('ActsAbilityTest', () => {
    /** 生命周期共享：afterAll 要按这些值把临时数据从库里清掉。 */
    let planId = '';
    let hostDay = 0;
    let hostChannel = WindowChannel.REGULAR;
    let altStart = 0;

    beforeAll(async () => {
      const ctx = abilityDelegatorRegistry.getAbilityDelegator().getAppContext();
      await Db.init(ctx);
      await SettingsStore.init(ctx);
      PlanCapabilities.bind(CAL, new E2eReminder());
      hilog.info(DOMAIN, TAG, '%{public}s', 'fixture ready');
    })

    afterAll(async () => {
      // 无论链路断在哪一步，都不把临时班次和覆盖留在用户的库里
      const cleared = await ScheduleCommandService.clearDayShift(hostDay, OWNER_ME);
      expect(cleared.ok).assertTrue();
      const removed = await ScheduleCommandService.removeShiftType(FIXTURE_SHIFT, OWNER_ME);
      expect(removed.ok).assertTrue();
      if (planId !== '') {
        await PlanUseCase.cancelPlan(planId);
      }
      await ScheduleUseCase.onScheduleChanged();
    })

    /**
     * UIAbility 集成：启动真实 EntryAbility 之后，本地存储与内置班次就绪，
     * 冷启动重算把窗口缓存写成有效值（US6 / FR-011）。
     */
    it('uiability_launch_leaves_a_valid_window_cache', 0, async () => {
      const delegator = abilityDelegatorRegistry.getAbilityDelegator();
      const want: Want = {
        bundleName: delegator.getAppContext().applicationInfo.name,
        abilityName: 'EntryAbility'
      };
      await delegator.startAbility(want);
      let computedAt = await ScheduleRepo.windowCacheComputedAt();
      for (let i = 0; i < 20 && computedAt <= 0; i++) {
        await delay(250);
        computedAt = await ScheduleRepo.windowCacheComputedAt();
      }
      expect(computedAt > 0).assertTrue();
      const types = await ScheduleRepo.listShiftTypes(OWNER_ME);
      expect(types.length > 0).assertTrue();
    })

    /**
     * 首页答案与共同时间页同源：入口只有"答案 → 窗口"这一条路，
     * 首页说的那段空闲必须能在窗口页里找到，否则点进去就是空的。
     */
    it('home_answer_points_at_a_window_the_page_offers', 0, async () => {
      const now = nowEpochMin();
      const home = await CommonTimeQueryService.getHomeSummary(now);
      const later = firstRegularAfter(await pageWindows(now), now);
      const answer = home.nextWindow;
      if (answer == null) {
        // 答案说"没有"：窗口页里也不能还有更晚的常规空闲
        expect(later == null).assertTrue();
        return;
      }
      expect(answer.start > now).assertTrue();
      expect(later != null).assertTrue();
      expect((later as WindowSummary).start).assertEqual(answer.start);
      expect((later as WindowSummary).durationMin).assertEqual(answer.durationMin);
    })

    /**
     * 计划生命周期：占用 → 出现在列表 → 被日程变更解释成冲突 → 采用替代时间 → 取消恢复。
     * 每一步的断言都来自下一次查询，而不是当次调用的返回值。
     */
    it('plan_occupies_explains_reschedules_and_frees_the_slot', 0, async () => {
      const now = nowEpochMin();
      const before = await pageWindows(now);
      // 前提：找一段"起点晚于此刻、放得下一个最短计划、且视界里还有更晚窗口当替代"的空闲
      let host: WindowSummary | null = null;
      for (let i = 0; i < before.length; i++) {
        if (before[i].start > now && before[i].durationMin >= MIN_PLAN_MIN) {
          host = before[i];
          break;
        }
      }
      expect(host != null).assertTrue();
      const h = host as WindowSummary;
      hostChannel = h.channel;
      hostDay = Math.floor(h.start / MIN_PER_DAY);
      const planEnd = h.start + MIN_PLAN_MIN;

      const created = await PlanUseCase.createPlan(h.start, h.end, PLAN_TITLE, 'MEAL', h.start, planEnd);
      expect(created.ok).assertTrue();
      planId = created.planId;
      // 默认路径是"写进本应用专属日历"的受管投影：改期/取消能自动跟上，事件 id 回写在计划行上
      expect(created.calendarState).assertEqual(CalendarState.MANAGED_WRITTEN);
      expect(isOnSystemCalendar(created.calendarState)).assertTrue();
      expect(isAppManagedEvent(created.calendarState)).assertTrue();
      const row1 = await planRowOf(planId);
      expect(row1 != null).assertTrue();
      expect((row1 as PlanRow).myEventId).assertEqual('e2e-evt-1');
      expect((row1 as PlanRow).start).assertEqual(h.start);

      // 共同计划出现在计划列表，此刻没有冲突
      const card1 = cardOf(await CommonTimeQueryService.getPlanCards(), planId);
      expect(card1.title).assertEqual(PLAN_TITLE);
      expect(card1.status).assertEqual('OK');
      expect(card1.conflict == null).assertTrue();
      expect(card1.calendarState).assertEqual(CalendarState.MANAGED_WRITTEN);
      // 这段时间不再空闲：窗口页里已经盖不住计划的起点了
      expect(covered(await pageWindows(now), h.start, hostChannel)).assertFalse();

      // 日程变更（整天班次）压上来：冲突要带得出"是谁的时间变了"
      const busyShift = ScheduleUseCase.mkType(FIXTURE_SHIFT, 'E2E 全天班', '#000000',
        0, MIN_PER_DAY - 1, false, 0, 0, 0);
      expect((await ScheduleCommandService.saveShiftType(busyShift, OWNER_ME)).ok).assertTrue();
      expect((await ScheduleCommandService.setDayShift(hostDay, FIXTURE_SHIFT, OWNER_ME)).ok).assertTrue();

      const card2 = cardOf(await CommonTimeQueryService.getPlanCards(), planId);
      expect(card2.status).assertEqual('CONFLICT');
      expect(card2.conflictText.length > 0).assertTrue();
      const view: PlanConflictView = card2.conflict as PlanConflictView;
      expect(card2.conflict != null).assertTrue();
      expect(view.reasonCode).assertEqual(CONFLICT_REASON_MY_SHIFT);
      expect(view.sourceLevel).assertEqual(CONFLICT_SOURCE_MINE);
      expect(view.reasonText).assertEqual('与你的班次冲突');
      expect(view.affectedText.length > 0).assertTrue();
      expect(view.kept).assertFalse();
      // 首页红点说同一句话：冲突数与归因来自同一份计划行
      const home2 = await CommonTimeQueryService.getHomeSummary(now);
      expect(home2.conflictCount >= 1).assertTrue();
      expect(home2.conflictReason).assertEqual('你的日程有变');
      // 替代窗口由引擎在重算后的窗口里挑出来，读模型只负责转述
      expect(view.altStart > h.start).assertTrue();
      expect(view.altEnd > view.altStart).assertTrue();
      expect(view.altText.length > 0).assertTrue();
      altStart = view.altStart;

      // 采用替代时间：计划搬到替代窗口，日历事件随之迁移
      const accepted = await PlanUseCase.acceptAlternative(planId);
      expect(accepted.ok).assertTrue();
      expect(accepted.calendarState).assertEqual(CalendarState.MANAGED_WRITTEN);
      const row2 = await planRowOf(planId);
      expect(row2 != null).assertTrue();
      expect((row2 as PlanRow).start).assertEqual(view.altStart);
      expect((row2 as PlanRow).end).assertEqual(Math.min(view.altStart + MIN_PLAN_MIN, view.altEnd));
      expect((row2 as PlanRow).myEventId).assertEqual('e2e-evt-2');
      expect(CAL.removed.join('|')).assertEqual('e2e-evt-1');
      expect(covered(await pageWindows(now), altStart, WindowChannel.REGULAR)).assertFalse();

      // 班表恢复：冲突是"这一天的班"造成的，班没了就该自动回到 OK，不用用户再点一次
      expect((await ScheduleCommandService.clearDayShift(hostDay, OWNER_ME)).ok).assertTrue();
      const card3 = cardOf(await CommonTimeQueryService.getPlanCards(), planId);
      expect(card3.status).assertEqual('OK');
      expect(card3.conflictText).assertEqual('');
      expect((await CommonTimeQueryService.getHomeSummary(now)).conflictReason).assertEqual('');

      // 取消计划：投影跟着清掉，这段时间重新变成共同空闲
      const canceled = await PlanUseCase.cancelPlan(planId);
      expect(canceled.ok).assertTrue();
      expect(await planRowOf(planId) == null).assertTrue();
      expect(CAL.removed.join('|')).assertEqual('e2e-evt-1|e2e-evt-2');
      expect(covered(await pageWindows(now), altStart, WindowChannel.REGULAR)).assertTrue();
      planId = '';
    })
  })
}
