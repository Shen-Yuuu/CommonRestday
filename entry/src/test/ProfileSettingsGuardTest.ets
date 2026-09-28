import { describe, it, expect } from '@ohos/hypium';
import { PAIRED, PAIR_NONE, PAIR_PENDING, PAIR_WAITING, PlanRow, ScheduleRepo, SettingsStore } from 'data';
import { AgcPairingClient, CloudApiError, CLOUD_NETWORK, PairKeyStore } from 'cloud';
import {
  CalendarCapability, CalendarOutcome, CalendarWriteResult, encodeSyncState, FeatureFlags,
  PlanCapabilities, ProfileSettingsService, ReminderCapability, RemoveOutcome, SYNC_STATE_BLOCKED
} from 'feature';

/**
 * 阶段 6R.2（独立验收 B1）＋批次 U·U3b：这几条用例打的是**两个档位各一格**。
 *
 * 开闸之前只有关闭态可跑，所以整份文件都是"关闭态一条请求都不发"。开闸之后源码常量是
 * `cloudPairing=true`，关闭态从此没有别的现场能证明它（真机上的包一定是开档的），
 * 于是 `tools/test/run.mjs` 支持 `CRD_TIER=closed|open` 改写**编译副本**的常量，
 * `tools/verify.mjs` 的两趟离线各跑一档、少跑任何一趟即判失败。每条用例因此读
 * `CLOUD_ON` 分桶，而不是把关闭态的用例删掉——守卫一旦哪天被挪动，闭档那一桶还是会红。
 *
 * 关闭态的三条主张保持不变：
 *
 * 1. 离线的云客户端**必定成功**（真机上 AGC 未配置时才必定失败）——少了开关守卫，
 *    pairId/pairState 就会在这一格里被写进本机，用例立刻响；
 * 2. 关闭态要求"一条云请求都不发"，所以断言的是同名计数器 `AgcPairingClient.calls` 为 0；
 *    开档则反过来要求**至少发出去一次**，否则守卫就成了把开着的门也挡住的黑洞；
 * 3. 关闭态不许把本机数据一起关掉：等级、代录、解除配对、清空数据照常（改造文档 §0.1「开关只关能力，不关数据」）；
 * 4. 长期密钥既不进 Preferences 也不进应用层：读/写密钥的 API 都不存在了，密钥只在 HUKS 别名里。
 *    所以关闭态断言的是**一次 HUKS 别名操作都不发生**（`PairKeyStore.calls`），
 *    比旧版那句"读回来是空串"更硬——旧断言能证明没写过，证明不了后来谁建了钥匙。
 *
 * 解除配对与取消等待是例外：它们允许调 `dropPairKey`，因为那是撤销而不是建立能力。
 *
 * 每条用例自己先把设置摆成已知的形状（上一版原型配对过的残留态），因此与文件顺序无关。
 */
const CLOSED = FeatureFlags.cloudClosedMessage;

/** 本跑生效的云端档位（`CRD_TIER` 改写的是编译副本，源码常量两档都读得到）。 */
const CLOUD_ON = FeatureFlags.cloudPairing;

/**
 * 让 fire-and-forget 的 promise 链跑完再断言。用 `setTimeout(…, 0)` 而不是空 `await`：
 * 心跳链里混着 Preferences 写入（真机上是异步 IO），宏任务一拍能把微任务队列整段排干。
 */
