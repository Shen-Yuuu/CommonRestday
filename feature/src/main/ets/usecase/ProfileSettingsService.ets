import { EngineParams, defaultParams, hhmmToMin, minToHHmm, PendingCloudUnpair } from 'domain';
import {
  PAIRED, PAIR_NONE, PAIR_PENDING, PAIR_WAITING, PartnerProfile,
  ScheduleRepo, SettingsStore
} from 'data';
import {
  AgcPairingClient, CLOUD_LOCAL, CLOUD_NETWORK, CloudApiError, newRequestId, PairKeyStore, PairSession
} from 'cloud';
import { Logger } from 'commons';
import { FeatureFlags } from '../config/FeatureFlags';
import { ScheduleUseCase } from './ScheduleUseCase';
import { ShareLevelReader } from './ShareLevelReader';
import { PlanProjectionCleanupService } from './PlanProjectionCleanupService';
import {
  addCleanupReport, clearAllMessageOf, emptyCleanupReport
} from '../model/PlanFlow';
import { horizonError, horizonFromStore, isCrossMidnight, rhythmError, toMinutes } from '../model/RhythmRules';
import {
  decodeSyncState, shareLevelFromStore, SHARE_LEVEL_UNKNOWN, SYNC_STATE_OK, SyncState
} from '../model/CloudSyncRules';

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

/** 一次云侧删除的结论：`removed` 是"云上那两行不用再管了"，`retryLater` 是"还值不值得再敲一次门"。 */
interface CloudUnpairOutcome {
  removed: boolean;
  message: string;
  retryLater: boolean;
}

/** 本机手里那份"该删的云端配对"。`uid` 为空表示要用本机当前 uid 填（活着的 pairId 走这一支）。 */
interface CloudUnpairTarget {
  pairId: string;
  uid: string;
}

/**
 * 一轮云侧删除的账（批次 AO 把它从"一次调用"扩成"一轮"，因为本机可能同时欠着两条：
 * 上一次清空没删掉的，和这一次正在解绑的）。
 *
 * `refusedMessage` 非空 = 解除配对那一档要**中止**（活着的 pairId 没删成，本机一行都不清），
 * 内容就是要回给用户的那句；清空那一档不看它，因为本机那一侧是用户的即时处置权。
 *
 * `kept` 是这一轮**没删掉**的那几笔（连同终局判定为 `dead` 的），交回调用方在清库之后落进偏好：
 * 清库之前落，它就是第一个被推平的；不落，这台设备就再也没有地方记得云上还有东西。
 */
