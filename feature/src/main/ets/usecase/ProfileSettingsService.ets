import { EngineParams, defaultParams, hhmmToMin, minToHHmm } from 'domain';
import {
  PAIRED, PAIR_NONE, PAIR_PENDING, PAIR_WAITING, PartnerProfile, ScheduleRepo, SettingsStore
} from 'data';
import {
  AgcPairingClient, CLOUD_LOCAL, CLOUD_NETWORK, CloudApiError, newRequestId, PairKeyStore, PairSession
} from 'cloud';
import { Logger } from 'commons';
import { FeatureFlags } from '../config/FeatureFlags';
import { ScheduleUseCase } from './ScheduleUseCase';
import { PlanProjectionCleanupService } from './PlanProjectionCleanupService';
import {
  addCleanupReport, clearAllMessageOf, emptyCleanupReport
} from '../model/PlanFlow';
import { horizonError, isCrossMidnight, rhythmError, toMinutes } from '../model/RhythmRules';
import { decodeSyncState, SYNC_STATE_OK, SyncState } from '../model/CloudSyncRules';

const TAG = 'ProfileSettingsService';

/**
 * 心跳节流窗口（协议 §4.6）：7 天。闲置回收线是 6 个月，取一周既留了 25 倍的余量，
 * 又把免费档的调用量压在一个 pair ≈ 52 次/年 —— 配额花在配对上，不花在续命上。
 */
const HEARTBEAT_WEEK_MS = 7 * 24 * 60 * 60 * 1000;

/** 一次设置写入的结果：message 已是可以直接 toast 的中文，页面不再自己拼错误码。 */
export interface SettingsResult {
  ok: boolean;
  message: string;
}

/** 邀请码结果：成功后页面要展示 6 位码，失败时只有提示语。 */
export interface InviteResult {
  ok: boolean;
  message: string;
  code: string;
}

/** 作息输入（原文传入，解析与校验统一在这一层，离线单测直接打这里）。 */
export interface RhythmInput {
  wakeText: string;
  bedText: string;
  windText: string;
}

/** 伴侣档案＝作息 + 昵称。 */
export interface PartnerInput extends RhythmInput {
  nick: string;
}

/** 「我的」页作息卡读模型：编辑态由页面持有，这里只给保存值与跨零点说明。 */
export interface MyRhythm extends RhythmInput {
  horizonText: string;
  minSlotMin: number;
}

function ok(message: string): SettingsResult {
  const r: SettingsResult = { ok: true, message: message };
  return r;
}

function fail(message: string): SettingsResult {
  const r: SettingsResult = { ok: false, message: message };
  return r;
}

/**
 * 「我的」页的写入编排：作息、伴侣档案（本机代录）、隐私等级、云端配对、清空数据。
 * 页面只管输入态与结果提示，SettingsStore / ScheduleRepo / 云函数调用都不再出现在 UI 层。
 */
export class ProfileSettingsService {
  // ---------- 我的作息参数（校验口径见 model/RhythmRules） ----------

  /** 读取当前保存值；设置未初始化时回退到引擎默认，页面不需要再兜异常。 */
  static loadMyRhythm(): MyRhythm {
    const d = defaultParams();
    let p: EngineParams = d;
    try {
      p = SettingsStore.getParams();
    } catch (e) {
      p = d;
    }
    const r: MyRhythm = {
      wakeText: minToHHmm(p.wakeMin), bedText: minToHHmm(p.bedMin), windText: '' + p.windDownMin,
      horizonText: '' + p.horizonDays, minSlotMin: p.minSlotMin
    };
    return r;
  }

  static async saveMyRhythm(input: MyRhythm): Promise<SettingsResult> {
    const err = rhythmError(input.wakeText, input.bedText, input.windText);
    if (err !== '') {
      return fail(err);
    }
    const hErr = horizonError(input.horizonText);
    if (hErr !== '') {
      return fail(hErr);
    }
    const horizon = toMinutes(input.horizonText);
    let p: EngineParams;
    try {
      p = SettingsStore.getParams();
    } catch (e) {
      return fail('设置还没读出来，稍后再试');
    }
    p.wakeMin = hhmmToMin(input.wakeText);
    p.bedMin = hhmmToMin(input.bedText);
    p.windDownMin = toMinutes(input.windText);
    p.horizonDays = horizon;
    p.minSlotMin = input.minSlotMin;
    try {
      await SettingsStore.setParams(p);
      await ScheduleUseCase.onScheduleChanged();
    } catch (e) {
      return fail('保存失败：' + (e as Error).message);
    }
    return ok('已保存，共同时间重新算好了');
  }

