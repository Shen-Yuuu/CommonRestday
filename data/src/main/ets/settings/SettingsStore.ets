import { preferences } from '@kit.ArkData';
import { common } from '@kit.AbilityKit';
import { util } from '@kit.ArkTS';
import { defaultParams, EngineParams, ScheduleOverride } from 'domain';
import { Logger } from 'commons';

/**
 * 轻量键值设置：引擎参数、隐私共享等级、配对状态等。
 * 结构化对象以 JSON 存储，读取失败时回退默认值。
 */

const TAG = 'Settings';
const STORE = 'crd_settings';

const KEY_PARAMS = 'engine_params';
const KEY_SHARE_LEVEL = 'share_level';
const KEY_PAIR_STATE = 'pair_state';
const KEY_PARTNER_ID = 'partner_uid';
const KEY_PARTNER_PROFILE = 'partner_profile';
const KEY_PRIVACY_ACCEPTED = 'privacy_accepted';
const KEY_DEVICE_UID = 'device_uid';
const KEY_PAIR_KEY = 'pair_key';
const KEY_PAIR_ID = 'pair_id';
const KEY_PARTNER_SNAP_VER = 'partner_snap_ver';
const KEY_PARTNER_SNAP_CACHE = 'partner_snap_cache';
const KEY_CLOUD_SYNC_STATE = 'cloud_sync_state';
const KEY_LAST_RECOMPUTE_DAY = 'last_recompute_day';
const KEY_LAST_HEARTBEAT_AT = 'last_heartbeat_at';
const KEY_PENDING_CLOUD_UNPAIR = 'pending_cloud_unpair';

export const PAIR_NONE = 'NONE';
export const PAIR_WAITING = 'WAITING';
/**
 * 对方已经用码加入、还等这一侧确认（协议 §8 的 PENDING_CONFIRM 在本机的投影）。
 * 加入方停在这档：它已经能协商出密钥，但在发起方确认之前一条快照都不推——
 * 少了这一档，加入方就会直接 PAIRED，界面上就是"已经在同步了"的谎（TC §9.5）。
 */
export const PAIR_PENDING = 'PENDING_CONFIRM';
export const PAIRED = 'PAIRED';
export const PAIR_ERROR = 'ERROR';

/** 伴侣档案：昵称 + 伴侣独立引擎参数子集（起床/就寝/收整）。 */
export interface PartnerProfile {
  nick: string;
  wakeMin: number;
  bedMin: number;
  windDownMin: number;
}

/**
 * 云侧那两行快照没删掉时留下的重试凭据（协议 §4.5 批次 U·U5）。
 *
 * 只有两个字段，而且是故意的：`pairing.unpair` 认的是会话行里的 `creatorUid`/`joinerUid`，
 * 删除**不需要任何密钥材料**。别的一概不存——HUKS 别名、对方快照、任何明文忙碌时段
 * 都不属于"把云上那行删掉"这件事，把它们留在一次「清空我的全部数据」之后就是漏披露。
 */
/**
 * 一次没删干净的云侧配对（协议 §4.5：删除要的凭据就是这两列成员，密钥材料对删除毫无用处）。
 *
 * `dead` 为真表示云端已经给了**终局判定**（不是那个会话的成员、参数不合法、版本对不上）——
 * 再敲一百次门也是同一句，于是它退出补删队列，只留着向用户如实报「云上还剩一份」。
 * 这一位是批次 AO 加的：终局之前只在日志里留了一行，用户看不见自己还剩这么个东西。
 */
export interface PendingCloudUnpair {
  pairId: string;
  uid: string;
  dead: boolean;
}

export class SettingsStore {
  private static prefs: preferences.Preferences | null = null;

  /** 初始化 Preferences（应用/卡片等任一进程入口调用一次；Context 基类以兼容 FormExtensionAbility）。 */
  static async init(context: common.Context): Promise<void> {
    if (SettingsStore.prefs != null) {
      return;
    }
    SettingsStore.prefs = await preferences.getPreferences(context, STORE);
  }

  private static p(): preferences.Preferences {
    if (SettingsStore.prefs == null) {
      throw new Error('SettingsStore not initialized');
    }
    return SettingsStore.prefs;
  }

  // ---------- 引擎参数 ----------