interface CloudSweep {
  removed: number;
  waiting: number;
  dead: number;
  refusedMessage: string;
  switchClosed: boolean;
  kept: PendingCloudUnpair[];
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
 * 「云上还剩一份」那半句（批次 U·U5 起，批次 AO 扩到一轮账）。
 *
 * 三支话不同是故意的，每一支都只说它兑现得了的那部分：
 * - **还欠着、也还值得再敲**：敢说"下次打开应用会自动再试一次"，因为 `retryPendingCloudUnpair`
 *   真的挂在回前台链尾。开关关着时那一次不会发（守卫在第一句），所以话里要说清是"开通后"才试——
 *   不说清就是拿一个当下走不通的路径给用户承诺。
 * - **云端给了终局判定**（不是成员、参数不合法、版本对不上）：重跑一百次也是同一句，
 *   所以它退出补删队列、只留着报数，这一支不再留任何承诺。
 * 这与最终验收 R2 钉住的是同一条规矩——`clearAllMessageOf` 里不许出现"可稍后重试"，
 * 因为系统日历的投影句柄随计划行一起没了，那句话兑现不了。
 */
function cloudCleanupNote(s: CloudSweep): string {
  const parts: string[] = [];
  if (s.waiting > 0) {
    const which = s.waiting === 1 ? '云上那份加密快照' : '云上那 ' + s.waiting + ' 份加密快照';
    parts.push(s.switchClosed
      ? which + '还没删掉（云端功能目前没开通），开通后打开应用会自动再试一次'
      : which + '还没删掉，下次打开应用会自动再试一次');
  }
  if (s.dead > 0) {
    const which = s.dead === 1 ? '云上还剩一份加密快照' : '云上还剩 ' + s.dead + ' 份加密快照';
    parts.push(which + '这台手机删不掉（云端不认这个删除凭据），本机这一侧已经清干净了');
  }
  return parts.length === 0 ? '' : '；' + parts.join('；');
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
      // 回填的是引擎真正会展开的那个界，不是 Preferences 里那串字面量（D-59）：
      // 备份/换机带回 5000 时，输入框念 5000 而本页的 horizonError 只放行 7–366，
      // 用户连改起床时间都保存不了，除非先动那个自己从没填过的数。
      horizonText: '' + horizonFromStore(p.horizonDays), minSlotMin: p.minSlotMin
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

  /**
   * 页面读的那一格共享等级：只有"知"与"未知"两种结果，未知不许被折成任何一档（批次 AO·AO4）。
   *
   * 旧写法是 `catch → 2`：偏好未初始化时念 L2，而实际存的可能是 L3——把用户的隐私档位念小，
   * 还让它看上去像是用户自己选的。读数唯一口径在 `ShareLevelReader.read`（引擎那一侧同一句），
   * 这里只是把它转给视图，页面不再自己兜异常。
   */
  static getShareLevel(): number {
    return ShareLevelReader.read();
  }

  /** 云上还剩几份是这台手机删不掉的（终局判定那一族）：视图据此决定要不要在数据卡里报这一笔。 */
  static undeletableCloudSnapshots(): number {
    try {
      return SettingsStore.countDeadCloudUnpair();
    } catch (e) {
      return 0;
    }
  }

  /**
   * 等级参与快照生成，切换后连同班表一起重算推送。
   *
   * 写侧也要认档：只有 1/2/3 进得了库。「未知」是两个读取口都可能出现的一格，
   * 若让它顺着某个回写路径存下去，就等于替用户选了一个他没选过的隐私档位——
   * 那种事一旦落库，下一次推快照会真的按它降维，界面上再也看不出破绽。
   */
  static async setShareLevel(level: number): Promise<SettingsResult> {
    if (shareLevelFromStore(level) === SHARE_LEVEL_UNKNOWN) {
      return fail('共享等级没认出来，先不保存');
    }
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
      return fail('请输入 TA 分享的 6 位配对码');
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
      return fail(session.status === 'WAITING' ? 'TA 还没有输入配对码' : '这次配对已经失效，重新配对一次');
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
   * HUKS 协商别名、心跳游标、内存里的确认凭据。
   * 身份别名（`crd-id-<uid>`）留着——它是这台设备的长期身份，下一轮配对还要用同一把公钥。
   *
   * 三态必须跟着清：「已降级」的语义是"排不动推送，直到某次拉成功"，留着它，
   * 下一轮配对从第一版快照起就静默不推——而界面上那条提示说的是上一个配对的事。
   *
   * 信封也必须跟着清：HUKS 别名一删，这份密文就永久解不开了——留着它只是让上一轮配对的
   * 字节一直躺在键值文件里，而读侧那道 pairId 比对是兜底，不是留着它的理由。
   *
   * 心跳游标同一批清掉（批次 AO）：它是"这个 pair 上周跳过一次没有"的账，
   * 留着它，下一轮配对最多要空等一周才发出第一跳——而那一周里页面上说的是这一轮的事。
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
    await SettingsStore.setLastHeartbeatAt(0);
    ProfileSettingsService.outboundToken = '';
  }

  /**
   * 云侧那两行快照的一次删除尝试，把"删没删成"和"还值不值得再试"分开报回来。
   *
   * 分开的理由在免费档：`pairing` 的按天配额是项目级共享的，而"这台设备不是那个会话的成员"
   * 这类判定（`retryable = false`）重跑一百次也是同一句——留着凭据只会让每次回前台白敲一次门。
   * 认不出形态的异常按"可以再试"处理：宁可多敲一次，也不把一份还删得动的密文判成永久留存。
   */
  private static async cloudUnpair(pairId: string, uid: string): Promise<CloudUnpairOutcome> {
    try {
      await new AgcPairingClient().unpair(pairId, uid, newRequestId());
      const done: CloudUnpairOutcome = { removed: true, message: '', retryLater: false };
      return done;
    } catch (e) {
      const err = e as CloudApiError;
      const outcome: CloudUnpairOutcome = {
        removed: false,
        message: ProfileSettingsService.degradedMessage(e),
        retryLater: err.name === 'CloudApiError' ? err.retryable : true
      };
      return outcome;
    }
  }

  /**
   * 本机手里所有"该删而还没删掉"的云端配对：活着的 pairId 排第一，其次是没有终局判定的欠账，
   * 同一个 pairId 只留一条（欠账那条自带 uid，优先采用——清空会把 `device_uid` 一起推平）。
   *
   * 批次 AO 把"挑一个"改成"列一份"。旧写法在 pairId 非空时把欠账整个遮住，于是
   * 「清空没删动 → 又配了一次 → 再清空」这一条链会把第一条欠账永久丢掉——那等于把一份还删得动的
   * 密文判成孤儿行，而界面上连提都不再提一句。
   * `dead` 不进这一列：云端已经给了终局判定，重跑一百次也是同一句，它只报数不敲门。
   */
  private static cloudUnpairTargets(): CloudUnpairTarget[] {
    const list: CloudUnpairTarget[] = [];
    const pending = SettingsStore.getPendingCloudUnpair();
    for (let i = 0; i < pending.length; i++) {
      const p = pending[i];
      if (!p.dead && p.pairId !== '') {
        const t: CloudUnpairTarget = { pairId: p.pairId, uid: p.uid };
        list.push(t);
      }
    }
    const livePairId = SettingsStore.getPairId();
    if (livePairId === '') {
      return list;
    }
    let carried = '';
    for (let i = 0; i < list.length; i++) {
      if (list[i].pairId === livePairId) {
        carried = list[i].uid;
        list.splice(i, 1);
        break;
      }
    }
    const live: CloudUnpairTarget = { pairId: livePairId, uid: carried };
    list.unshift(live);
    return list;
  }

  /**
   * 把 `cloudUnpairTargets()` 那份账逐个敲一遍门，按「删掉了 / 还欠着 / 终局判了」三档记账，
   * 并把**没删掉的**原样交回调用方落库（`kept`）。
   *
   * 关闭态一次云调用都不发（B1 的 `AgcPairingClient.calls === 0` 断言管的就是这一格），但每一笔
   * 都照记成欠账，`switchClosed` 只用来把话改成"开通后再试"——「开关只关能力，不关数据」。
   * 旧写法是 `cloudPairing ? target : null`：回退版本下既不发也不记，紧接着 `forgetPair()`／
   * `clearAllSettings()` 照样把本机 pairId 推平，云上那份密文当场成为谁都对不上号的孤儿行。
   * 按发布预案回退一档，本来只是关掉能力，实际却把用户的云端数据永久留在那儿——这一格是批次 AO 第一条。
   *
   * `failClosed` 只属于解除配对那一档：活着的 pairId 没删成就本机一行都不清，重试的凭据
   * 就是这一屏本身。「清空我的全部数据」不看它——用户对自己的设备有即时处置权。
   */
  private static async sweepCloudUnpair(failClosed: boolean): Promise<CloudSweep> {
    const kept: PendingCloudUnpair[] = [];
    const sweep: CloudSweep = { removed: 0, waiting: 0, dead: 0, refusedMessage: '', switchClosed: false, kept: kept };
    const targets = ProfileSettingsService.cloudUnpairTargets();
    if (targets.length === 0) {
      return sweep;
    }
    const livePairId = SettingsStore.getPairId();
    if (!FeatureFlags.cloudPairing) {
      sweep.switchClosed = true;
      for (let i = 0; i < targets.length; i++) {
        const uid = targets[i].uid === '' ? await SettingsStore.getOrCreateUid() : targets[i].uid;
        const k: PendingCloudUnpair = { pairId: targets[i].pairId, uid: uid, dead: false };
        kept.push(k);
      }
      sweep.waiting = targets.length;
      return sweep;
    }
    for (let i = 0; i < targets.length; i++) {
      const pairId = targets[i].pairId;
      const uid = targets[i].uid === '' ? await SettingsStore.getOrCreateUid() : targets[i].uid;
      const out = await ProfileSettingsService.cloudUnpair(pairId, uid);
      if (out.removed) {
        sweep.removed = sweep.removed + 1;
        continue;
      }
      const k: PendingCloudUnpair = { pairId: pairId, uid: uid, dead: !out.retryLater };
      kept.push(k);
      if (out.retryLater) {
        sweep.waiting = sweep.waiting + 1;
      } else {
        sweep.dead = sweep.dead + 1;
      }
      if (failClosed && pairId === livePairId) {
        Logger.warn(TAG, 'unpair cloud failed, local marks kept: ' + out.message);
        sweep.refusedMessage = '云上那份还没删掉，本机配对我留着了：' + out.message;
        return sweep;
      }
    }
    return sweep;
  }

  /**
   * 把这一轮没删掉的欠账落进偏好。**必须在清库之后调用**：`clearAllSettings()` 会把这一格一起推平，
   * 而它是那场推平里唯一该活下来的东西——没有它，这台设备再也没有地方记得云上还有份密文。
   *
   * `deadOnly` 只用于解除配对 fail-closed 那一格：还值得再敲的那一笔，本机这一屏就是凭据，
   * 不必另存一份会漂的副本；而云端已经判死的那一行，本机留着 pairId 也敲不动它，
   * 只有落进队列才有人替用户报出「这台手机删不掉」（批次 AO·AO3）。
   */
  private static async rememberCloudDebt(s: CloudSweep, deadOnly: boolean): Promise<void> {
    for (let i = 0; i < s.kept.length; i++) {
      if (deadOnly && !s.kept[i].dead) {
        continue;
      }
      await SettingsStore.addPendingCloudUnpair(s.kept[i].pairId, s.kept[i].uid, s.kept[i].dead);
    }
  }

  /**
   * 解除配对：云侧级联删快照 + 本机配对标记/协商密钥/对方快照游标一律清干净。
   *
   * 注意这条**不受关闭态拒绝**：上一版原型可能在本机留下 PAIRED 与残留密钥，而云入口已经藏起来了，
   * 用户必须还能亲手撤掉这些标记，否则界面会一直挂着"已配对"。「开关只关能力，不关数据」。
   *
   * **[批次 U·U5] 云端删不动时 fail-closed，本机一行都不清。** 旧写法是把云侧异常吞成一句 warn，
   * 接着照删 pairId 与 HUKS 别名，最后回一句「已解除配对」——那是三件事叠出来的谎：
   * 云上那行密文还在（协议 §4.5 的删除凭据就是 pairId + uid，本机一清就再没有别的入口能删它）、
   * 用户以为已经删了所以不会再试、界面上"已解除"三个字把欠账抹平了。
   * 现在失败原样回给用户，配对标记留在原地，于是**重试的凭据就是这一屏本身**：
   * 同一颗按钮、同一条提示，网络通了再点一次就补上。
   * 真要连不上云端也还有出路——「清空我的全部数据」这条会把待补删凭据落进偏好（见 `clearAllData`）。
   *
   * **[批次 AO·AO1] 关闭态走另一条：本机照清，欠账照记。** 上面那条 fail-closed 的前提是"这一屏
   * 就是凭据"，而关闭态没有这一屏可留（用户撤不掉的是入口，不是数据）。于是这里让 `forgetPair()`
   * 照常清本机，但把那笔 pairId + uid 记进待补删队列，话也说清楚是"云上那份还没删掉、开通后再试"——
   * 回退版本不该顺手把云端数据判成孤儿。
   */
  static async unpair(): Promise<SettingsResult> {
    try {
      const sweep = await ProfileSettingsService.sweepCloudUnpair(true);
      if (sweep.refusedMessage !== '') {
        await ProfileSettingsService.rememberCloudDebt(sweep, true);
        return fail(sweep.refusedMessage);
      }
      await ProfileSettingsService.forgetPair();
      await ProfileSettingsService.rememberCloudDebt(sweep, false);
      ScheduleUseCase.onScheduleChanged().catch(() => {
      });
      return ok((sweep.switchClosed ? '本机配对已解除' : '已解除配对') + cloudCleanupNote(sweep));
    } catch (e) {
      return fail('操作失败：' + (e as Error).message);
    }
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
      .then(() => ProfileSettingsService.commitBeat(pairId, now))
      .catch((e: Error) => {
        Logger.warn(TAG, 'heartbeat degraded: ' + e.message);
      });
  }

  /**
   * 落心跳游标之前的**同一性复核**：这一趟 await 期间用户可能已经解除配对，甚至又配上了另一个人。
   * 旧写法无条件写 `now`，于是旧会话那一次往返的返回值会把新会话的游标推到一周之后——
   * 新配对最多空等一周才发出第一跳，而这段时间页面上说的全是这一轮的事。
   * `forgetPair()` 已经把游标归零，所以这里丢掉的只是"迟到的一跳"，不会留下半条旧账。
   */
  private static async commitBeat(pairId: string, now: number): Promise<void> {
    if (pairId === '' || SettingsStore.getPairId() !== pairId) {
      Logger.warn(TAG, 'heartbeat result dropped: that pair is no longer the current one');
      return;
    }
    await SettingsStore.setLastHeartbeatAt(now);
  }

  // ---------- 清空数据 ----------

  /**
   * 清空 8 张 RDB 表 + 全部设置；隐私同意标记保留，避免重启后重复弹窗。
   *
   * 清库之前先把系统侧的东西一起带走（验收报告 B2）：计划级的系统日历日程，以及（升级前遗留的）
   * 计划级提醒句柄，再整本清掉应用专属「同休日」日历作兜底（句柄丢了的那些日程也一并删掉）。
   * "清空我的全部数据"这句话若只管本机表，用户删掉的只是自己看得见的那份，
   * 日程和提醒还留在系统里——所以清不干净的部分必须报数，不能回一句"已清空"。
   *
   * **[批次 U·U5] 云侧那两行快照是同一条要求的第四项**，旧写法压根没打算碰它：清库把
   * `pairId`、HUKS 别名与 uid 一起推平之后，云上那份密文就成了谁都对不上号的孤儿行，
   * 而本机界面上连"还剩这么个东西"都不再说一句。这里的口径与系统侧那两项一致：
   *
   * 1. **本机能收回的先收回**——清空不因为云端删不动而失败（用户对自己的设备有即时处置权，
   *    这一条与 `unpair` 的 fail-closed 相反，因为 `unpair` 没有"必须删干净本机"的压力）；
   * 2. **删不掉的要留下凭据**——只留 `pairId` + 本机 `uid`（`pairing.unpair` 认的就是会话行里
   *    那两列成员，密钥材料对删除毫无用处），写在 `clearAllSettings()` 之后，否则它自己就是第一个被推平的；
   *    队列可以有几条：上一次清空没删动的，这一次同样要带走，不许被新的一条顶掉（批次 AO·AO2）。
   * 3. **要如实报，不承诺做不到的**——`retryable = false` 的判定（不是成员、参数不合法、版本对不上）
   *    重跑也是同一句，所以它标记成 `dead` 退出补删队列，但**仍留在偏好里报数**：那行密文还在云上，
   *    一句 warn 用户看不见（批次 AO·AO3 的读侧就是 `undeletableCloudSnapshots()`）。
   *    只有能补删的那一笔，话里才说"下次打开会自动再试"。
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
      // 云端那几行要在本机身份还在的时候删：pairId 与 uid 一推平，就再没有别的地方记得它们了
      const sweep = await ProfileSettingsService.sweepCloudUnpair(false);
      // 协商密钥要跟着一起毁：pairId 随 Preferences 清掉之后，HUKS 里那把别名就成了没人认领的钥匙
      await PairKeyStore.dropPairKey(SettingsStore.getPairId());
      await ScheduleRepo.clearAllData();
      await SettingsStore.clearAllSettings();
      await ProfileSettingsService.rememberCloudDebt(sweep, false);
      if (privacyWas) {
        await SettingsStore.acceptPrivacy();
      }
      await ScheduleUseCase.onScheduleChanged();
      return ok(clearAllMessageOf(report, calendarPurged) + cloudCleanupNote(sweep));
    } catch (e) {
      return fail('清空失败：' + (e as Error).message);
    }
  }

  /**
   * 上一次「清空全部数据」或关闭态解除配对没删掉的云侧快照，在这里补删。
   *
   * 挂在回前台的初始化链尾、与心跳同一排，是因为本机已经没有别的入口记得这件事了：
   * 配对标记、pairId、对方快照全随清空推平，只剩偏好里那一串凭据，而 §3.3/§7 又禁后台常驻。
   * 于是"下一次打开应用"就是它唯一的机会——与系统侧投影的 `sweepPendingProjections` 同一形状。
   *
   * 不建重试计数也不排闹钟：这条链的触发频率就是用户的启动频率，本身已经被"人还在用这个应用"
   * 限住了；而云端一旦给了终局判定（`retryLater = false`）就把它标记成 `dead` 退出补删队列，
   * 不会一直白敲门——但**不删记录**：那行密文还在云上，删了记录就等于把知情也一起删掉（批次 AO·AO3）。
   * `dead` 的读侧是 `undeletableCloudSnapshots()`，落点是「我的 · 数据与隐私」那一条。
   */
  static async retryPendingCloudUnpair(): Promise<void> {
    if (ProfileSettingsService.cloudBlocked()) {
      return;
    }
    let pending: PendingCloudUnpair[] = [];
    try {
      pending = SettingsStore.getPendingCloudUnpair();
    } catch (e) {
      // Preferences 尚未初始化：这一趟不补删，下一次回前台还有机会
      return;
    }
    for (let i = 0; i < pending.length; i++) {
      const p = pending[i];
      if (p.dead) {
        continue;
      }
      const cloud = await ProfileSettingsService.cloudUnpair(p.pairId, p.uid);
      if (cloud.removed) {
        await SettingsStore.dropPendingCloudUnpair(p.pairId);
      } else if (!cloud.retryLater) {
        await SettingsStore.addPendingCloudUnpair(p.pairId, p.uid, true);
      }
      // 还欠着且值得再敲的那一笔：原样留在队列里，下一次回前台再试
      Logger.warn(TAG, 'pending cloud unpair ' + (cloud.removed ? 'removed'
        : (cloud.retryLater ? 'kept for the next launch' : 'refused for good')));
    }
  }
}