  // ---------- 伴侣档案（本机代录） ----------

  /** 有档案即代表这台手机在替 TA 记录；快照同步不写档案，故不会误判。 */
  static loadPartner(): PartnerInput | null {
    let profile: PartnerProfile | null = null;
    try {
      profile = SettingsStore.getPartnerProfile();
    } catch (e) {
      profile = null;
    }
    if (profile == null) {
      return null;
    }
    const r: PartnerInput = {
      nick: profile.nick, wakeText: minToHHmm(profile.wakeMin),
      bedText: minToHHmm(profile.bedMin), windText: '' + profile.windDownMin
    };
    return r;
  }

  static async savePartner(input: PartnerInput): Promise<SettingsResult> {
    const nick = input.nick.trim();
    if (nick === '') {
      return fail('先填 TA 的昵称');
    }
    const err = rhythmError(input.wakeText, input.bedText, input.windText);
    if (err !== '') {
      return fail(err);
    }
    const profile: PartnerProfile = {
      nick: nick, wakeMin: hhmmToMin(input.wakeText),
      bedMin: hhmmToMin(input.bedText), windDownMin: toMinutes(input.windText)
    };
    try {
      await SettingsStore.savePartnerProfile(profile);
      await ScheduleUseCase.onScheduleChanged();
    } catch (e) {
      return fail('保存失败：' + (e as Error).message);
    }
    return ok('TA 的作息已保存，共同时间重新算好了');
  }

  /** 删除档案同时清掉本机代录的 TA 班表，回退单人模式。 */
  static async deletePartner(): Promise<SettingsResult> {
    try {
      await SettingsStore.clearPartnerProfile();
      await ScheduleRepo.deletePartnerData();
      await ScheduleUseCase.onScheduleChanged();
    } catch (e) {
      return fail('删除失败：' + (e as Error).message);
    }
    return ok('已删除 TA 的数据，回到单人模式');
  }

  // ---------- 隐私共享等级 ----------

  static getShareLevel(): number {
    try {
      return SettingsStore.getShareLevel();
    } catch (e) {
      return 2;
    }
  }

  /** 等级参与快照生成，切换后连同班表一起重算推送。 */
  static async setShareLevel(level: number): Promise<SettingsResult> {
    try {
      await SettingsStore.setShareLevel(level);
      await ScheduleUseCase.onScheduleChanged();
    } catch (e) {
      return fail('保存失败：' + (e as Error).message);
    }
    return ok('共享等级已保存');
  }

  // ---------- 云端配对（协议 v1 §8：UNPAIRED ─create→ WAITING ─join→ PENDING_CONFIRM ─confirm→ ACTIVE） ----------

  /**
   * 配对相关的写动作共用这一句判断，且必须在**任何**副作用之前：
   * 不生成/读回 uid、不在 HUKS 建身份密钥、不发云对象、不写 pairId/配对态。
   *
   * 为什么不能靠"AGC 未配置所以调用必然抛错"来保证：换机、复用证书或误关联云工程之后，
   * 成功分支就会把 pairId 与配对态写进本机（验收报告 B1）。这条路径另有一重结构保险——
   * 长期密钥的写入 API 已经不存在了，密钥只在 HUKS 别名里，翻开关也复现不出"短码派生密钥存 Preferences"。
   */
  private static cloudBlocked(): boolean {
    return !FeatureFlags.cloudPairing;
  }

  static getPairState(): string {
    try {
      return SettingsStore.getPairState();
    } catch (e) {
      return PAIR_NONE;
    }
  }

  /**
   * 云同步三态（协议 §3.4 末行）：「我的 · 伴侣与同步」的提示条与「今天还排不排得动推送」共用的读入口。
   * 偏好没就绪或串是脏值都回「已同步」= 提示条不出——假警报比漏报更贵，见 `decodeSyncState`。
   */
  static getCloudSyncState(): SyncState {
    try {
      return decodeSyncState(SettingsStore.getCloudSyncState());
    } catch (e) {
      const clean: SyncState = { outcome: SYNC_STATE_OK, day: 0, code: '' };
      return clean;
    }
  }

