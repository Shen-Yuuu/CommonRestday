import { Course, CycleTemplate, ScheduleOverride, SectionTime, ShiftType } from 'domain';
import { PAIRED, ScheduleRepo, SettingsStore } from 'data';
import { Logger } from 'commons';
import { LABEL_SAVE_FLOW, RecomputeExecutor } from '../performance/RecomputeExecutor';
import { ScheduleUseCase } from './ScheduleUseCase';

const TAG = 'ScheduleCommandService';

/**
 * 写操作统一结果，页面据此提示，不再自行决定"保存后还要不要重算"。
 * - changed：确实执行了一次写入（空批次为 false，也不触发重算）；
 * - recomputed：共同时间是否已完成那一次重算（写入成功但重算失败时为 false）；
 * - syncQueued：已配对时快照推送是否已排队（由 onScheduleChanged 负责，不重复推）。
 * errorCode：WRITE_FAILED（含事务回滚）/ RECOMPUTE_FAILED / 空串表示正常。
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

/** 空批次：写入没有发生，重算也不该被无谓触发。 */
function noop(): ScheduleCommandResult {
  return result(true, false, false, false, '');
}

/**
 * 班表写入的唯一入口：任何一次用户保存 = 一次写入 + 一次重算 + 一次广播。
 * 页面只负责收集输入和展示结果，不再直连 ScheduleRepo，也不再自己 catch 重算。
 */
export class ScheduleCommandService {
  // ---------- 单日覆盖 ----------

  /** 某一天改班：shiftTypeId 传 null 表示"这天强制休息"（与覆盖表语义一致）。 */
  static async setDayShift(epochDay: number, shiftTypeId: string | null,
    owner: string): Promise<ScheduleCommandResult> {
    const ov: ScheduleOverride = { epochDay: epochDay, shiftTypeId: shiftTypeId };
    return await ScheduleCommandService.run(async (): Promise<void> => {
      await ScheduleRepo.upsertOverride(ov, '', owner);
    });
  }

  /** 清除某一天的覆盖，回到循环模板推算值。 */
  static async clearDayShift(epochDay: number, owner: string): Promise<ScheduleCommandResult> {
    return await ScheduleCommandService.run(async (): Promise<void> => {
      await ScheduleRepo.deleteOverride(epochDay, owner);
    });
  }

  /**
   * 月历涂抹的一次冲刷：整批删除 + 整批覆盖放进同一条事务，失败整批回滚后重试即可。
   * deletes 与 overrides 同一天同时出现时按"先删后写"顺序处理，最终态以 overrides 为准。
   */
  static async paintDays(deletes: number[], overrides: ScheduleOverride[],
    owner: string): Promise<ScheduleCommandResult> {
    if (deletes.length === 0 && overrides.length === 0) {
      return noop();
    }
    return await ScheduleCommandService.run(async (): Promise<void> => {
      await ScheduleRepo.runInTransaction(async (): Promise<void> => {
        for (let i = 0; i < deletes.length; i++) {
          await ScheduleRepo.deleteOverride(deletes[i], owner);
        }
        for (let i = 0; i < overrides.length; i++) {
          await ScheduleRepo.upsertOverride(overrides[i], '', owner);
        }
      });
    });
  }

  // ---------- 班次类型 ----------

  static async saveShiftType(st: ShiftType, owner: string): Promise<ScheduleCommandResult> {
    return await ScheduleCommandService.run(async (): Promise<void> => {
      await ScheduleRepo.upsertShiftType(st, owner);
    });
  }

  static async removeShiftType(id: string, owner: string): Promise<ScheduleCommandResult> {
    return await ScheduleCommandService.run(async (): Promise<void> => {
      await ScheduleRepo.deleteShiftType(id, owner);
    });
  }

  // ---------- 循环模板 ----------

  static async saveTemplate(tpl: CycleTemplate, owner: string): Promise<ScheduleCommandResult> {
    return await ScheduleCommandService.run(async (): Promise<void> => {
      await ScheduleRepo.saveTemplate(tpl, owner);
    });
  }

  static async removeTemplate(owner: string): Promise<ScheduleCommandResult> {
    return await ScheduleCommandService.run(async (): Promise<void> => {
      await ScheduleRepo.deleteTemplate(owner);
    });
  }

  // ---------- 课程 ----------

  static async saveCourse(c: Course, owner: string): Promise<ScheduleCommandResult> {
    return await ScheduleCommandService.run(async (): Promise<void> => {
      await ScheduleRepo.upsertCourse(c, owner);
    });
  }

  static async removeCourse(id: string, owner: string): Promise<ScheduleCommandResult> {
    return await ScheduleCommandService.run(async (): Promise<void> => {
      await ScheduleRepo.deleteCourse(id, owner);
    });
  }

  /** 批量导入（文本解析 / 拍照识别）：整批一次事务、一次重算，避免每门课各算一遍。 */
  static async importCourses(list: Course[], owner: string): Promise<ScheduleCommandResult> {
    if (list.length === 0) {
      return noop();
    }
    return await ScheduleCommandService.run(async (): Promise<void> => {
      await ScheduleRepo.runInTransaction(async (): Promise<void> => {
        for (let i = 0; i < list.length; i++) {
          await ScheduleRepo.upsertCourse(list[i], owner);
        }
      });
    });
  }

  // ---------- 学期与节次 ----------

  /** 学期锚点 + 节次模板：两者共同决定课程展开，任一改完都要重算。times 为空时写默认模板。 */
  static async saveTerm(termStartEpochDay: number, times: SectionTime[]): Promise<ScheduleCommandResult> {
    const t: SectionTime[] = times.length === 0 ? ScheduleUseCase.defaultSectionTimes() : times;
    const json: string = ScheduleUseCase.sectionTimesToJson(t);
    return await ScheduleCommandService.run(async (): Promise<void> => {
      await ScheduleRepo.saveTermConfig(termStartEpochDay, json);
    });
  }

  // ---------- 内部收口 ----------

  /**
   * 一次写入 → 一次重算：写失败不碰重算，重算失败要说清"数据已落库、只是这一轮没刷新"。
   * 只给重算段计时（保存动作里唯一会随数据量变长的那一段），写入本身由 RDB 侧负责。
   */
  private static async run(write: () => Promise<void>): Promise<ScheduleCommandResult> {
    try {
      await write();
    } catch (e) {
      Logger.warn(TAG, 'write failed: ' + (e as Error).message);
      return result(false, false, false, false, 'WRITE_FAILED');
    }
    try {
      await RecomputeExecutor.measure(LABEL_SAVE_FLOW, async (): Promise<void> => {
        await ScheduleUseCase.onScheduleChanged();
      });
    } catch (e) {
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