  static async setParams(p: EngineParams): Promise<void> {
    const text = JSON.stringify({
      horizonDays: p.horizonDays, wakeMin: p.wakeMin, bedMin: p.bedMin,
      windDownMin: p.windDownMin, nightStartMin: p.nightStartMin, nightEndMin: p.nightEndMin,
      minSlotMin: p.minSlotMin, halfDayMin: p.halfDayMin, fullDayAvailMin: p.fullDayAvailMin,
      overnightMinMin: p.overnightMinMin, tripMinMin: p.tripMinMin,
      studyStartMin: p.studyStartMin, studyEndMin: p.studyEndMin, studyMinMin: p.studyMinMin
    });
    await SettingsStore.p().put(KEY_PARAMS, text);
    await SettingsStore.p().flush();
  }

  static getParams(): EngineParams {
    const text = SettingsStore.p().getSync(KEY_PARAMS, '') as string;
    const p = defaultParams();
    if (text === '') {
      return p;
    }
    try {
      const o = JSON.parse(text) as Record<string, Object>;
      // 旧版本存量 JSON 可能缺少新增字段：仅覆盖存在且可解析为数字的键，避免 NaN 污染。
      SettingsStore.assignParam(p, 'horizonDays', o);
      SettingsStore.assignParam(p, 'wakeMin', o);
      SettingsStore.assignParam(p, 'bedMin', o);
      SettingsStore.assignParam(p, 'windDownMin', o);
      SettingsStore.assignParam(p, 'nightStartMin', o);
      SettingsStore.assignParam(p, 'nightEndMin', o);
      SettingsStore.assignParam(p, 'minSlotMin', o);
      SettingsStore.assignParam(p, 'halfDayMin', o);
      SettingsStore.assignParam(p, 'fullDayAvailMin', o);
      SettingsStore.assignParam(p, 'overnightMinMin', o);
      SettingsStore.assignParam(p, 'tripMinMin', o);
      SettingsStore.assignParam(p, 'studyStartMin', o);
      SettingsStore.assignParam(p, 'studyEndMin', o);
      SettingsStore.assignParam(p, 'studyMinMin', o);
    } catch (e) {
      Logger.warn(TAG, 'params parse failed, use defaults');
    }
    return p;
  }

  private static assignParam(p: EngineParams, key: string, o: Record<string, Object>): void {
    const raw = o[key];
    if (raw == null) {
      return;
    }
    const v = Number(raw);
    if (Number.isNaN(v)) {
      return;
    }
    if (key === 'horizonDays') {
      p.horizonDays = v;
    } else if (key === 'wakeMin') {
      p.wakeMin = v;
    } else if (key === 'bedMin') {
      p.bedMin = v;
    } else if (key === 'windDownMin') {
      p.windDownMin = v;
    } else if (key === 'nightStartMin') {
      p.nightStartMin = v;
    } else if (key === 'nightEndMin') {
      p.nightEndMin = v;
    } else if (key === 'minSlotMin') {
      p.minSlotMin = v;
    } else if (key === 'halfDayMin') {
      p.halfDayMin = v;
    } else if (key === 'fullDayAvailMin') {
      p.fullDayAvailMin = v;
    } else if (key === 'overnightMinMin') {
      p.overnightMinMin = v;
    } else if (key === 'tripMinMin') {
      p.tripMinMin = v;
    } else if (key === 'studyStartMin') {
      p.studyStartMin = v;
    } else if (key === 'studyEndMin') {
      p.studyEndMin = v;
    } else if (key === 'studyMinMin') {
      p.studyMinMin = v;
    }
  }

  // ---------- 隐私共享等级 ----------

  static async setShareLevel(level: number): Promise<void> {
    await SettingsStore.p().put(KEY_SHARE_LEVEL, level);
    await SettingsStore.p().flush();
  }

  static getShareLevel(): number {
    const v = SettingsStore.p().getSync(KEY_SHARE_LEVEL, 2);
    return Number(v);
  }

  // ---------- 配对状态 ----------

  static async setPairState(state: string, partnerUid: string): Promise<void> {
    await SettingsStore.p().put(KEY_PAIR_STATE, state);
    await SettingsStore.p().put(KEY_PARTNER_ID, partnerUid);
    await SettingsStore.p().flush();
  }

  static getPairState(): string {
    return SettingsStore.p().getSync(KEY_PAIR_STATE, PAIR_NONE) as string;
  }

