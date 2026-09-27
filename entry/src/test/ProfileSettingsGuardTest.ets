import { describe, it, expect } from '@ohos/hypium';
import { PAIRED, PAIR_NONE, PAIR_WAITING, PlanRow, ScheduleRepo, SettingsStore } from 'data';
import { AgcPairingClient, PairKeyStore } from 'cloud';
import {
  CalendarCapability, CalendarOutcome, CalendarWriteResult, FeatureFlags, PlanCapabilities,
  ProfileSettingsService, ReminderCapability, RemoveOutcome
} from 'feature';

/**
 * 阶段 6R.2（独立验收 B1）：`cloudPairing=false` 必须是一条**真边界**，而不是"AGC 恰好没配、
 * 云调用必然抛错"这种靠环境成立的安静。所以这几条用例打的正是最坏那一格：
 *
 * 1. 离线的云客户端**必定成功**（真机上 AGC 未配置时才必定失败）——少了开关守卫，
 *    pairId/pairState 就会在这一格里被写进本机，用例立刻响；
 * 2. 关闭态要求"一条云请求都不发"，所以断言的是同名计数器 `AgcPairingClient.calls` 为 0；
 * 3. 关闭态不许把本机数据一起关掉：等级、代录、解除配对、清空数据照常（改造文档 §0.1「开关只关能力，不关数据」）；
 * 4. 长期密钥既不进 Preferences 也不进应用层：读/写密钥的 API 都不存在了，密钥只在 HUKS 别名里。
 *    所以这一格断言的是**关闭态一次 HUKS 别名操作都不发生**（`PairKeyStore.calls`），
 *    比旧版那句"读回来是空串"更硬——旧断言能证明没写过，证明不了后来谁建了钥匙。
 *
 * 解除配对与取消等待是例外：它们允许调 `dropPairKey`，因为那是撤销而不是建立能力。
 *
 * 每条用例自己先把设置摆成已知的形状（上一版原型配对过的残留态），因此与文件顺序无关。
 */
const CLOSED = FeatureFlags.cloudClosedMessage;

/** 只读内存表里的计划行，用来判断"清空"到底清没清。 */
async function activePlanCount(): Promise<number> {
  return (await ScheduleRepo.listActivePlans()).length;
}

async function carryCount(): Promise<number> {
  return (await ScheduleRepo.listPlansCarryingHandles()).length;
}

/**
 * 清出一张白卷：ScheduleRepo 的离线桩是一整份共享的内存表（PlanUseCaseTest 也往里写行），
 * 清空动作要按条数向用户报账，所以这里的计数必须先归零，否则断言打到的是别人留的行。
 */
async function emptyPlanTable(): Promise<void> {
  await ScheduleRepo.clearAllData();
}

/** 造一条"已写入系统日历 + 已发布计划级提醒"的计划：清空时必须逐条带走投影。 */
async function mkPlanWithHandles(id: string, eventId: string, reminderId: number): Promise<void> {
  const row: PlanRow = {
    id: id, title: '一起吃饭', kind: 'meal', start: 600, end: 660,
    status: 'ACTIVE', createdBy: 'ME', windowRef: '', conflictHint: '',
    myEventId: eventId, reminderId: reminderId, updatedAt: 0,
    calendarState: 'MANAGED_WRITTEN', syncState: 'LOCAL_ONLY'
  };
  await ScheduleRepo.upsertPlan(row);
}

/** 删除动作为真失败：日程与提醒都删不动，清空必须把数量报出来（不能回一句"已清空"）。 */
class RefusingCalendar implements CalendarCapability {
  async write(title: string, startMin: number, endMin: number): Promise<CalendarWriteResult> {
    const r: CalendarWriteResult = { outcome: CalendarOutcome.FAILED, eventId: '' };
    return r;
  }

  async exportToSystem(title: string, startMin: number, endMin: number): Promise<CalendarWriteResult> {
    const r: CalendarWriteResult = { outcome: CalendarOutcome.FAILED, eventId: '' };
    return r;
  }

  async remove(eventId: string): Promise<RemoveOutcome> {
    return RemoveOutcome.FAILED;
  }

  async purgeManagedCalendar(): Promise<boolean> {
    return false;
  }
}

class RefusingReminder implements ReminderCapability {
  async publish(title: string, startMin: number): Promise<number> {
    return -1;
  }

  async cancel(reminderId: number): Promise<boolean> {
    return false;
  }
}