  /**
   * 加入方拿到的一次性确认凭据，等 TA 把它交回发起方（分享/二维码）。
   * 只活在进程内存：落 Preferences 就违反"一次性凭据不持久化"（门禁 §4 第 3 条），
   * 而宿主必须是比页面长寿的静态位，否则用户切个 Tab 回来就分享不出去了。
   */
  private static outboundToken: string = '';

  /** 页面组分享链接用（`PairLink.build(token, 0)`）；空串就是还没有可分享的东西。 */
  static getOutboundToken(): string {
    return ProfileSettingsService.outboundToken;
  }

  /**
   * 云端失败的统一说法（协议 §3.4 收敛成 UI 能直接念的一句）。
   * 语义码之外的异常一律按"暂时不可用"，不把 stack 抛给用户。
   */
  private static degradedMessage(e: Object): string {
    const err = e as CloudApiError;
    const semantic = err.name === 'CloudApiError' ? err.semantic : '';
    if (semantic === CLOUD_LOCAL) {
      return FeatureFlags.cloudClosedMessage;
    }
    if (semantic === CLOUD_NETWORK) {
      return '连不上网络，稍后再试';
    }
    if (semantic === 'CODE_EXPIRED' || semantic === 'CODE_TAKEN') {
      return '配对码失效或已经被用过，让 TA 重新生成一个';
    }
    if (semantic === 'UNAUTHORIZED' || semantic === 'FORBIDDEN' || semantic === 'NOT_FOUND') {
      return '这次配对已经失效，重新配对一次就行；本机数据不受影响';
    }
    if (semantic === 'QUOTA_EXHAUSTED') {
      return '今天的同步次数用完了，明天自动恢复';
    }
    if (semantic === 'SCHEMA_UNSUPPORTED') {
      return '云端版本和手机上的应用对不上，更新后再试';
    }
    return '配对服务暂时用不了，请稍后再试';
  }

  /**
   * 生成邀请码（发起方）：HUKS 身份密钥 → pairing-create（带公钥）→ 存 pairId → WAITING。
   * 关闭态一条请求都不发、一个别名都不建。
   */
  static async createInvite(): Promise<InviteResult> {
    if (ProfileSettingsService.cloudBlocked()) {
      const blocked: InviteResult = { ok: false, code: '', message: FeatureFlags.cloudClosedMessage };
      return blocked;
    }
    try {
      const uid = await SettingsStore.getOrCreateUid();
      const publicKey = await PairKeyStore.ensureIdentity(uid);
      const session: PairSession = await new AgcPairingClient().createPairing(uid, publicKey);
      await SettingsStore.savePairId(session.pairId);
      await SettingsStore.setPairState(PAIR_WAITING, '');
      ProfileSettingsService.outboundToken = '';
      const r: InviteResult = { ok: true, message: '配对码已生成，发给 TA 吧', code: session.code };
      return r;
    } catch (e) {
      Logger.warn(TAG, 'createPairing degraded: ' + (e as Error).message);
      const r: InviteResult = { ok: false, code: '', message: ProfileSettingsService.degradedMessage(e) };
      return r;
    }
  }

  /**
   * 输码加入（加入方）：pairing-join → **就地完成 ECDH 协商** → 存 pairId → PENDING_CONFIRM。
   *
   * 加入后不得立即视为已配对，也不得推任何快照（协议 §4.2）：本机停在 PENDING_CONFIRM，
   * 直到发起方带着这条 confirmToken 走完 §4.3。token 交回发起方靠分享/扫码，本应用不代发。
   */
  static async joinByCode(codeText: string): Promise<SettingsResult> {
    if (ProfileSettingsService.cloudBlocked()) {
      return fail(FeatureFlags.cloudClosedMessage);
    }
    const code = codeText.trim();
    if (code.length !== 6 || Number.isNaN(Number(code))) {
      return fail('请输入对方分享的 6 位配对码');
    }
    try {
      const uid = await SettingsStore.getOrCreateUid();
      const publicKey = await PairKeyStore.ensureIdentity(uid);
      const session: PairSession = await new AgcPairingClient().joinPairing(code, uid, publicKey);
      // 协商失败就是没有钥匙：宁可不写 pairId，也不留下一个"显示已配对但永远同步不动"的态
      if (session.peerPublicKey === '') {
        return fail('TA 那边还没准备好，让 TA 重新生成配对码');
      }
      await PairKeyStore.agreeKey(uid, session.pairId, session.peerPublicKey);
      await SettingsStore.savePairId(session.pairId);
      await SettingsStore.setPairState(PAIR_PENDING, session.peerUid);
      ProfileSettingsService.outboundToken = session.confirmToken;
    } catch (e) {
      Logger.warn(TAG, 'joinPairing degraded: ' + (e as Error).message);
      return fail(ProfileSettingsService.degradedMessage(e));
    }
    if (ProfileSettingsService.outboundToken === '') {
      return ok('已加入，但这次没拿到确认用的链接：让 TA 用配对码重新发起一次');
    }
    return ok('已加入，把配对链接发给 TA，TA 确认后才开始同步');
  }