  static getPartnerUid(): string {
    return SettingsStore.p().getSync(KEY_PARTNER_ID, '') as string;
  }

  /** 快照版本号（单调递增）。 */
  static async nextSnapshotVersion(): Promise<number> {
    const v = Number(SettingsStore.p().getSync('snap_ver', 0)) + 1;
    await SettingsStore.p().put('snap_ver', v);
    await SettingsStore.p().flush();
    return v;
  }

  static getSnapshotVersion(): number {
    return Number(SettingsStore.p().getSync('snap_ver', 0));
  }

  // ---------- 设备标识与配对密钥 ----------

  /** 稳定设备标识：首次生成随机 UUID 并持久化，之后直接返回（云端配对用它替代"每次调用随机 UUID"）。 */
  static async getOrCreateUid(): Promise<string> {
    const existing = SettingsStore.p().getSync(KEY_DEVICE_UID, '') as string;
    if (existing !== '') {
      return existing;
    }
    const uid = util.generateRandomUUID();
    await SettingsStore.p().put(KEY_DEVICE_UID, uid);
    await SettingsStore.p().flush();
    return uid;
  }

  /**
   * 快照加密密钥（旧原型残留）。
   *
   * **本应用没有读它的路径，也没有写它的路径**：长期密钥从阶段 3 起只活在 HUKS 别名里
   * （`cloud` 的 `PairKeyStore`），Preferences 里连别名都不存——别名由 pairId 推出来，
   * 存一份就会和 pairId 漂。留着这个 delete 只为了清理旧原型留下的 64 位 hex：
   * 那条残留既解不开今天的信封，也不该一直躺在明文键值文件里。
   */
  static async clearPairKey(): Promise<void> {
    await SettingsStore.p().delete(KEY_PAIR_KEY);
    await SettingsStore.p().flush();
  }

  /** 配对会话 id（快照推送/拉取的 pairId）；未配对时返回空串。 */
  static getPairId(): string {
    return SettingsStore.p().getSync(KEY_PAIR_ID, '') as string;
  }

  static async savePairId(pairId: string): Promise<void> {
    await SettingsStore.p().put(KEY_PAIR_ID, pairId);
    await SettingsStore.p().flush();
  }

  /** 已接收的对方快照版本（pull 的 sinceVersion 游标）。 */
  static getPartnerSnapVer(): number {
    return Number(SettingsStore.p().getSync(KEY_PARTNER_SNAP_VER, 0));
  }

  static async setPartnerSnapVer(v: number): Promise<void> {
    await SettingsStore.p().put(KEY_PARTNER_SNAP_VER, v);
    await SettingsStore.p().flush();
  }

  /**
   * 最后一次**有效**对方快照的信封（协议 §5.1 的 JSON，含密文与明文元数据）；未拉到过为空串。
   *
   * 存密文而不是存解码后的区间：解码仍要每次走 HUKS 别名 + 信封自带的 AAD，
   * 于是"把 A 配对的信封搬到 B 配对下"在读取时自然解不开，键值文件里也始终没有明文忙碌时段。
   * 密钥材料一格都不写（长期密钥只活在 HUKS 别名里，见 `clearPairKey` 的注释）。
   */
  static getPartnerSnapCache(): string {
    return SettingsStore.p().getSync(KEY_PARTNER_SNAP_CACHE, '') as string;
  }

  static async setPartnerSnapCache(envelope: string): Promise<void> {
    await SettingsStore.p().put(KEY_PARTNER_SNAP_CACHE, envelope);
    await SettingsStore.p().flush();
  }

  static async clearPartnerSnapCache(): Promise<void> {
    await SettingsStore.p().delete(KEY_PARTNER_SNAP_CACHE);
    await SettingsStore.p().flush();
  }

  /**
   * 云同步最近一次结论的编码串（`已同步/待重试/已降级|epochDay|语义码`，见 feature 的 `CloudSyncRules`）；
   * 空串 = 这台设备还没试过同步。协议 §3.4 末行的三态与 §7 末行的"当天不再重排"都读这一格。
   */
  static getCloudSyncState(): string {
    return SettingsStore.p().getSync(KEY_CLOUD_SYNC_STATE, '') as string;
  }