/** 写得动的日历：清空后专属日历整本也没清掉时，仍要把"日历没清空"这半句说出来。 */
class CleanCalendar implements CalendarCapability {
  async write(title: string, startMin: number, endMin: number): Promise<CalendarWriteResult> {
    const r: CalendarWriteResult = { outcome: CalendarOutcome.WRITTEN, eventId: 'evt-x' };
    return r;
  }

  async exportToSystem(title: string, startMin: number, endMin: number): Promise<CalendarWriteResult> {
    const r: CalendarWriteResult = { outcome: CalendarOutcome.EXPORTED, eventId: 'evt-x' };
    return r;
  }

  async remove(eventId: string): Promise<RemoveOutcome> {
    return RemoveOutcome.REMOVED;
  }

  async purgeManagedCalendar(): Promise<boolean> {
    return true;
  }
}

class OkReminder implements ReminderCapability {
  async publish(title: string, startMin: number): Promise<number> {
    return 1;
  }

  async cancel(reminderId: number): Promise<boolean> {
    return true;
  }
}

export default function profileSettingsGuardTest() {
  describe('profileSettingsGuardTest', () => {

    it('create_invite_returns_before_uid_cloud_and_writes', 0, async () => {
      await SettingsStore.savePairId('stale-session');
      await SettingsStore.setPairState(PAIR_WAITING, 'stale-partner');
      AgcPairingClient.calls = 0;
      PairKeyStore.calls = 0;

      const res = await ProfileSettingsService.createInvite();

      expect(res.ok).assertFalse();
      expect(res.code).assertEqual('');
      expect(res.message).assertEqual(CLOSED);
      expect(AgcPairingClient.calls).assertEqual(0);
      // 关闭态连 HUKS 身份别名都不建：没有钥匙的配对态才是真的配对不了
      expect(PairKeyStore.calls).assertEqual(0);
      expect(SettingsStore.getPairId()).assertEqual('stale-session');
      expect(SettingsStore.getPairState()).assertEqual(PAIR_WAITING);
      expect(SettingsStore.getPartnerUid()).assertEqual('stale-partner');
    });

    it('join_by_code_never_reaches_paired_when_cloud_is_closed', 0, async () => {
      await SettingsStore.savePairId('');
      await SettingsStore.setPairState(PAIR_NONE, '');
      AgcPairingClient.calls = 0;
      PairKeyStore.calls = 0;

      const res = await ProfileSettingsService.joinByCode('246810');
      const junk = await ProfileSettingsService.joinByCode('abc');

      expect(res.ok).assertFalse();
      expect(res.message).assertEqual(CLOSED);
      // 非法码也不许先发请求：守卫在校验之前，两句都停在同一格
      expect(junk.ok).assertFalse();
      expect(junk.message).assertEqual(CLOSED);
      expect(AgcPairingClient.calls).assertEqual(0);
      expect(PairKeyStore.calls).assertEqual(0);
      expect(SettingsStore.getPairState()).assertEqual(PAIR_NONE);
      expect(SettingsStore.getPairId()).assertEqual('');
    });

    it('reconcile_pair_cannot_fabricate_a_paired_state', 0, async () => {
      await SettingsStore.savePairId('stale-session');
      await SettingsStore.setPairState(PAIR_WAITING, '');
      AgcPairingClient.calls = 0;
      PairKeyStore.calls = 0;

      const res = await ProfileSettingsService.reconcilePair();

      // 「检查配对状态」的语义是"去云端对一次账"，关闭态既不许发请求也不许改本机进度。
      expect(res.ok).assertFalse();
      expect(res.message).assertEqual(CLOSED);
      expect(AgcPairingClient.calls).assertEqual(0);
      expect(PairKeyStore.calls).assertEqual(0);
      expect(SettingsStore.getPairState()).assertEqual(PAIR_WAITING);
    });

    /**
     * 确认链接这条入口最坏的一格：本机什么都没做过，只凭别人发来的一串凭据就能转 PAIRED。
     * 关闭态必须一句拒绝，且不留 pairId、不建别名、不发云对象（协议 §4.3 的能力，开关关着就不该有）。
     */
    it('confirm_with_token_is_refused_before_any_write', 0, async () => {
      // 上一条用例留下了 pairId 与 WAITING，这里自己摆回"本机从没配过对"的形状
      await SettingsStore.savePairId('');
      await SettingsStore.setPairState(PAIR_NONE, '');
      AgcPairingClient.calls = 0;
      PairKeyStore.calls = 0;

      const res = await ProfileSettingsService.confirmWithToken('token-from-a-shared-link');

      expect(res.ok).assertFalse();
      expect(res.message).assertEqual(CLOSED);
      expect(AgcPairingClient.calls).assertEqual(0);
      expect(PairKeyStore.calls).assertEqual(0);
      expect(SettingsStore.getPairState()).assertEqual(PAIR_NONE);
      expect(SettingsStore.getPairId()).assertEqual('');
      expect(ProfileSettingsService.getOutboundToken()).assertEqual('');
    });

    it('unpair_still_clears_local_marks_without_a_cloud_call', 0, async () => {
      await SettingsStore.savePairId('session-left-by-the-prototype');
      await SettingsStore.setPairState(PAIRED, 'old-partner-uid');
      await SettingsStore.setPartnerSnapVer(7);
      AgcPairingClient.calls = 0;

      const res = await ProfileSettingsService.unpair();

      // 入口藏着但退出必须留着：残留的 PAIRED 说不清来源，用户要能亲手撤掉。
      expect(res.ok).assertTrue();
      expect(AgcPairingClient.calls).assertEqual(0);
      expect(SettingsStore.getPairState()).assertEqual(PAIR_NONE);
      expect(SettingsStore.getPairId()).assertEqual('');
      expect(SettingsStore.getPartnerSnapVer()).assertEqual(0);
    });

    it('cancel_waiting_needs_no_cloud', 0, async () => {
      await SettingsStore.savePairId('stale-session');
      await SettingsStore.setPairState(PAIR_WAITING, 'stale-partner');
      AgcPairingClient.calls = 0;

      await ProfileSettingsService.cancelWaiting();

      expect(AgcPairingClient.calls).assertEqual(0);
      expect(SettingsStore.getPairState()).assertEqual(PAIR_NONE);
      expect(SettingsStore.getPairId()).assertEqual('');
    });

    it('local_only_features_keep_working_with_cloud_closed', 0, async () => {
      expect(FeatureFlags.cloudPairing).assertFalse();

      const level = await ProfileSettingsService.setShareLevel(3);
      expect(level.ok).assertTrue();
      expect(ProfileSettingsService.getShareLevel()).assertEqual(3);

      const partner = await ProfileSettingsService.savePartner({
        nick: '阿明', wakeText: '07:00', bedText: '23:00', windText: '20'
      });
      expect(partner.ok).assertTrue();
      const loaded = ProfileSettingsService.loadPartner();
      expect(loaded == null ? '' : loaded.nick).assertEqual('阿明');

      const deleted = await ProfileSettingsService.deletePartner();
      expect(deleted.ok).assertTrue();
      expect(ProfileSettingsService.loadPartner() == null).assertTrue();
    });

    it('clear_all_reports_the_projections_it_could_not_remove', 0, async () => {
      await emptyPlanTable();
      await mkPlanWithHandles('plan-dirty', 'evt-dirty', 41);
      await SettingsStore.savePairId('stale-session');
      await SettingsStore.setPairState(PAIRED, 'stale-partner');
      await SettingsStore.setPartnerSnapVer(9);
      await SettingsStore.acceptPrivacy();
      PlanCapabilities.bind(new RefusingCalendar(), new RefusingReminder());

      const dirty = await ProfileSettingsService.clearAllData();

      // 2 = 1 条日程 + 1 条计划级提醒；专属日历也没清掉，所以后半句要跟着出来
      expect(dirty.ok).assertTrue();
      expect(dirty.message).assertEqual('已清空本机全部数据；2 项系统日历/提醒可能仍在，'
        + '本应用已无法再替你清理，请到系统日历/系统设置检查；「同休日」日历没有清空，请到系统日历里检查');
      // 最终验收 R2：这条路径已经删掉了计划行与句柄，"可稍后重试"承诺的是做不到的动作。
      expect(dirty.message.indexOf('稍后重试') < 0).assertTrue();
      expect(await activePlanCount()).assertEqual(0);
      expect(await carryCount()).assertEqual(0);
      expect(SettingsStore.getPairState()).assertEqual(PAIR_NONE);
      expect(SettingsStore.getPairId()).assertEqual('');
      // 隐私同意标记是唯一被留下的设置：清掉它就会在重启后再弹一次首启弹窗
      expect(SettingsStore.isPrivacyAccepted()).assertTrue();
    });

    it('clear_all_says_so_when_the_system_side_is_clean', 0, async () => {
      await emptyPlanTable();
      await mkPlanWithHandles('plan-clean', 'evt-clean', 42);
      PlanCapabilities.bind(new CleanCalendar(), new OkReminder());

      const clean = await ProfileSettingsService.clearAllData();

      expect(clean.ok).assertTrue();
      expect(clean.message).assertEqual('已清空本机全部数据');
      expect(await activePlanCount()).assertEqual(0);
    });
  });
}