  /**
   * 发起方确认（协议 §4.3）：只有在云端真的把会话转成 ACTIVE 之后才写 PAIRED。
   * 协商双方各算一次：发起方在这里用加入方的公钥算出与对方同一个密钥。
   */
  static async confirmWithToken(confirmToken: string): Promise<SettingsResult> {
    if (ProfileSettingsService.cloudBlocked()) {
      return fail(FeatureFlags.cloudClosedMessage);
    }
    const pairId = SettingsStore.getPairId();
    if (pairId === '' || confirmToken === '') {
      return fail('现在没有要确认的配对');
    }
    try {
      const uid = await SettingsStore.getOrCreateUid();
      const session: PairSession = await new AgcPairingClient().confirmPairing(pairId, uid, confirmToken);
      if (session.status !== 'ACTIVE') {
        return fail('云端还没确认这次配对，稍后再试');
      }
      if (session.peerPublicKey === '') {
        return fail('TA 那边还没准备好，重新配对一次');
      }
      await PairKeyStore.agreeKey(uid, pairId, session.peerPublicKey);
      await SettingsStore.setPairState(PAIRED, session.peerUid);
      ProfileSettingsService.outboundToken = '';
      ScheduleUseCase.onScheduleChanged().catch(() => {
      });
      return ok('配对完成，班表会按你选的等级加密同步');
    } catch (e) {
      Logger.warn(TAG, 'confirmPairing degraded: ' + (e as Error).message);
      return fail(ProfileSettingsService.degradedMessage(e));
    }
  }

  /**
   * 「检查配对状态」：只做**对账**，不再直接置 PAIRED。
   *
   * 旧名 `markPaired` 那条是协议 §8 明令修掉的偏离——本地写 PAIRED 而云端仍是 WAITING，界面上就是"正在同步"那句谎。
   * 以 pairing-status 为准：云端 ACTIVE 才转 PAIRED（并补上缺席的协商），其余状态照实回落本机配对态。
   */
  static async reconcilePair(): Promise<SettingsResult> {
    if (ProfileSettingsService.cloudBlocked()) {
      return fail(FeatureFlags.cloudClosedMessage);
    }
    const pairId = SettingsStore.getPairId();
    if (pairId === '') {
      return fail('还没有生成配对码，先生成一个');
    }
    try {
      const uid = await SettingsStore.getOrCreateUid();
      const session: PairSession = await new AgcPairingClient().pairStatus(pairId, uid);
      if (session.status === 'ACTIVE') {
        if (!await PairKeyStore.hasPairKey(pairId)) {
          if (session.peerPublicKey === '') {
            return fail('TA 那边还没准备好，重新配对一次');
          }
          await PairKeyStore.agreeKey(uid, pairId, session.peerPublicKey);
        }
        await SettingsStore.setPairState(PAIRED, session.peerUid);
        ScheduleUseCase.onScheduleChanged().catch(() => {
        });
        return ok('已经连上云端，班表会按你选的等级加密同步');
      }
      if (session.status === 'PENDING_CONFIRM') {
        await SettingsStore.setPairState(PAIR_PENDING, session.peerUid);
        return ok('还在等 TA 确认：把配对链接发给 TA，确认后自动开始同步');
      }
      // WAITING / EXPIRED / REVOKED / 未知：本机跟着回落，不替云端谎报进度
      await SettingsStore.setPairState(session.status === 'WAITING' ? PAIR_WAITING : PAIR_NONE, '');
      return fail(session.status === 'WAITING' ? '对方还没有输入配对码' : '这次配对已经失效，重新配对一次');
    } catch (e) {
      Logger.warn(TAG, 'pairStatus degraded: ' + (e as Error).message);
      return fail(ProfileSettingsService.degradedMessage(e));
    }
  }