async function letItSettle(): Promise<void> {
  await new Promise<number>((resolve) => {
    setTimeout(resolve, 0);
  });
}

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

    it('create_invite_reaches_the_cloud_only_when_open', 0, async () => {
      await SettingsStore.savePairId('stale-session');
      await SettingsStore.setPairState(PAIR_WAITING, 'stale-partner');
      AgcPairingClient.calls = 0;
      PairKeyStore.calls = 0;

      const res = await ProfileSettingsService.createInvite();

      if (CLOUD_ON) {
        // 开档：守卫不许顺手把真的路径也挡掉。替身必定成功，所以这一格要看到一次别名、
        // 一次云调用，以及会话真的落进本机（关闭态那半句"残留态原样保留"反过来成立）。
        expect(res.ok).assertTrue();
        expect(res.code).assertEqual('246810');
        expect(AgcPairingClient.calls).assertEqual(1);
        expect(PairKeyStore.calls).assertEqual(1);
        expect(SettingsStore.getPairId()).assertEqual('session-from-the-cloud');
        expect(SettingsStore.getPairState()).assertEqual(PAIR_WAITING);
        expect(SettingsStore.getPartnerUid()).assertEqual('');
        return;
      }
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

      if (CLOUD_ON) {
        // 开档：加入停在 PENDING，绝不就地 PAIRED（协议 §4.2），非法码也不许先发请求
        expect(res.ok).assertTrue();
        expect(junk.ok).assertFalse();
        expect(junk.message).assertEqual('请输入 TA 分享的 6 位配对码');
        expect(AgcPairingClient.calls).assertEqual(1);
        // ensureIdentity + agreeKey：加入方就地完成协商，钥匙不在手就不写 pairId
        expect(PairKeyStore.calls).assertEqual(2);
        expect(SettingsStore.getPairState()).assertEqual(PAIR_PENDING);
        expect(SettingsStore.getPairId()).assertEqual('session-from-the-cloud');
        expect(ProfileSettingsService.getOutboundToken()).assertEqual('token-from-the-cloud');
        return;
      }
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

      // 「检查配对状态」的语义是"去云端对一次账"：两个档位都不许凭空造出 PAIRED，
      // 区别只在关闭态连门都不敲、且本机进度一格不动。
      expect(res.ok).assertFalse();
      expect(SettingsStore.getPairState()).assertEqual(PAIR_WAITING);
      if (CLOUD_ON) {
        // 替身回的 WAITING → 照实回落并说出"TA 还没有输入配对码"，不替云端谎报进度
        expect(res.message).assertEqual('TA 还没有输入配对码');
        expect(AgcPairingClient.calls).assertEqual(1);
        expect(PairKeyStore.calls).assertEqual(0);
        return;
      }
      expect(res.message).assertEqual(CLOSED);
      expect(AgcPairingClient.calls).assertEqual(0);
      expect(PairKeyStore.calls).assertEqual(0);
    });

    /**
     * 确认链接这条入口最坏的一格：本机什么都没做过，只凭别人发来的一串凭据就能转 PAIRED。
     * 关闭态一句拒绝、不留 pairId、不建别名、不发云对象；开档则是"云端没说 ACTIVE 就不许写"
     * ——协议 §4.3 的这条前置在两个档位都得成立，写 PAIRED 的唯一凭据是云端的回答。
     */
    it('confirm_with_token_needs_the_cloud_to_say_active', 0, async () => {
      // 上一条用例留下了 pairId 与 WAITING，这里自己摆回"本机从没配过对"的形状
      await SettingsStore.savePairId('');
      await SettingsStore.setPairState(PAIR_NONE, '');
      AgcPairingClient.calls = 0;
      PairKeyStore.calls = 0;
      // 上一条 join 留下的确认凭据（关闭态它本该是空串）：这条用例要证的是"拒绝不许改动它"
      const tokenBefore = ProfileSettingsService.getOutboundToken();

      const res = await ProfileSettingsService.confirmWithToken('token-from-a-shared-link');

      expect(res.ok).assertFalse();
      expect(AgcPairingClient.calls).assertEqual(0);
      expect(PairKeyStore.calls).assertEqual(0);
      expect(SettingsStore.getPairState()).assertEqual(PAIR_NONE);
      expect(SettingsStore.getPairId()).assertEqual('');
      expect(ProfileSettingsService.getOutboundToken()).assertEqual(tokenBefore);
      if (CLOUD_ON) {
        // 开档：手里没有会话时，别人发来的凭据本身不算数（拒绝话术是"现在没有要确认的配对"）
        expect(res.message !== CLOSED).assertTrue();
        // 有会话、且云端回的正是 ACTIVE，才轮到写 PAIRED
        await SettingsStore.savePairId('session-from-the-cloud');
        AgcPairingClient.calls = 0;
        PairKeyStore.calls = 0;
        const done = await ProfileSettingsService.confirmWithToken('token-from-the-cloud');
        await letItSettle();
        expect(done.ok).assertTrue();
        expect(AgcPairingClient.calls >= 1).assertTrue();
        expect(PairKeyStore.calls >= 1).assertTrue();
        expect(SettingsStore.getPairState()).assertEqual(PAIRED);
        // 确认完成，本机手里这份一次性凭据就地作废（协议 §4.3：它换过一次 ACTIVE 就没用了）
        expect(ProfileSettingsService.getOutboundToken()).assertEqual('');
        return;
      }
      expect(res.message).assertEqual(CLOSED);
    });

    it('unpair_clears_local_marks_in_every_tier', 0, async () => {
      await SettingsStore.savePairId('session-left-by-the-prototype');
      await SettingsStore.setPairState(PAIRED, 'old-partner-uid');
      await SettingsStore.setPartnerSnapVer(7);
      // 上一轮配对留下的「已降级」：语义是"排不动推送，直到某次拉成功"，留着它，下一轮配对
      // 从第一版配对起就静默不推，而界面上那条提示讲的是上一个配对的事。
      await SettingsStore.setCloudSyncState(encodeSyncState(SYNC_STATE_BLOCKED, 20453, 'FORBIDDEN'));
      // 最后一次有效快照的信封：HUKS 别名一删它永久解不开，留着就是挂在下一轮配对上的死数据。
      await SettingsStore.setPartnerSnapCache('{"pairId":"session-left-by-the-prototype","version":7}');
      AgcPairingClient.calls = 0;

      const res = await ProfileSettingsService.unpair();

      // 入口藏着但退出必须留着：残留的 PAIRED 说不清来源，用户要能亲手撤掉。
      // 这一半两档相同；不同的只是开档要顺手把云端那两行也删掉（隐私政策「怎么撤」说的就是它）。
      expect(res.ok).assertTrue();
      expect(AgcPairingClient.calls).assertEqual(CLOUD_ON ? 1 : 0);
      expect(SettingsStore.getPairState()).assertEqual(PAIR_NONE);
      expect(SettingsStore.getPairId()).assertEqual('');
      expect(SettingsStore.getPartnerSnapVer()).assertEqual(0);
      expect(SettingsStore.getPartnerSnapCache()).assertEqual('');
      expect(SettingsStore.getCloudSyncState()).assertEqual('');
    });

    /**
     * 云端删不动时，解除配对**一个字节都不许先清**（批次 U·U5 修的就是这一格）。
     *
     * 旧写法把云侧异常吞成一句 warn，接着照删 pairId 与 HUKS 别名，最后回一句「已解除配对」。
     * 那是三份损失叠成的一句假话：协议 §4.5 里删除的凭据就是 `pairId` + `uid`，本机一清，
     * 云上那行密文从此谁都对不上号；界面上"已解除"又把欠账抹平，用户连重试的入口都摸不到。
     * 所以这里断言的是"失败之后手里还剩什么"：配对态、pairId、游标、信封、三态、别名全部原样，
     * 而重试入口就是同一颗按钮——不再另存一份凭据，多一处存就多一处会漂。
     */
    it('unpair_keeps_every_credential_when_the_cloud_refuses', 0, async () => {
      await SettingsStore.savePairId('session-still-on-the-cloud');
      await SettingsStore.setPairState(PAIRED, 'peer-uid');
      await SettingsStore.setPartnerSnapVer(9);
      await SettingsStore.setPartnerSnapCache('{"pairId":"session-still-on-the-cloud","version":9}');
      await SettingsStore.setCloudSyncState(encodeSyncState(SYNC_STATE_BLOCKED, 20453, 'FORBIDDEN'));
      await SettingsStore.clearPendingCloudUnpair();
      AgcPairingClient.calls = 0;
      PairKeyStore.calls = 0;
      AgcPairingClient.unpairFailure = new CloudApiError(CLOUD_NETWORK, true, 'no signal');

      const refused = await ProfileSettingsService.unpair();
      AgcPairingClient.unpairFailure = null;

      if (!CLOUD_ON) {
        // 关闭态没有云端可删，本机标记照旧一手清掉（「开关只关能力，不关数据」）
        expect(refused.ok).assertTrue();
        expect(refused.message).assertEqual('已解除配对');
        expect(AgcPairingClient.calls).assertEqual(0);
        expect(SettingsStore.getPairState()).assertEqual(PAIR_NONE);
        expect(SettingsStore.getPairId()).assertEqual('');
        return;
      }

      expect(refused.ok).assertFalse();
      expect(AgcPairingClient.calls).assertEqual(1);
      // 失败的话术要说出"云上那份还在"，而不是把错误码念给用户
      expect(refused.message.indexOf('云上那份还没删掉') >= 0).assertTrue();
      expect(refused.message.indexOf('配对我留着了') >= 0).assertTrue();
      expect(SettingsStore.getPairState()).assertEqual(PAIRED);
      expect(SettingsStore.getPairId()).assertEqual('session-still-on-the-cloud');
      expect(SettingsStore.getPartnerSnapVer()).assertEqual(9);
      expect(SettingsStore.getPartnerSnapCache()).assertEqual('{"pairId":"session-still-on-the-cloud","version":9}');
      expect(SettingsStore.getCloudSyncState())
        .assertEqual(encodeSyncState(SYNC_STATE_BLOCKED, 20453, 'FORBIDDEN'));
      // 一次都没去碰 HUKS 别名：删了它，重试时要解的东西就真解不开了
      expect(PairKeyStore.calls).assertEqual(0);
      // 也不落待补删凭据——本机这一屏就是凭据
      expect(SettingsStore.getPendingCloudUnpair() == null).assertTrue();

      // 网络回来了：同一颗按钮再点一次就补上，用户不需要先去做别的动作
      const second = await ProfileSettingsService.unpair();
      expect(second.ok).assertTrue();
      expect(second.message).assertEqual('已解除配对');
      expect(AgcPairingClient.calls).assertEqual(2);
      expect(PairKeyStore.calls).assertEqual(1);
      expect(SettingsStore.getPairState()).assertEqual(PAIR_NONE);
      expect(SettingsStore.getPairId()).assertEqual('');
      expect(SettingsStore.getPartnerSnapVer()).assertEqual(0);
    });

    /**
     * 回前台补删那条欠账（`retryPendingCloudUnpair`，挂在 `EntryAbility.onForeground` 的初始化链尾）。
     *
     * 清库之后本机只剩 `pending_cloud_unpair` 这一处记得云上还有东西，所以"什么时候必须继续敲"
     * 与"什么时候不再敲"两格都得钉住。后者尤其要紧：免费档的按天配额是**项目级共享**的，
     * 而云端一旦给了终局判定（不是那个会话的成员）再敲一百次也是同一句——留着就是白付。
     */
    it('pending_cloud_unpair_retry_stops_at_a_final_verdict', 0, async () => {
      await SettingsStore.setPendingCloudUnpair('orphan-session', 'uid-from-before-the-wipe');
      AgcPairingClient.calls = 0;

      if (!CLOUD_ON) {
        await ProfileSettingsService.retryPendingCloudUnpair();
        expect(AgcPairingClient.calls).assertEqual(0);
        // 守卫在第一句：连欠账都不去读，原样留着等开档
        expect(SettingsStore.getPendingCloudUnpair() == null).assertFalse();
        await SettingsStore.clearPendingCloudUnpair();
        await ProfileSettingsService.retryPendingCloudUnpair();
        expect(AgcPairingClient.calls).assertEqual(0);
        return;
      }

      // 通路还没通：欠账必须留着，否则这台设备就再也没有删掉它的办法
      AgcPairingClient.unpairFailure = new CloudApiError(CLOUD_NETWORK, true, 'no signal');
      await ProfileSettingsService.retryPendingCloudUnpair();
      expect(AgcPairingClient.calls).assertEqual(1);
      expect(SettingsStore.getPendingCloudUnpair() == null).assertFalse();
      AgcPairingClient.unpairFailure = null;

      // 通了：删完就地清掉，凭据不该留在机器上过夜
      await ProfileSettingsService.retryPendingCloudUnpair();
      expect(AgcPairingClient.calls).assertEqual(2);
      expect(SettingsStore.getPendingCloudUnpair() == null).assertTrue();

      // 会话行本来就不在：服务端把"已经删过了"报成 OK + 0 行（§4.5 幂等），欠账同样就地清掉
      await SettingsStore.setPendingCloudUnpair('already-gone', 'uid-y');
      await ProfileSettingsService.retryPendingCloudUnpair();
      expect(AgcPairingClient.calls).assertEqual(3);
      expect(SettingsStore.getPendingCloudUnpair() == null).assertTrue();

      // 终局判定：不是成员 = 这份数据不归这台设备删，凭据跟着走，不再白敲门
      await SettingsStore.setPendingCloudUnpair('not-mine', 'uid-z');
      AgcPairingClient.unpairFailure = new CloudApiError('FORBIDDEN', false, 'not a member');
      await ProfileSettingsService.retryPendingCloudUnpair();
      expect(AgcPairingClient.calls).assertEqual(4);
      expect(SettingsStore.getPendingCloudUnpair() == null).assertTrue();
      AgcPairingClient.unpairFailure = null;
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

    /**
     * 心跳（协议 §4.6，U3b-1 接线）跟着档位走：关闭态必须**完全静默**——`beatIfDue` 是回前台挂的
     * fire-and-forget，一旦漏了守卫，每台装了本机的设备都会替一个从没配过对的用户去敲 AGC 的门。
     * 这里刻意把设置摆成"已配对且游标为 0"（也就是最该发的一格），好让这条断言打的是守卫本身，
     * 而不是顺带被节流挡掉。开档则要求这一格**真的发出去并且落下游标**，否则守卫是堵死而不是开关。
     */
    it('beat_if_due_follows_the_cloud_tier', 0, async () => {
      await SettingsStore.savePairId('stale-session');
      await SettingsStore.setPairState(PAIRED, 'stale-partner');
      await SettingsStore.setLastHeartbeatAt(0);
      AgcPairingClient.calls = 0;
      PairKeyStore.calls = 0;

      ProfileSettingsService.beatIfDue();

      if (CLOUD_ON) {
        await letItSettle();
        expect(AgcPairingClient.calls).assertEqual(1);
        expect(SettingsStore.getLastHeartbeatAt() > 0).assertTrue();
        return;
      }
      // 守卫是 `beatIfDue` 的第一句，所以这里可以同步断言：连 uid 都没去取，谈不上发请求
      expect(AgcPairingClient.calls).assertEqual(0);
      expect(PairKeyStore.calls).assertEqual(0);
      // 游标没被写：一次都没发出去，就不该留下"最近跳过"的假证据
      expect(SettingsStore.getLastHeartbeatAt()).assertEqual(0);
    });

    /**
     * 「该不该跳」的判断单独断言（`heartbeatDue` 是纯函数）。为什么不能只靠上一条：
     * 上一条按档位分桶，闭档那一跑只证明守卫，开档那一跑只证明"会发"，而**按时间的四格**
     * （未心跳 / 窗口内 / 窗口满 / 时钟回拨）在两跑里都只走同一格；设备侧又改不了系统钟
     * （无 root，`date -s` 回 Operation not permitted），所以权威覆盖只能落在这几条断言上（同 D-39）。
     */
    it('heartbeat_due_predicate_covers_eligibility_and_window', 0, async () => {
      const now = 1777000000000;
      const day = 86400000;

      // 收窄资格：本机没有 pairId 就永远不发，哪怕游标老到跨年——保护的是自己的云端数据，
      // 不是替整个项目交配额（协议 §4.6 端侧口径）
      expect(ProfileSettingsService.heartbeatDue('', 0, now)).assertFalse();
      expect(ProfileSettingsService.heartbeatDue('', now - 400 * day, now)).assertFalse();
      // 已配对且从未心跳（0）或偏好里是脏值（Number 给出 NaN）都要发
      expect(ProfileSettingsService.heartbeatDue('pair-1', 0, now)).assertTrue();
      expect(ProfileSettingsService.heartbeatDue('pair-1', Number('dirty'), now)).assertTrue();
      // 窗口内不发，窗口满要发：边界按"到点即到期"取，不留一整天的缝隙
      expect(ProfileSettingsService.heartbeatDue('pair-1', now - day, now)).assertFalse();
      expect(ProfileSettingsService.heartbeatDue('pair-1', now - (7 * day - 1), now)).assertFalse();
      expect(ProfileSettingsService.heartbeatDue('pair-1', now - 7 * day, now)).assertTrue();
      // 时钟回拨（游标落在未来）判为到期：宁可多跳一次，也不要一次改表就永久停跳
      expect(ProfileSettingsService.heartbeatDue('pair-1', now + day, now)).assertTrue();
    });

    it('local_only_features_keep_working_with_cloud_closed', 0, async () => {
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

    /**
     * 清空全部数据时云端删不动：本机照清，云上那份**留下能重试的凭据**，话要说全（批次 U·U5）。
     *
     * 这里与上一条 `unpair` 的口径**故意不同**：清空是用户对自己设备的即时处置权，不该因为
     * 云侧一次失败就把本机数据锁在"还在"的状态里。所以断言的重心是清完之后本机还剩什么——
     * 只剩 `pending_cloud_unpair` 那两个字符串。协议 §4.5 的删除只认会话成员（`pairId` + `uid`），
     * 密钥材料对删除毫无用处，所以这两个字段既够用也有界：多存一个字段就多一处会漂的披露面。
     * `uid` 取的是**清库之前**那一个：`clearAllSettings()` 把 `device_uid` 一起推平，事后再生成的
     * 新 uid 不是那个会话的成员，补删永远撞 FORBIDDEN——这一格只能靠断言钉住。
     */
    it('clear_all_leaves_a_cloud_retry_credential_and_says_so', 0, async () => {
      await emptyPlanTable();
      await mkPlanWithHandles('plan-cloud', 'evt-cloud', 43);
      PlanCapabilities.bind(new CleanCalendar(), new OkReminder());
      await SettingsStore.savePairId('session-to-wipe');
      await SettingsStore.setPairState(PAIRED, 'peer-uid');
      await SettingsStore.setPartnerSnapVer(9);
      await SettingsStore.clearPendingCloudUnpair();
      const uidBefore = await SettingsStore.getOrCreateUid();
      AgcPairingClient.calls = 0;
      AgcPairingClient.unpairFailure = new CloudApiError(CLOUD_NETWORK, true, 'no signal');

      const wiped = await ProfileSettingsService.clearAllData();
      AgcPairingClient.unpairFailure = null;

      if (!CLOUD_ON) {
        // 关闭态没有"云上那份"可言，欠账也无从记起：整句就是本地清空的口径
        expect(wiped.ok).assertTrue();
        expect(wiped.message).assertEqual('已清空本机全部数据');
        expect(AgcPairingClient.calls).assertEqual(0);
        expect(SettingsStore.getPendingCloudUnpair() == null).assertTrue();
        return;
      }

      expect(wiped.ok).assertTrue();
      expect(AgcPairingClient.calls).assertEqual(1);
      expect(wiped.message).assertEqual('已清空本机全部数据；云上那份加密快照还没删掉，下次打开应用会自动再试一次');
      // 最终验收 R2 的禁句仍然成立：这句"会自动再试"背后有落库的凭据撑着，不是空承诺
      expect(wiped.message.indexOf('稍后重试') < 0).assertTrue();
      // 本机这一侧确实清干净了，没有因为云端删不动而少清一项
      expect(await activePlanCount()).assertEqual(0);
      expect(SettingsStore.getPairState()).assertEqual(PAIR_NONE);
      expect(SettingsStore.getPairId()).assertEqual('');
      expect(SettingsStore.getPartnerSnapVer()).assertEqual(0);
      const left = SettingsStore.getPendingCloudUnpair();
      expect(left == null ? '' : left.pairId).assertEqual('session-to-wipe');
      expect(left == null ? '' : left.uid).assertEqual(uidBefore);

      // 下一次回前台补删成功：凭据就地清掉，不让它在这台机器上过夜
      await ProfileSettingsService.retryPendingCloudUnpair();
      expect(AgcPairingClient.calls).assertEqual(2);
      expect(SettingsStore.getPendingCloudUnpair() == null).assertTrue();

      // 还没补成又清一次：第二次不许把第一条欠账顶掉（它自己也没删动，记的还是同一格）
      await SettingsStore.setPendingCloudUnpair('orphan-session', 'uid-of-the-orphan');
      AgcPairingClient.unpairFailure = new CloudApiError(CLOUD_NETWORK, true, 'no signal');
      const again = await ProfileSettingsService.clearAllData();
      AgcPairingClient.unpairFailure = null;
      expect(again.ok).assertTrue();
      expect(AgcPairingClient.calls).assertEqual(3);
      const still = SettingsStore.getPendingCloudUnpair();
      expect(still == null ? '' : still.pairId).assertEqual('orphan-session');
      expect(still == null ? '' : still.uid).assertEqual('uid-of-the-orphan');

      await SettingsStore.clearPendingCloudUnpair();
    });
  });
}
