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
const KEY_WEEKLY_REMINDER_ID = 'weekly_reminder_id';
const KEY_LAST_RECOMPUTE_DAY = 'last_recompute_day';
const KEY_NOTIFY_PRECISE = 'notify_precise_reminder';
const KEY_NOTIFY_WEEKLY = 'notify_weekly_summary';
const KEY_NOTIFY_ACTION = 'notify_action_alerts';
const KEY_NOTIFIED_CONFLICT_SIGS = 'notified_conflict_sigs';
const KEY_NOTIFIED_REPAIR = 'notified_repair';

export const PAIR_NONE = 'NONE';
export const PAIR_WAITING = 'WAITING';
export const PAIRED = 'PAIRED';
export const PAIR_ERROR = 'ERROR';

/** 伴侣档案：昵称 + 伴侣独立引擎参数子集（起床/就寝/收整）。 */
export interface PartnerProfile {
  nick: string;
  wakeMin: number;
  bedMin: number;
  windDownMin: number;
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
    // 配对一变，"需要重新配对"那句提示就过期：新状态下要还能再提醒一次
    await SettingsStore.p().delete(KEY_NOTIFIED_REPAIR);
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
   * 快照加密密钥（32 字节 hex，64 字符）；没有就返回空串。
   *
   * **只读**：本应用不往 Preferences 写长期密钥（改造文档 §0.3 红线 + 阶段 6R.2）。
   * 之前那个写入口 `savePairKey` 连同 `SnapshotCrypto.deriveKeyHex` 一起删掉了——它写进去的是
   * "6 位邀请码 SHA-256"出来的密钥，熵只有 ~20 bit，而 Preferences 是明文可读的键值文件。
   * 长期密钥的唯一容器是 HUKS（Task 0.4 尚未验证，所以云端配对保持关闭）。
   * 这里保留读，是为了让读到残留值时快照链路仍要校验长度，也是为了把旧原型留下的那条清干净。
   */
  static async getPairKey(): Promise<string> {
    return SettingsStore.p().getSync(KEY_PAIR_KEY, '') as string;
  }

  /** 清掉上一版原型可能留在沙箱里的密钥（解除配对、清空数据、恢复完成回调都用它）。 */
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

  // ---------- 周摘要提醒 ----------

  /** 周摘要提醒的 reminder id；未注册时返回 -1。 */
  static async getWeeklyReminderId(): Promise<number> {
    return Number(SettingsStore.p().getSync(KEY_WEEKLY_REMINDER_ID, -1));
  }

  static async setWeeklyReminderId(id: number): Promise<void> {
    await SettingsStore.p().put(KEY_WEEKLY_REMINDER_ID, id);
    await SettingsStore.p().flush();
  }

  // ---------- 通知与提醒开关（阶段 4 Task 4.3：默认低打扰） ----------

  /**
   * 精确提醒（ReminderAgent 定点提醒）。默认关闭：
   * 计划默认写进系统日历，报时由日历负责，再叠一条应用自建提醒就是双倍打扰。
   */
  static isPreciseReminderOn(): boolean {
    return SettingsStore.p().getSync(KEY_NOTIFY_PRECISE, false) === true;
  }

  static async setPreciseReminderOn(on: boolean): Promise<void> {
    await SettingsStore.p().put(KEY_NOTIFY_PRECISE, on);
    await SettingsStore.p().flush();
  }

  /** 周日周摘要提醒。默认关闭：共同时间是"要看的那一周"，不是每周必到的推送。 */
  static isWeeklySummaryOn(): boolean {
    return SettingsStore.p().getSync(KEY_NOTIFY_WEEKLY, false) === true;
  }

  static async setWeeklySummaryOn(on: boolean): Promise<void> {
    await SettingsStore.p().put(KEY_NOTIFY_WEEKLY, on);
    await SettingsStore.p().flush();
  }

  /** 需行动通知（冲突、需重新配对）。默认开启：这是唯一"用户不在屏幕上时也有价值"的一类。 */
  static isActionAlertsOn(): boolean {
    return SettingsStore.p().getSync(KEY_NOTIFY_ACTION, true) === true;
  }

  static async setActionAlertsOn(on: boolean): Promise<void> {
    await SettingsStore.p().put(KEY_NOTIFY_ACTION, on);
    await SettingsStore.p().flush();
  }

  /**
   * 已提示过的冲突签名集合（';' 连接）。每轮重算整体覆写，所以随冲突消失自动收敛；
   * 同一签名不重复提示，签名一变（原因或受影响区间变了）就是新冲突，会再提示一次。
   */
  static getNotifiedConflictSigs(): string {
    return SettingsStore.p().getSync(KEY_NOTIFIED_CONFLICT_SIGS, '') as string;
  }

  static async setNotifiedConflictSigs(sigs: string): Promise<void> {
    await SettingsStore.p().put(KEY_NOTIFIED_CONFLICT_SIGS, sigs);
    await SettingsStore.p().flush();
  }

  /** "需要重新配对"是否已经提示过；配对状态一变就清，允许下一次再提示。 */
  static isRepairNoticeSent(): boolean {
    return SettingsStore.p().getSync(KEY_NOTIFIED_REPAIR, false) === true;
  }

  static async setRepairNoticeSent(on: boolean): Promise<void> {
    await SettingsStore.p().put(KEY_NOTIFIED_REPAIR, on);
    await SettingsStore.p().flush();
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

  /** 清空 crd_settings 的全部条目（"清空我的全部数据"设置项的设置侧；数据侧配合 ScheduleRepo.clearAllData）。 */
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