  /** 取消等待中的配对：只清配对标记与别名，不动本机代录数据。 */
  static async cancelWaiting(): Promise<void> {
    try {
      await ProfileSettingsService.forgetPair();
    } catch (e) {
      Logger.warn(TAG, 'cancelWaiting degraded: ' + (e as Error).message);
    }
  }

  /**
   * 本机配对痕迹的一次性清理：pairId、对方快照游标、最后一次有效快照信封、云同步三态、
   * HUKS 协商别名、内存里的确认凭据。
   * 身份别名（`crd-id-<uid>`）留着——它是这台设备的长期身份，下一轮配对还要用同一把公钥。
   *
   * 三态必须跟着清：「已降级」的语义是"排不动推送，直到某次拉成功"，留着它，
   * 下一轮配对从第一版快照起就静默不推——而界面上那条提示说的是上一个配对的事。
   *
   * 信封也必须跟着清：HUKS 别名一删，这份密文就永久解不开了——留着它只是让上一轮配对的
   * 字节一直躺在键值文件里，而读侧那道 pairId 比对是兜底，不是留着它的理由。
   */
  private static async forgetPair(): Promise<void> {
    ScheduleUseCase.cancelMergedSync();
    await PairKeyStore.dropPairKey(SettingsStore.getPairId());
    await SettingsStore.savePairId('');
    await SettingsStore.clearPairKey();
    await SettingsStore.setPartnerSnapVer(0);
    await SettingsStore.clearPartnerSnapCache();
    await SettingsStore.setCloudSyncState('');
    await SettingsStore.setPairState(PAIR_NONE, '');
    ProfileSettingsService.outboundToken = '';
  }

  /**
   * 解除配对：云侧级联删快照 + 本机配对标记/协商密钥/对方快照游标一律清干净。
   *
   * 注意这条**不受关闭态拒绝**：上一版原型可能在本机留下 PAIRED 与残留密钥，而云入口已经藏起来了，
   * 用户必须还能亲手撤掉这些标记，否则界面会一直挂着"已配对"。「开关只关能力，不关数据」。
   */
  static async unpair(): Promise<SettingsResult> {
    try {
      if (FeatureFlags.cloudPairing) {
        try {
          await new AgcPairingClient().unpair(SettingsStore.getPairId(),
            await SettingsStore.getOrCreateUid(), newRequestId());
        } catch (e) {
          Logger.warn(TAG, 'unpair cloud degraded: ' + (e as Error).message);
        }
      }
      await ProfileSettingsService.forgetPair();
    } catch (e) {
      return fail('操作失败：' + (e as Error).message);
    }
    ScheduleUseCase.onScheduleChanged().catch(() => {
    });
    return ok('已解除配对');
  }

  /**
   * 「该不该跳一次心跳」的纯判断（与发请求分开，是为了让这一格能离线断言：设备侧改不了系统钟，
   * `hdc shell` 无 root、`date -s` 回 Operation not permitted，于是"隔一周"这类按时间的分支
   * 在真机上属于撞运气，权威覆盖只能落在这里——同 D-39 的 `greetingOf` 口径）。
   *
   * 三条到期情形合成一句：从未心跳过、窗口走满、系统时间被往回拨过。最后一条反过来判为"到期"
   * 而不是"未到期"——宁可多打一次，也不要用户改一次时钟就永久停跳，让 6 个月的回收线裸奔。
   */
  static heartbeatDue(pairId: string, lastBeatAt: number, now: number): boolean {
    if (pairId === '') {
      return false;
    }
    // 偏好里若是脏值，Number() 给出 NaN，而 `NaN > 0` 为假 —— 于是脏值也落在"从未心跳过"这一支
    if (!(lastBeatAt > 0)) {
      return true;
    }
    const elapsed = now - lastBeatAt;
    return elapsed < 0 || elapsed >= HEARTBEAT_WEEK_MS;
  }