  static async setCloudSyncState(raw: string): Promise<void> {
    await SettingsStore.p().put(KEY_CLOUD_SYNC_STATE, raw);
    await SettingsStore.p().flush();
  }

  /**
   * 上一次心跳**成功返回**时的本机时刻（epoch ms）；0 = 从未心跳过。
   *
   * 两个口径都是故意的：存本机钟而不是服务端回的 serverTime，因为节流比的是同一只钟的两端；
   * 失败不写，所以"未到期"这一句是真的"最近一次确认活着"，而不是"最近一次试过"。
   */
  static getLastHeartbeatAt(): number {
    return Number(SettingsStore.p().getSync(KEY_LAST_HEARTBEAT_AT, 0));
  }

  static async setLastHeartbeatAt(ms: number): Promise<void> {
    await SettingsStore.p().put(KEY_LAST_HEARTBEAT_AT, ms);
    await SettingsStore.p().flush();
  }

  /**
   * 读全部待补删的云侧配对。批次 AO 起它是一条**队列**而不是单格：
   * 「上次没删掉 → 又配了一次 → 再清空」时两条都得记住，旧那条不该因为新的插队就被推平。
   *
   * 脏串、非数组、缺字段一律按「那一条没有欠账」处理，与 `decodeSyncState` 同一取向：
   * 宁可这条提示不出来，也不要一次偏好写坏就在页面上挂假警报。
   */
  static getPendingCloudUnpair(): PendingCloudUnpair[] {
    const text = SettingsStore.p().getSync(KEY_PENDING_CLOUD_UNPAIR, '') as string;
    if (text === '') {
      return [];
    }
    const out: PendingCloudUnpair[] = [];
    try {
      const rows = JSON.parse(text) as Array<Record<string, Object>>;
      for (let i = 0; i < rows.length; i++) {
        const o = rows[i];
        const pairId = o['pairId'] == null ? '' : String(o['pairId']);
        const uid = o['uid'] == null ? '' : String(o['uid']);
        if (pairId === '' || uid === '') {
          continue;
        }
        const rec: PendingCloudUnpair = { pairId: pairId, uid: uid, dead: String(o['dead']) === '1' };
        out.push(rec);
      }
    } catch (e) {
      Logger.warn(TAG, 'pending cloud unpair parse failed');
      return [];
    }
    return out;
  }

  /**
   * 记一条待补删的云侧配对（同一个 pairId 只留一条，重复登记按最后一次的说法覆盖）。
   *
   * 调用方必须排在 `clearAllSettings()` **之后**：清空动作是把整张表推平，
   * 而这条记录存在的意义正是"本机已经没有别的地方记得这次删除了"。
   * `uid` 必须是**推平前**读到的那一个——云端认的是成员表里那个旧 uid，换新 uid 永远撞 FORBIDDEN。
   */
  static async addPendingCloudUnpair(pairId: string, uid: string, dead: boolean): Promise<void> {
    if (pairId === '' || uid === '') {
      return;
    }
    const list = SettingsStore.getPendingCloudUnpair();
    const next: PendingCloudUnpair[] = [];
    for (let i = 0; i < list.length; i++) {
      if (list[i].pairId !== pairId) {
        next.push(list[i]);
      }
    }
    const rec: PendingCloudUnpair = { pairId: pairId, uid: uid, dead: dead };
    next.push(rec);
    await SettingsStore.savePendingCloudUnpair(next);
  }

  /** 补删成了（或已被终局判定那条顶替）之后，把这一条从队列里拿掉。 */
  static async dropPendingCloudUnpair(pairId: string): Promise<void> {
    const list = SettingsStore.getPendingCloudUnpair();
    const next: PendingCloudUnpair[] = [];
    for (let i = 0; i < list.length; i++) {
      if (list[i].pairId !== pairId) {
        next.push(list[i]);
      }
    }
    await SettingsStore.savePendingCloudUnpair(next);
  }

