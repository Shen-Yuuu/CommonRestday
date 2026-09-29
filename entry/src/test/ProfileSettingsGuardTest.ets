import { describe, it, expect } from '@ohos/hypium';
import { PAIRED, PAIR_NONE, PAIR_PENDING, PAIR_WAITING, PendingCloudUnpair, PlanRow, ScheduleRepo, SettingsStore } from 'data';
import { AgcPairingClient, CloudApiError, CLOUD_NETWORK, PairKeyStore } from 'cloud';
import {
  CalendarCapability, CalendarOutcome, CalendarWriteResult, encodeSyncState, FeatureFlags,
  PlanCapabilities, ProfileSettingsService, ReminderCapability, RemoveOutcome,
  SHARE_LEVEL_UNKNOWN, SYNC_STATE_BLOCKED
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
 * 批次 AO 在这一份文件里补的是**同一批入口的四格欠账**，每一格都各打两个档位：
 *
 * 1. 关闭态（按发布预案回退一档）不许把云端欠账一起关掉：`unpair`／`clearAllData` 都要留下
 *    待补删凭据，并把「云上那份还没删掉」说出来，只是话里得改口成"开通后再试"；
 * 2. 待补删凭据从一格变成一条队列，于是「欠账 → 又配了一次 → 再清空」不会把旧欠账顶掉；
 * 3. 云端给了终局判定的那一行不再自动敲门，但**必须留在偏好里被界面报数**（`undeletableCloudSnapshots`），
 *    不然这个结论只活在日志里；
 * 4. 共享等级读不出来就是「未知」，不折成 L1 也不折成 L2，更不许当设置存下去；
 * 5. 心跳游标跟着配对一起销毁，且旧会话那一跳的迟到返回值不许写进新会话的游标。
 *
 * 每条用例自己先把设置摆成已知的形状（上一版原型配对过的残留态），因此与文件顺序无关。
 * `pending_cloud_unpair`、`share_level` 与两个测试开关注入都是跨用例存活的状态，
 * 所以每条用例开头都要自己清一次——它们没有 `beforeEach` 可依赖。
 */
const CLOSED = FeatureFlags.cloudClosedMessage;

/** 关闭态解除配对那句的开头（批次 AO·AO1：本机照清，欠账照记，话要说全）。 */
const CLOSED_UNPAIR_HEAD = '本机配对已解除';

/** 本跑生效的云端档位（`CRD_TIER` 改写的是编译副本，源码常量两档都读得到）。 */
const CLOUD_ON = FeatureFlags.cloudPairing;

/**
 * 关闭态清空时，本机手里那个 pairId 会被记成待补删欠账，并跟着说进消息里（批次 AO·AO1）。
 * 开档删干净了，这一句就是空串——同一个入口在两个档位各说一句不同的实话。
 */
const CLOSED_CLEAR_NOTE = CLOUD_ON
  ? ''
  : '；云上那份加密快照还没删掉（云端功能目前没开通），开通后打开应用会自动再试一次';

/** 待补删队列里按 pairId 找一条（批次 AO 起队列可以有好几条，顺序不再是断言的对象）。 */
function debtOf(list: PendingCloudUnpair[], pairId: string): PendingCloudUnpair | null {
  for (let i = 0; i < list.length; i++) {
    if (list[i].pairId === pairId) {
      return list[i];
    }
  }
  return null;
}

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

    /**
     * 解除配对的"本机这一半"（两档同规格）＋ 批次 AO 的两格：
     * **AO5** 心跳游标要跟着配对一起归零（旧游标留着，下一轮配对最多空等一周才发第一跳）；
     * **AO1** 关闭态也要把云端欠账记下来，只把话改口成"开通后再试"。
     */
    it('unpair_clears_local_marks_in_every_tier', 0, async () => {
      await SettingsStore.savePairId('session-left-by-the-prototype');
      await SettingsStore.setPairState(PAIRED, 'old-partner-uid');
      await SettingsStore.setPartnerSnapVer(7);
      // 上一轮配对留下的「已降级」：语义是"排不动推送，直到某次拉成功"，留着它，下一轮配对
      // 从第一版配对起就静默不推，而界面上那条提示讲的是上一个配对的事。
      await SettingsStore.setCloudSyncState(encodeSyncState(SYNC_STATE_BLOCKED, 20453, 'FORBIDDEN'));
      // 最后一次有效快照的信封：HUKS 别名一删它永久解不开，留着就是挂在下一轮配对上的死数据。
      await SettingsStore.setPartnerSnapCache('{"pairId":"session-left-by-the-prototype","version":7}');
      // 上一轮配对最后一次心跳的时刻（批次 AO·AO5 断言的就是它被清零）
      await SettingsStore.setLastHeartbeatAt(1777000000000);
      await SettingsStore.clearPendingCloudUnpair();
      AgcPairingClient.calls = 0;
      AgcPairingClient.unpairFailure = null;
      const uidBefore = await SettingsStore.getOrCreateUid();

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
      expect(SettingsStore.getLastHeartbeatAt()).assertEqual(0);

      const debt = SettingsStore.getPendingCloudUnpair();
      if (CLOUD_ON) {
        // 云端删掉了：欠账就地清干净，不该留任何"云上还有东西"的尾巴
        expect(res.message).assertEqual('已解除配对');
        expect(debt.length).assertEqual(0);
        return;
      }
      // 关闭态：一句云请求都不发（上面 calls===0 已经钉住），但这一笔照记成欠账——
      // 按发布预案回退一档只是关掉能力，不该顺手把云上那份密文判成谁都对不上号的孤儿行。
      expect(debt.length).assertEqual(1);
      expect(debt[0].pairId).assertEqual('session-left-by-the-prototype');
      expect(debt[0].uid).assertEqual(uidBefore);
      expect(debt[0].dead).assertFalse();
      expect(res.message).assertEqual(CLOSED_UNPAIR_HEAD
        + '；云上那份加密快照还没删掉（云端功能目前没开通），开通后打开应用会自动再试一次');
      await SettingsStore.clearPendingCloudUnpair();
    });

    /**
     * 云端删不动时，解除配对**一个字节都不许先清**（批次 U·U5 修的就是这一格）。
     *
     * 旧写法把云侧异常吞成一句 warn，接着照删 pairId 与 HUKS 别名，最后回一句「已解除配对」。
     * 那是三份损失叠成的一句假话：协议 §4.5 里删除的凭据就是 `pairId` + `uid`，本机一清，
     * 云上那行密文从此谁都对不上号；界面上"已解除"又把欠账抹平，用户连重试的入口都摸不到。
     * 所以这里断言的是"失败之后手里还剩什么"：配对态、pairId、游标、信封、三态、别名全部原样，
     * 而重试入口就是同一颗按钮——还值得再敲的那一笔不另存凭据，多一处存就多一处会漂。
     * 批次 AO 给这一条加了两段：关闭态**没有这一屏可留**，所以改记欠账（AO1）；
     * 云端判死的那一行敲第二次也是白敲（免费档按天配额是项目级共享的），所以它要落进队列被界面报数（AO3）。
     */
    it('unpair_keeps_every_credential_when_the_cloud_refuses', 0, async () => {
      await SettingsStore.savePairId('session-still-on-the-cloud');
      await SettingsStore.setPairState(PAIRED, 'peer-uid');
      await SettingsStore.setPartnerSnapVer(9);
      await SettingsStore.setPartnerSnapCache('{"pairId":"session-still-on-the-cloud","version":9}');
      await SettingsStore.setCloudSyncState(encodeSyncState(SYNC_STATE_BLOCKED, 20453, 'FORBIDDEN'));
      await SettingsStore.clearPendingCloudUnpair();
      AgcPairingClient.calls = 0;
      AgcPairingClient.unpairFailure = null;
      PairKeyStore.calls = 0;
      const uidBefore = await SettingsStore.getOrCreateUid();

      AgcPairingClient.unpairFailure = new CloudApiError(CLOUD_NETWORK, true, 'no signal');

      const refused = await ProfileSettingsService.unpair();
      AgcPairingClient.unpairFailure = null;

      if (!CLOUD_ON) {
        // 关闭态（批次 AO·AO1）：没有云端可删，本机标记照旧一手清掉（「开关只关能力，不关数据」），
        // 但这一笔 pairId + uid 必须记成欠账——回退版本关掉的只是能力，不是替用户把云上那份判成孤儿。
        expect(refused.ok).assertTrue();
        expect(refused.message.indexOf(CLOSED_UNPAIR_HEAD)).assertEqual(0);
        expect(refused.message.indexOf('云上那份加密快照还没删掉（云端功能目前没开通）') >= 0).assertTrue();
        expect(AgcPairingClient.calls).assertEqual(0);
        expect(SettingsStore.getPairState()).assertEqual(PAIR_NONE);
        expect(SettingsStore.getPairId()).assertEqual('');
        const debt = SettingsStore.getPendingCloudUnpair();
        expect(debt.length).assertEqual(1);
        expect(debt[0].pairId).assertEqual('session-still-on-the-cloud');
        expect(debt[0].uid).assertEqual(uidBefore);
        expect(debt[0].dead).assertFalse();
        expect(ProfileSettingsService.undeletableCloudSnapshots()).assertEqual(0);
        await SettingsStore.clearPendingCloudUnpair();
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
      // 也不落待补删凭据——这一屏本身就是"还值得再敲"的那一笔的凭据，多存一份就多一处会漂

      // 网络回来了：同一颗按钮再点一次就补上，用户不需要先去做别的动作
      const second = await ProfileSettingsService.unpair();
      expect(second.ok).assertTrue();
      expect(second.message).assertEqual('已解除配对');
      expect(AgcPairingClient.calls).assertEqual(2);
      expect(PairKeyStore.calls).assertEqual(1);
      expect(SettingsStore.getPairState()).assertEqual(PAIR_NONE);
      expect(SettingsStore.getPairId()).assertEqual('');
      expect(SettingsStore.getPartnerSnapVer()).assertEqual(0);
      expect(SettingsStore.getPendingCloudUnpair().length).assertEqual(0);

      /**
       * 第三段（批次 AO·AO3）：云端给的是**终局判定**（不是这个会话的成员）。
       * 本机标记仍然留着（fail-closed 的前提没变），但这一行从此不再值得敲第二次，
       * 于是它必须落进队列并被界面报数——只在日志里留一句 warn，用户看不见这份数据还在云上。
       */
      await SettingsStore.savePairId('session-not-mine');
      await SettingsStore.setPairState(PAIRED, 'peer-uid');
      AgcPairingClient.calls = 0;
      AgcPairingClient.unpairFailure = new CloudApiError('FORBIDDEN', false, 'not a member');
      const judged = await ProfileSettingsService.unpair();
      AgcPairingClient.unpairFailure = null;

      expect(judged.ok).assertFalse();
      expect(AgcPairingClient.calls).assertEqual(1);
      expect(SettingsStore.getPairId()).assertEqual('session-not-mine');
      const dead = debtOf(SettingsStore.getPendingCloudUnpair(), 'session-not-mine');
      expect(dead == null ? 'missing' : dead.pairId).assertEqual('session-not-mine');
      expect(dead == null ? false : dead.dead).assertTrue();
      expect(ProfileSettingsService.undeletableCloudSnapshots()).assertEqual(1);
      await SettingsStore.clearPendingCloudUnpair();
    });

    /**
     * 回前台补删那条欠账（`retryPendingCloudUnpair`，挂在 `EntryAbility.onForeground` 的初始化链尾）。
     *
     * 清库之后本机只剩 `pending_cloud_unpair` 这一处记得云上还有东西，所以"什么时候必须继续敲"
     * 与"什么时候不再敲"两格都得钉住。后者尤其要紧：免费档的按天配额是**项目级共享**的，
     * 而云端一旦给了终局判定（不是那个会话的成员）再敲一百次也是同一句。批次 AO·AO3 分开了这两件事：
     * **不再敲**（省配额）与**不再提**（用户就看不见那份还躺在云上的密文）不是一回事，
     * 所以那一行翻成 `dead` 留在队列里报数，而不是连记录一起删掉。
     */
    it('pending_cloud_unpair_retry_stops_at_a_final_verdict', 0, async () => {
      await SettingsStore.clearPendingCloudUnpair();
      await SettingsStore.addPendingCloudUnpair('orphan-session', 'uid-from-before-the-wipe', false);
      AgcPairingClient.calls = 0;
      AgcPairingClient.unpairFailure = null;

      if (!CLOUD_ON) {
        await ProfileSettingsService.retryPendingCloudUnpair();
        expect(AgcPairingClient.calls).assertEqual(0);
        // 守卫在第一句：连欠账都不去读，原样留着等开档
        const kept = SettingsStore.getPendingCloudUnpair();
        expect(kept.length).assertEqual(1);
        expect(kept[0].pairId).assertEqual('orphan-session');
        expect(ProfileSettingsService.undeletableCloudSnapshots()).assertEqual(0);
        await SettingsStore.clearPendingCloudUnpair();
        await ProfileSettingsService.retryPendingCloudUnpair();
        expect(AgcPairingClient.calls).assertEqual(0);
        return;
      }

      // 通路还没通：欠账必须留着，否则这台设备就再也没有删掉它的办法
      AgcPairingClient.unpairFailure = new CloudApiError(CLOUD_NETWORK, true, 'no signal');
      await ProfileSettingsService.retryPendingCloudUnpair();
      expect(AgcPairingClient.calls).assertEqual(1);
      const owing = SettingsStore.getPendingCloudUnpair();
      expect(owing.length).assertEqual(1);
      expect(owing[0].pairId).assertEqual('orphan-session');
      expect(owing[0].dead).assertFalse();
      AgcPairingClient.unpairFailure = null;

      // 通了：删完就地清掉，凭据不该留在机器上过夜
      await ProfileSettingsService.retryPendingCloudUnpair();
      expect(AgcPairingClient.calls).assertEqual(2);
      expect(SettingsStore.getPendingCloudUnpair().length).assertEqual(0);

      // 会话行本来就不在：服务端把"已经删过了"报成 OK + 0 行（§4.5 幂等），欠账同样就地清掉
      await SettingsStore.addPendingCloudUnpair('already-gone', 'uid-y', false);
      await ProfileSettingsService.retryPendingCloudUnpair();
      expect(AgcPairingClient.calls).assertEqual(3);
      expect(SettingsStore.getPendingCloudUnpair().length).assertEqual(0);

      // 终局判定：不是成员 = 这份数据不归这台设备删。**旧写法在这里删掉记录**，
      // 于是"云上还剩一份删不掉"这个结论只活在日志里（批次 AO·AO3）——现在它翻成 dead 留着报数。
      await SettingsStore.addPendingCloudUnpair('not-mine', 'uid-z', false);
      AgcPairingClient.unpairFailure = new CloudApiError('FORBIDDEN', false, 'not a member');
      await ProfileSettingsService.retryPendingCloudUnpair();
      AgcPairingClient.unpairFailure = null;
      expect(AgcPairingClient.calls).assertEqual(4);
      const judged = debtOf(SettingsStore.getPendingCloudUnpair(), 'not-mine');
      expect(judged == null ? 'gone' : judged.pairId).assertEqual('not-mine');
      expect(judged == null ? false : judged.dead).assertTrue();
      expect(ProfileSettingsService.undeletableCloudSnapshots()).assertEqual(1);

      // 判死的那一行不再进补删队列：下一次回前台一句都不敲——免费档的按天配额是项目级共享的
      AgcPairingClient.calls = 0;
      await ProfileSettingsService.retryPendingCloudUnpair();
      expect(AgcPairingClient.calls).assertEqual(0);
      expect(ProfileSettingsService.undeletableCloudSnapshots()).assertEqual(1);

      // 同一条队列里"还值得再敲"的那一笔不许被 dead 那一条挡住（AO2 起队列可以有好几条）
      await SettingsStore.addPendingCloudUnpair('still-owing', 'uid-w', false);
      await ProfileSettingsService.retryPendingCloudUnpair();
      expect(AgcPairingClient.calls).assertEqual(1);
      const after = SettingsStore.getPendingCloudUnpair();
      expect(after.length).assertEqual(1);
      expect(after[0].pairId).assertEqual('not-mine');
      expect(SettingsStore.countDeadCloudUnpair()).assertEqual(1);

      await SettingsStore.clearPendingCloudUnpair();
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
      await SettingsStore.clearPendingCloudUnpair();
      PlanCapabilities.bind(new RefusingCalendar(), new RefusingReminder());

      const dirty = await ProfileSettingsService.clearAllData();

      // 2 = 1 条日程 + 1 条计划级提醒；专属日历也没清掉，所以后半句要跟着出来。
      // 末尾那半句是关闭态专属的：本机手里有 pairId 而云端没敲，清空就得把这笔账记下来并说出来（AO1）。
      expect(dirty.ok).assertTrue();
      expect(dirty.message).assertEqual('已清空本机全部数据；2 项系统日历/提醒可能仍在，'
        + '本应用已无法再替你清理，请到系统日历/系统设置检查；「同休日」日历没有清空，请到系统日历里检查'
        + CLOSED_CLEAR_NOTE);
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
      // 这一格测的是"系统侧也干净时只说本地那一句"，所以本机手里不该有任何 pairId 或欠账：
      // 关闭态下那两者都会追加一笔待补删的说明（AO1），留到上一条用例的残留里就会串味。
      await SettingsStore.savePairId('');
      await SettingsStore.setPairState(PAIR_NONE, '');
      await SettingsStore.clearPendingCloudUnpair();
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
     * 只剩 `pending_cloud_unpair` 里那几对字符串（批次 AO·AO2 起是一条队列，不再是一格）。
     * 协议 §4.5 的删除只认会话成员（`pairId` + `uid`），
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
        // 关闭态（批次 AO·AO1，也就是"回退版本测试"那一格）：没有云请求可发，但欠账照记、
        // 话照说，只是把"下次打开会自动再试"改口成"开通后再试"——不说清就是拿一条当下走不通的路径作承诺。
        expect(wiped.ok).assertTrue();
        expect(wiped.message).assertEqual('已清空本机全部数据；'
          + '云上那份加密快照还没删掉（云端功能目前没开通），开通后打开应用会自动再试一次');
        expect(AgcPairingClient.calls).assertEqual(0);
        const debt = SettingsStore.getPendingCloudUnpair();
        expect(debt.length).assertEqual(1);
        expect(debt[0].pairId).assertEqual('session-to-wipe');
        // uid 取的仍然是**清库之前**那一个：关闭态也一样，否则开通后补删永远撞 FORBIDDEN
        expect(debt[0].uid).assertEqual(uidBefore);
        expect(debt[0].dead).assertFalse();
        await SettingsStore.clearPendingCloudUnpair();
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
      expect(left.length).assertEqual(1);
      expect(left[0].pairId).assertEqual('session-to-wipe');
      expect(left[0].uid).assertEqual(uidBefore);

      // 下一次回前台补删成功：凭据就地清掉，不让它在这台机器上过夜
      await ProfileSettingsService.retryPendingCloudUnpair();
      expect(AgcPairingClient.calls).assertEqual(2);
      expect(SettingsStore.getPendingCloudUnpair().length).assertEqual(0);

      // 还没补成又清一次：这一次记的是队列里的另一条，不许把前一条顶掉（批次 AO·AO2 改成队列的动因）
      await SettingsStore.addPendingCloudUnpair('orphan-session', 'uid-of-the-orphan', false);
      AgcPairingClient.unpairFailure = new CloudApiError(CLOUD_NETWORK, true, 'no signal');
      const again = await ProfileSettingsService.clearAllData();
      AgcPairingClient.unpairFailure = null;
      expect(again.ok).assertTrue();
      expect(AgcPairingClient.calls).assertEqual(3);
      const still = debtOf(SettingsStore.getPendingCloudUnpair(), 'orphan-session');
      expect(still == null ? '' : still.pairId).assertEqual('orphan-session');
      expect(still == null ? '' : still.uid).assertEqual('uid-of-the-orphan');

      await SettingsStore.clearPendingCloudUnpair();
    });

    /**
     * 「欠账 → 又配了一次 → 再清空」（批次 AO·AO2）。
     *
     * 旧写法只有一格 `pending_cloud_unpair`，而 `cloudUnpairTarget()` 在 pairId 非空时优先取**新的**那一个，
     * 于是链条走到第二次清空时：新会话写进同一格、旧的随 `clearAllSettings()` 一起没了——
     * 云上第一份密文当场变成谁都对不上号的孤儿行，界面上连提都不再提一句。
     * 现在它是一条按 pairId 记账的队列：两条都要敲、两条都没删动就两条都留着。
     */
    it('an_unpaid_debt_survives_a_new_pairing_and_a_second_wipe', 0, async () => {
      await emptyPlanTable();
      PlanCapabilities.bind(new CleanCalendar(), new OkReminder());
      await SettingsStore.clearPendingCloudUnpair();
      await SettingsStore.addPendingCloudUnpair('debt-from-the-first-wipe', 'uid-of-that-round', false);
      await SettingsStore.savePairId('second-session');
      await SettingsStore.setPairState(PAIRED, 'peer-uid');
      AgcPairingClient.calls = 0;
      AgcPairingClient.unpairFailure = new CloudApiError(CLOUD_NETWORK, true, 'no signal');

      const wiped = await ProfileSettingsService.clearAllData();
      AgcPairingClient.unpairFailure = null;

      expect(wiped.ok).assertTrue();
      const debt = SettingsStore.getPendingCloudUnpair();
      expect(debt.length).assertEqual(2);
      // 旧欠账的 uid 原样带过去：那是**那一轮**的成员，本机新生成的 uid 不是
      const first = debtOf(debt, 'debt-from-the-first-wipe');
      expect(first == null ? '' : first.uid).assertEqual('uid-of-that-round');
      expect(first == null ? true : first.dead).assertFalse();
      // 新会话这一条用的是清库之前的本机 uid（`clearAllSettings()` 会把 `device_uid` 一起推平）
      const second = debtOf(debt, 'second-session');
      expect(second == null ? '' : second.pairId).assertEqual('second-session');
      expect(second == null ? true : second.dead).assertFalse();
      expect(wiped.message.indexOf('云上那 2 份加密快照还没删掉') >= 0).assertTrue();

      if (!CLOUD_ON) {
        // 关闭态：一条都不发，但两条都记下来（AO1 与 AO2 在同一格里叠加）
        expect(AgcPairingClient.calls).assertEqual(0);
        expect(wiped.message.indexOf('（云端功能目前没开通）') >= 0).assertTrue();
        await SettingsStore.clearPendingCloudUnpair();
        return;
      }
      expect(AgcPairingClient.calls).assertEqual(2);

      // 网络通了以后，一次回前台就把两条一起带走
      await ProfileSettingsService.retryPendingCloudUnpair();
      expect(AgcPairingClient.calls).assertEqual(4);
      expect(SettingsStore.getPendingCloudUnpair().length).assertEqual(0);

      // 只有其中一条被云端判死：它退出补删队列、留着报数，另一条删得动就照删（AO3 在多条形状下仍成立）
      AgcPairingClient.calls = 0;
      AgcPairingClient.unpairFailure = new CloudApiError('FORBIDDEN', false, 'not a member');
      await SettingsStore.addPendingCloudUnpair('doomed', 'uid-a', false);
      await ProfileSettingsService.retryPendingCloudUnpair();
      AgcPairingClient.unpairFailure = null;
      expect(AgcPairingClient.calls).assertEqual(1);
      expect(ProfileSettingsService.undeletableCloudSnapshots()).assertEqual(1);

      // 判死的那一行不再进补删队列：第二次回前台一句都不敲（免费档按天配额是项目级共享的）
      AgcPairingClient.calls = 0;
      await ProfileSettingsService.retryPendingCloudUnpair();
      expect(AgcPairingClient.calls).assertEqual(0);
      expect(ProfileSettingsService.undeletableCloudSnapshots()).assertEqual(1);

      // 同一条队列里"还值得再敲"的那一笔不许被 dead 挡住，也不许被一起带走
      await SettingsStore.addPendingCloudUnpair('owing', 'uid-b', false);
      await ProfileSettingsService.retryPendingCloudUnpair();
      expect(AgcPairingClient.calls).assertEqual(1);
      const mixed = SettingsStore.getPendingCloudUnpair();
      expect(mixed.length).assertEqual(1);
      expect(mixed[0].pairId).assertEqual('doomed');
      expect(mixed[0].dead).assertTrue();
      expect(ProfileSettingsService.undeletableCloudSnapshots()).assertEqual(1);

      await SettingsStore.clearPendingCloudUnpair();
    });

    /**
     * 共享等级的"假读数"（批次 AO·AO4）。
     *
     * 旧写法有三处各自的猜法：引擎直取（未初始化时是 NaN）、「我的」页 `catch → 2`、页面初值写死 2，
     * 而库里存的可能是 L3——把用户的隐私档位**念小**，还让它看上去像用户自己选过。
     * 现在三个读取口并成一句 `ShareLevelReader.read()`：读不出来就是 `SHARE_LEVEL_UNKNOWN`，
     * 并且这一格不许当设置存下去——占位值一旦落库，下一次推快照会真按它降维，界面再也看不出破绽。
     *
     * 三格分别对应三种真实成因：**初始化竞态**（设备侧 `SettingsStore.p()` 在 Preferences init 之前抛错）、
     * **损坏值**（脏串／0／越界）、**冷启动的正常值**（L1 与 L3 各自念自己那一档，谁也不压成谁）。
     * 档位那句占位话术在 `MeView`，它不参与离线转译，所以这里钉的是它的**数据来源**。
     */
    it('unreadable_share_level_is_unknown_and_never_stored', 0, async () => {
      await SettingsStore.clearPendingCloudUnpair();
      SettingsStore.shareLevelFailure = null;

      // ① 初始化竞态：库里明明有值（L3），但读不出来时不许替它猜一个
      await SettingsStore.setShareLevelRaw(3);
      SettingsStore.shareLevelFailure = new Error('SettingsStore not initialized');
      expect(ProfileSettingsService.getShareLevel()).assertEqual(SHARE_LEVEL_UNKNOWN);
      const placeholder = await ProfileSettingsService.setShareLevel(SHARE_LEVEL_UNKNOWN);
      expect(placeholder.ok).assertFalse();
      expect(placeholder.message).assertEqual('共享等级没认出来，先不保存');
      // 竞态过去之后，读到的是库里那一个，而不是刚才那一格的猜测
      SettingsStore.shareLevelFailure = null;
      expect(ProfileSettingsService.getShareLevel()).assertEqual(3);

      // ② 损坏值：脏串、0、越界一律「未知」，不就近折成一档
      await SettingsStore.setShareLevelRaw('dirty');
      expect(ProfileSettingsService.getShareLevel()).assertEqual(SHARE_LEVEL_UNKNOWN);
      await SettingsStore.setShareLevelRaw(0);
      expect(ProfileSettingsService.getShareLevel()).assertEqual(SHARE_LEVEL_UNKNOWN);
      await SettingsStore.setShareLevelRaw(9);
      expect(ProfileSettingsService.getShareLevel()).assertEqual(SHARE_LEVEL_UNKNOWN);
      const tooBig = await ProfileSettingsService.setShareLevel(9);
      expect(tooBig.ok).assertFalse();
      expect(tooBig.message).assertEqual('共享等级没认出来，先不保存');

      // ③ 冷启动的正常值：L1／L3 各念各的，写侧读侧同一口径
      await SettingsStore.setShareLevelRaw(1);
      expect(ProfileSettingsService.getShareLevel()).assertEqual(1);
      await SettingsStore.setShareLevelRaw(3);
      expect(ProfileSettingsService.getShareLevel()).assertEqual(3);
      const saved = await ProfileSettingsService.setShareLevel(2);
      expect(saved.ok).assertTrue();
      expect(ProfileSettingsService.getShareLevel()).assertEqual(2);

      SettingsStore.shareLevelFailure = null;
      await SettingsStore.setShareLevelRaw(2);
    });

    /**
     * 心跳游标的两条命（批次 AO·AO5）。
     *
     * ① `forgetPair()` 现在把游标一起归零（上一格用例已断言清零），所以新配对的第一跳不该空等一周；
     * ② 旧会话那一跳的**迟到返回值**不许写下新会话的游标。`beat()` 里"取 uid → 发请求 → 落游标"是
     *    一条 await 链，中间用户完全可能解绑并配上另一个人；无条件写 `now` 会把新会话的游标推到
     *    一周之后，而那一周里页面说的全是这一轮的事。
     * 桩里的 `heartbeatHold` 就是为了这一格：桩若即时 resolve，那次同一性复核永远走在
     * "还是同一个 pair"那一支，断言就成了摆设。
     */
    it('a_late_heartbeat_never_moves_the_new_pair_cursor', 0, async () => {
      await SettingsStore.savePairId('old-session');
      await SettingsStore.setPairState(PAIRED, 'old-partner');
      await SettingsStore.setLastHeartbeatAt(0);
      AgcPairingClient.calls = 0;
      AgcPairingClient.heartbeatHold = null;

      if (!CLOUD_ON) {
        // 守卫是 beatIfDue 的第一句，所以这里同步断言：连 uid 都没去取，谈不上发请求
        ProfileSettingsService.beatIfDue();
        expect(AgcPairingClient.calls).assertEqual(0);
        expect(SettingsStore.getLastHeartbeatAt()).assertEqual(0);
        return;
      }

      let release: (v?: void) => void = () => {
      };
      AgcPairingClient.heartbeatHold = new Promise<void>((resolve: (v?: void) => void) => {
        release = resolve;
      });

      ProfileSettingsService.beatIfDue();
      await letItSettle();
      // 请求已经发出去、还挂在半路：这一拍游标本来就不该有值（失败不落游标是既有口径）
      expect(AgcPairingClient.calls).assertEqual(1);
      expect(SettingsStore.getLastHeartbeatAt()).assertEqual(0);

      // 就在这一趟往返还没回来时，本机解了绑又配上了另一个人（游标随解绑归零）
      await SettingsStore.savePairId('new-session');
      await SettingsStore.setLastHeartbeatAt(0);

      release();
      await letItSettle();
      // 迟到那一跳被丢弃：新会话仍然处于"从未心跳过"，而不是被旧会话替它记了一笔
      expect(AgcPairingClient.calls).assertEqual(1);
      expect(SettingsStore.getLastHeartbeatAt()).assertEqual(0);
      AgcPairingClient.heartbeatHold = null;

      // 新会话的第一跳照发——这才是"没有空等一周"
      ProfileSettingsService.beatIfDue();
      await letItSettle();
      expect(AgcPairingClient.calls).assertEqual(2);
      expect(SettingsStore.getLastHeartbeatAt() > 0).assertTrue();

      await SettingsStore.savePairId('');
      await SettingsStore.setPairState(PAIR_NONE, '');
      await SettingsStore.setLastHeartbeatAt(0);
    });
  });
}