  /**
   * 心跳（协议 §4.6）：AGC 的闲置回收是**项目级**判定（连续 6 个月无有效调用 → 预警 30 日后回收），
   * 这条端点的作用是把"还有人在用配对功能"这件事，用最小代价、与业务解耦地说给云侧听。
   *
   * 只由回前台顺路带起，**不建常驻、不起定时器**（协议 §3.3 与 §7 都禁后台常驻）——
   * 所以 `HEARTBEAT_WEEK_MS` 是"两次心跳的最小间隔"，不是闹钟：整机不用应用，心跳就停，
   * 而回收线在 6 个月外，中间隔着 25 倍余量。
   *
   * 两条形同拒绝的前置：关闭态一次都不发（B1 的 `AgcPairingClient.calls === 0` 断言管的就是这里）；
   * 从未配对（`pairId` 为空）也不发——本机没有云端数据要护着，就不该替整个项目开一次云调用。
   * 这一句与 `ScheduleUseCase.scheduleMergedSync` 的 `pairState === PAIRED` 口径**故意不同**：
   * 那边管的是"该不该动对方的数据"，这边只看"本机手里有没有一个 pairId 指向的云端记录"，
   * 停在 WAITING/PENDING 的会话行同样占着库，一跳都不亏。
   *
   * fire-and-forget 且失败不排重试：漏一跳的代价是下次回前台补上，重试风暴的代价是把当天的
   * 配额吃光，反过来把真正的快照同步挤成 `QUOTA_EXHAUSTED`。
   */
  static beatIfDue(): void {
    if (ProfileSettingsService.cloudBlocked()) {
      return;
    }
    let pairId = '';
    let lastBeatAt = 0;
    try {
      pairId = SettingsStore.getPairId();
      lastBeatAt = SettingsStore.getLastHeartbeatAt();
    } catch (e) {
      // Preferences 尚未初始化：这一趟回前台不心跳，下一次还有机会
      return;
    }
    const now = Date.now();
    if (!ProfileSettingsService.heartbeatDue(pairId, lastBeatAt, now)) {
      return;
    }
    ProfileSettingsService.beat(pairId, now);
  }

  /**
   * 发一次心跳。拆成私有方法只为让上面那段判断保持同步返回：启动链上没有人该为一个心跳 await。
   * 记的是**发起前**取的本机钟（不是服务端回的 serverTime）：节流比的是同一只钟的两端，
   * 混进服务端时刻会让一次网络往返的偏差也算进间隔里。失败不落游标，于是下次回前台还能补。
   */
  private static beat(pairId: string, now: number): void {
    SettingsStore.getOrCreateUid()
      .then((uid: string) => new AgcPairingClient().heartbeat(uid, pairId))
      .then(() => SettingsStore.setLastHeartbeatAt(now))
      .catch((e: Error) => {
        Logger.warn(TAG, 'heartbeat degraded: ' + e.message);
      });
  }

  // ---------- 清空数据 ----------

  /**
   * 清空 8 张 RDB 表 + 全部设置；隐私同意标记保留，避免重启后重复弹窗。
   *
   * 清库之前先把系统侧的东西一起带走（验收报告 B2）：计划级的系统日历日程，以及（升级前遗留的）
   * 计划级提醒句柄，再整本清掉应用专属「同休日」日历作兜底（句柄丢了的那些日程也一并删掉）。
   * "清空我的全部数据"这句话若只管本机表，用户删掉的只是自己看得见的那份，
   * 日程和提醒还留在系统里——所以清不干净的部分必须报数，不能回一句"已清空"。
   */
  static async clearAllData(): Promise<SettingsResult> {
    const report = emptyCleanupReport();
    let calendarPurged = true;
    try {
      // 逐条计划：删日程 + 撤提醒（含 CANCELLED 但没删动的残留行）
      const rows = await ScheduleRepo.listPlansCarryingHandles();
      addCleanupReport(report, await PlanProjectionCleanupService.cleanupPlanList(rows));
      calendarPurged = await PlanProjectionCleanupService.purgeManagedCalendar();
    } catch (e) {
      // 系统侧清不动也要把本机表清掉：数据在用户设备上，本机那份是能立刻收回的
      Logger.warn(TAG, 'clearAllData projection cleanup degraded: ' + (e as Error).message);
      calendarPurged = false;
    }
    try {
      const privacyWas = SettingsStore.isPrivacyAccepted();
      // 协商密钥要跟着一起毁：pairId 随 Preferences 清掉之后，HUKS 里那把别名就成了没人认领的钥匙
      await PairKeyStore.dropPairKey(SettingsStore.getPairId());
      await ScheduleRepo.clearAllData();
      await SettingsStore.clearAllSettings();
      if (privacyWas) {
        await SettingsStore.acceptPrivacy();
      }
      await ScheduleUseCase.onScheduleChanged();
    } catch (e) {
      return fail('清空失败：' + (e as Error).message);
    }
    return ok(clearAllMessageOf(report, calendarPurged));
  }
}
