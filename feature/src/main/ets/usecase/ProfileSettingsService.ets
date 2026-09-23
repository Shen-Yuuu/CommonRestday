import { EngineParams, defaultParams, hhmmToMin, minToHHmm } from 'domain';
import {
  PAIRED, PAIR_NONE, PAIR_WAITING, PartnerProfile, ScheduleRepo, SettingsStore
} from 'data';
import { AgcPairingClient, PairingSession } from 'cloud';
import { Logger } from 'commons';
import { FeatureFlags } from '../config/FeatureFlags';
import { ScheduleUseCase } from './ScheduleUseCase';
import { PlanProjectionCleanupService } from './PlanProjectionCleanupService';
import { PlanCapabilities } from '../integration/PlanCapabilities';
import {
  addCleanupReport, clearAllMessageOf, emptyCleanupReport
} from '../model/PlanFlow';
import { horizonError, isCrossMidnight, rhythmError, toMinutes } from '../model/RhythmRules';

const TAG = 'ProfileSettingsService';

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
      return fail('设置尚未就绪，请稍后再试');
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
    return ok('参数已保存，已重新计算');
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
      return fail('请填写伴侣昵称');
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
    return ok('伴侣档案已保存，共同时间已重算');
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
    return ok('已删除伴侣数据，回退单人模式');
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
    return ok('已保存，重启后仍保持');
  }

  // ---------- 云端配对（阶段 6R.2：开关关闭时这里是真边界，不是"AGC 恰好没配"） ----------

  /**
   * 配对相关的四个写动作共用这一句判断，且必须在**任何**副作用之前：
   * 不生成/读回 uid、不发云函数、不写 pairId/pairKey/pairState。
   *
   * 为什么不能靠"AGC 未配置所以调用必然抛错"来保证：换机、复用证书或误关联云工程之后，
   * 成功分支就会把 pairId 与配对态写进本机（验收报告 B1）。今天这条路径还多一重结构保险——
   * 长期密钥的写入 API 已经从 SettingsStore 删掉了，翻开关也复现不出"短码派生密钥存 Preferences"。
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

  /** 生成邀请码（创建方）：稳定 uid → pairing-create → 存 pairId → WAITING。关闭态一条请求都不发。 */
  static async createInvite(): Promise<InviteResult> {
    if (ProfileSettingsService.cloudBlocked()) {
      const blocked: InviteResult = { ok: false, code: '', message: FeatureFlags.cloudClosedMessage };
      return blocked;
    }
    try {
      const uid = await SettingsStore.getOrCreateUid();
      const session: PairingSession = await new AgcPairingClient().createPairing(uid);
      await SettingsStore.savePairId(session.sessionId);
      await SettingsStore.setPairState(PAIR_WAITING, '');
      const r: InviteResult = { ok: true, message: '配对码已生成，发给 TA 吧', code: session.code };
      return r;
    } catch (e) {
      Logger.warn(TAG, 'createPairing degraded: ' + (e as Error).message);
      const r: InviteResult = { ok: false, code: '', message: FeatureFlags.cloudClosedMessage };
      return r;
    }
  }

  /** 输码加入（加入方）：关闭态直接拒；开启后配对码无效/云端未开通统一失败提示，页面只 toast。 */
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
      const session: PairingSession = await new AgcPairingClient().joinPairing(code, uid);
      await SettingsStore.savePairId(session.sessionId);
      await SettingsStore.setPairState(PAIRED, '');
    } catch (e) {
      Logger.warn(TAG, 'joinPairing degraded: ' + (e as Error).message);
      return fail('加入失败：云端配对暂未开放或配对码无效');
    }
    ScheduleUseCase.onScheduleChanged().catch(() => {
    });
    return ok('配对成功，班表将按隐私等级加密同步');
  }

  /**
   * 创建方确认完成配对：只在云端真的接通后才有意义。
   * 关闭态必须拒——写进库的 PAIRED 在界面上就是"正在同步"那句谎（TC §9.5 的偏离口径）。
   */
  static async markPaired(): Promise<SettingsResult> {
    if (ProfileSettingsService.cloudBlocked()) {
      return fail(FeatureFlags.cloudClosedMessage);
    }
    try {
      await SettingsStore.setPairState(PAIRED, '');
    } catch (e) {
      return fail('操作失败：' + (e as Error).message);
    }
    ScheduleUseCase.onScheduleChanged().catch(() => {
    });
    return ok('已进入配对模式，班表变更将加密同步');
  }

  /** 取消等待中的配对：只清配对标记，不动本机代录数据。 */
  static async cancelWaiting(): Promise<void> {
    try {
      await SettingsStore.savePairId('');
      await SettingsStore.clearPairKey();
      await SettingsStore.setPartnerSnapVer(0);
      await SettingsStore.setPairState(PAIR_NONE, '');
    } catch (e) {
      Logger.warn(TAG, 'cancelWaiting degraded: ' + (e as Error).message);
    }
  }

  /**
   * 解除配对：本地配对标记/密钥残留/对方快照游标一律清干净；云端解绑只在开关打开时才发。
   *
   * 注意这条**不受关闭态拒绝**：上一版原型可能在本机留下 PAIRED 与 pair_key，而云入口已经藏起来了，
   * 用户必须还能亲手撤掉这些标记，否则界面会一直挂着"已配对"。「开关只关能力，不关数据」。
   */
  static async unpair(): Promise<SettingsResult> {
    try {
      if (FeatureFlags.cloudPairing) {
        try {
          await new AgcPairingClient().unpair(SettingsStore.getPairId(), await SettingsStore.getOrCreateUid());
        } catch (e) {
          Logger.warn(TAG, 'unpair cloud degraded: ' + (e as Error).message);
        }
      }
      await SettingsStore.savePairId('');
      await SettingsStore.clearPairKey();
      await SettingsStore.setPartnerSnapVer(0);
      await SettingsStore.setPairState(PAIR_NONE, '');
    } catch (e) {
      return fail('操作失败：' + (e as Error).message);
    }
    ScheduleUseCase.onScheduleChanged().catch(() => {
    });
    return ok('已解除配对');
  }

  // ---------- 清空数据 ----------

  /**
   * 清空 8 张 RDB 表 + 全部设置；隐私同意标记保留，避免重启后重复弹窗。
   *
   * 清库之前先把系统侧的东西一起带走（验收报告 B2）：计划级日历日程、计划级提醒、周报提醒，
   * 再整本清掉应用专属「同休日」日历作兜底（句柄丢了的那些日程也一并删掉）。
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
      const weeklyId = await SettingsStore.getWeeklyReminderId();
      if (weeklyId >= 0 && !await PlanCapabilities.reminder().cancel(weeklyId)) {
        report.remindersPending = report.remindersPending + 1;
      }
    } catch (e) {
      // 系统侧清不动也要把本机表清掉：数据在用户设备上，本机那份是能立刻收回的
      Logger.warn(TAG, 'clearAllData projection cleanup degraded: ' + (e as Error).message);
      calendarPurged = false;
    }
    try {
      const privacyWas = SettingsStore.isPrivacyAccepted();
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
