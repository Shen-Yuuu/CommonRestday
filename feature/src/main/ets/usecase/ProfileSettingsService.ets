import { EngineParams, defaultParams, hhmmToMin, minToHHmm } from 'domain';
import {
  PAIRED, PAIR_NONE, PAIR_WAITING, PartnerProfile, ScheduleRepo, SettingsStore
} from 'data';
import { AgcPairingClient, PairingSession, SnapshotCrypto } from 'cloud';
import { reminderAgentManager } from '@kit.BackgroundTasksKit';
import { Logger } from 'commons';
import { ScheduleUseCase } from './ScheduleUseCase';
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

  // ---------- 云端配对（AGC 未就绪时全程降级，不影响本机代录） ----------

  static getPairState(): string {
    try {
      return SettingsStore.getPairState();
    } catch (e) {
      return PAIR_NONE;
    }
  }

  /** 生成邀请码（创建方）：稳定 uid → pairing-create → 存 pairId + 派生密钥 → WAITING。 */
  static async createInvite(): Promise<InviteResult> {
    try {
      const uid = await SettingsStore.getOrCreateUid();
      const session: PairingSession = await new AgcPairingClient().createPairing(uid);
      await SettingsStore.savePairId(session.sessionId);
      await SettingsStore.savePairKey(SnapshotCrypto.deriveKeyHex(session.code));
      await SettingsStore.setPairState(PAIR_WAITING, '');
      const r: InviteResult = { ok: true, message: '配对码已生成，发给 TA 吧', code: session.code };
      return r;
    } catch (e) {
      Logger.warn(TAG, 'createPairing degraded: ' + (e as Error).message);
      const r: InviteResult = {
        ok: false, code: '', message: '云端配对暂未开放（需开通 AGC 云服务），可先用本机代录'
      };
      return r;
    }
  }

  /** 输码加入（加入方）：配对码无效/云端未开通统一失败提示，页面只 toast。 */
  static async joinByCode(codeText: string): Promise<SettingsResult> {
    const code = codeText.trim();
    if (code.length !== 6 || Number.isNaN(Number(code))) {
      return fail('请输入对方分享的 6 位配对码');
    }
    try {
      const uid = await SettingsStore.getOrCreateUid();
      const session: PairingSession = await new AgcPairingClient().joinPairing(code, uid);
      await SettingsStore.savePairId(session.sessionId);
      await SettingsStore.savePairKey(SnapshotCrypto.deriveKeyHex(code));
      await SettingsStore.setPairState(PAIRED, '');
    } catch (e) {
      Logger.warn(TAG, 'joinPairing degraded: ' + (e as Error).message);
      return fail('加入失败：云端配对暂未开放或配对码无效');
    }
    ScheduleUseCase.onScheduleChanged().catch(() => {
    });
    return ok('配对成功，班表将按隐私等级加密同步');
  }

  /** 创建方确认完成配对（体验版：无服务端推送，对方输码后手动确认）。 */
  static async markPaired(): Promise<SettingsResult> {
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

  /** 解除配对：云端尽力解绑（失败忽略），本地配对标记/密钥/对方快照游标一律清干净。 */
  static async unpair(): Promise<SettingsResult> {
    try {
      const pairId = SettingsStore.getPairId();
      const uid = await SettingsStore.getOrCreateUid();
      try {
        await new AgcPairingClient().unpair(pairId, uid);
      } catch (e) {
        Logger.warn(TAG, 'unpair cloud degraded: ' + (e as Error).message);
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

  /** 清空 8 张 RDB 表 + 全部设置；隐私同意标记保留，避免重启后重复弹窗。 */
  static async clearAllData(): Promise<SettingsResult> {
    try {
      const weeklyId = await SettingsStore.getWeeklyReminderId();
      if (weeklyId >= 0) {
        try {
          await reminderAgentManager.cancelReminder(weeklyId);
        } catch (e) {
          // 提醒已被系统清理：取消失败可忽略
        }
      }
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
    return ok('已清空全部数据');
  }
}