  /**
   * 整份队列存成一个串（空队列存空串）：这几条永远一起变，分成几格就把"只写了一半"做出来了。
   *
   * `dead` 存 **1/0 而不是布尔**：`JSON.stringify(true)` 出来是 `true`，而读侧 `String(v) === '1'`
   * 认的是这个数；用布尔写就用布尔读，两边各认一种字面量，就是"登记了却读不出"的那一格。
   */
  static async savePendingCloudUnpair(list: PendingCloudUnpair[]): Promise<void> {
    const rows: Array<Record<string, Object>> = [];
    for (let i = 0; i < list.length; i++) {
      const o: Record<string, Object> = {
        'pairId': list[i].pairId, 'uid': list[i].uid, 'dead': list[i].dead ? 1 : 0
      };
      rows.push(o);
    }
    await SettingsStore.p().put(KEY_PENDING_CLOUD_UNPAIR, list.length === 0 ? '' : JSON.stringify(rows));
    await SettingsStore.p().flush();
  }

  static async clearPendingCloudUnpair(): Promise<void> {
    await SettingsStore.p().delete(KEY_PENDING_CLOUD_UNPAIR);
    await SettingsStore.p().flush();
  }

  /** 云上还剩几份是这台手机**删不掉**的（终局判定那一族）：只用于向用户如实报数。 */
  static countDeadCloudUnpair(): number {
    const list = SettingsStore.getPendingCloudUnpair();
    let n = 0;
    for (let i = 0; i < list.length; i++) {
      if (list[i].dead) {
        n = n + 1;
      }
    }
    return n;
  }

  // ---------- 日切重算 ----------

  /** 最近一次重算的 epochDay（日切判断用；App 切前台时与其比较，跨天即重算）。 */
  static getLastRecomputeDay(): number {
    return Number(SettingsStore.p().getSync(KEY_LAST_RECOMPUTE_DAY, -1));
  }

  static async setLastRecomputeDay(day: number): Promise<void> {
    await SettingsStore.p().put(KEY_LAST_RECOMPUTE_DAY, day);
    await SettingsStore.p().flush();
  }

  // ---------- 伴侣档案（本机代录） ----------

  /** 读取伴侣档案；未建立时返回 null。 */
  static getPartnerProfile(): PartnerProfile | null {
    const text = SettingsStore.p().getSync(KEY_PARTNER_PROFILE, '') as string;
    if (text === '') {
      return null;
    }
    try {
      const o = JSON.parse(text) as Record<string, Object>;
      const profile: PartnerProfile = {
        nick: String(o['nick']),
        wakeMin: Number(o['wakeMin']),
        bedMin: Number(o['bedMin']),
        windDownMin: Number(o['windDownMin'])
      };
      return profile;
    } catch (e) {
      Logger.warn(TAG, 'partner profile parse failed');
      return null;
    }
  }

  static async savePartnerProfile(profile: PartnerProfile): Promise<void> {
    const text = JSON.stringify({
      nick: profile.nick, wakeMin: profile.wakeMin,
      bedMin: profile.bedMin, windDownMin: profile.windDownMin
    });
    await SettingsStore.p().put(KEY_PARTNER_PROFILE, text);
    await SettingsStore.p().flush();
  }

  static async clearPartnerProfile(): Promise<void> {
    await SettingsStore.p().delete(KEY_PARTNER_PROFILE);
    await SettingsStore.p().flush();
  }

  // ---------- 首启隐私标记 ----------

  /** 首启隐私政策弹窗是否已同意。 */
  static isPrivacyAccepted(): boolean {
    return SettingsStore.p().getSync(KEY_PRIVACY_ACCEPTED, false) === true;
  }

  static async acceptPrivacy(): Promise<void> {
    await SettingsStore.p().put(KEY_PRIVACY_ACCEPTED, true);
    await SettingsStore.p().flush();
  }

  // ---------- 全量清空 ----------

  /**
   * 清空 crd_settings 的全部条目（"清空我的全部数据"设置项的设置侧；数据侧配合 ScheduleRepo.clearAllData）。
   *
   * 连 `device_uid` 与 `pending_cloud_unpair` 一起推平，所以调用方要在这句之后补写云侧的待补删凭据，
   * 且补写用的 uid 必须是**推平前**读到的那一个——云端认的是成员表里那个旧 uid，换新的是对不上的。
   */
  static async clearAllSettings(): Promise<void> {
    await SettingsStore.p().clear();
    await SettingsStore.p().flush();
  }
}

/** 空覆盖构造（供 UI 快捷使用）。 */
export function emptyOverride(epochDay: number): ScheduleOverride {
  const o: ScheduleOverride = { epochDay: epochDay, shiftTypeId: null };
  return o;
}
