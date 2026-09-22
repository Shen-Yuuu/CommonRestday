import { ScheduleOverride } from 'domain';
import { PAIRED, ScheduleRepo, SettingsStore } from 'data';
import { Logger } from 'commons';
import { ScheduleUseCase } from './ScheduleUseCase';

const TAG = 'ScheduleCommandService';

/**
 * 写操作统一结果，页面据此提示，不再自行决定"保存后还要不要重算"。
 * - changed：确实执行了一次写入；
 * - recomputed：共同时间是否已完成那一次重算（写入成功但重算失败时为 false）；
 * - syncQueued：已配对时快照推送是否已排队（由 onScheduleChanged 负责，不重复推）。
 */
export interface ScheduleCommandResult {
  ok: boolean;
  changed: boolean;
  recomputed: boolean;
  syncQueued: boolean;
  errorCode: string;
}

function result(ok: boolean, changed: boolean, recomputed: boolean,
  syncQueued: boolean, errorCode: string): ScheduleCommandResult {
  const r: ScheduleCommandResult = {
    ok: ok, changed: changed, recomputed: recomputed, syncQueued: syncQueued, errorCode: errorCode
  };
  return r;
}

/**
 * 班表写入命令：单次写入 + 单次重算 + 广播，全部收口在这里。
 * 阶段 1R 先承接「临时调整」单日覆盖；其余录入页随阶段 2 逐步接入。
 */
export class ScheduleCommandService {
  /** 某一天改班：shiftTypeId 传 null 表示"这天强制休息"（与覆盖表语义一致）。 */
  static async setDayShift(epochDay: number, shiftTypeId: string | null,
    owner: string): Promise<ScheduleCommandResult> {
    const ov: ScheduleOverride = { epochDay: epochDay, shiftTypeId: shiftTypeId };
    try {
      await ScheduleRepo.upsertOverride(ov, '', owner);
    } catch (e) {
      return ScheduleCommandService.writeFailed(e);
    }
    return await ScheduleCommandService.afterWrite();
  }

  /** 清除某一天的覆盖，回到循环模板推算值。 */
  static async clearDayShift(epochDay: number, owner: string): Promise<ScheduleCommandResult> {
    try {
      await ScheduleRepo.deleteOverride(epochDay, owner);
    } catch (e) {
      return ScheduleCommandService.writeFailed(e);
    }
    return await ScheduleCommandService.afterWrite();
  }

  private static writeFailed(e: Object): ScheduleCommandResult {
    Logger.warn(TAG, 'write failed: ' + (e as Error).message);
    return result(false, false, false, false, 'WRITE_FAILED');
  }

  /** 写入成功后的统一收口：重算 + recomputeCount 广播 + 配对态快照推送。 */
  private static async afterWrite(): Promise<ScheduleCommandResult> {
    try {
      await ScheduleUseCase.onScheduleChanged();
    } catch (e) {
      // 数据已落库，只是这一轮共同时间没刷新：说清状态，别让页面以为整笔操作失败
      Logger.warn(TAG, 'recompute after write failed: ' + (e as Error).message);
      return result(false, true, false, false, 'RECOMPUTE_FAILED');
    }
    return result(true, true, true, ScheduleCommandService.isPaired(), '');
  }

  private static isPaired(): boolean {
    try {
      return SettingsStore.getPairState() === PAIRED;
    } catch (e) {
      return false;
    }
  }
}
