import { EngineParams, Interval, MIN_PER_DAY, MySchedule } from '../model/Types';
import { buildMyAvailability } from '../engine/CommonFreeEngine';
import { mergeIntervals, mkIv } from '../merge/IntervalOps';
import { SnapshotData } from './SnapshotCodec';

const SLOT = 30;

/**
 * 快照构建：把"我"的不可用时间按隐私等级降维为快照明文。
 * 注意：无论何等级，睡眠/收整/恢复/课程都并入"忙"，保证 L1 也能正确参与共同空闲计算。
 */
export class SnapshotBuilder {
  static build(my: MySchedule, params: EngineParams, startEpochDay: number,
    shareLevel: number, version: number): SnapshotData {
    const days = Math.max(1, Math.min(params.horizonDays, 366));
    const avail = buildMyAvailability(my, params, startEpochDay, days);
    const merged = mergeIntervals(avail.notAvailable);

    if (shareLevel === 3) {
      const data: SnapshotData = {
        version: version,
        shareLevel: shareLevel,
        startEpochDay: startEpochDay,
        days: days,
        busy30: new Array<boolean>(0),
        segments: merged
      };
      return data;
    }

    // L1/L2：位图
    const bitsLen = days * (MIN_PER_DAY / SLOT);
    const busy30: boolean[] = new Array<boolean>(bitsLen);
    for (let i = 0; i < bitsLen; i++) {
      busy30[i] = false;
    }
    const base = startEpochDay * MIN_PER_DAY;
    for (let i = 0; i < merged.length; i++) {
      const iv = merged[i];
      const fromSlot = Math.max(0, Math.floor((iv.start - base) / SLOT));
      const toSlot = Math.min(bitsLen, Math.ceil((iv.end - base) / SLOT));
      for (let s = fromSlot; s < toSlot; s++) {
        if (s >= 0 && s < bitsLen) {
          busy30[s] = true;
        }
      }
    }

    if (shareLevel === 1) {
      const data: SnapshotData = {
        version: version,
        shareLevel: shareLevel,
        startEpochDay: startEpochDay,
        days: days,
        busy30: busy30,
        segments: []
      };
      return data;
    }

    // L2：量化分段（start 向下取整、end 向上取整，宁可多算忙）
    const quant: Interval[] = [];
    for (let i = 0; i < merged.length; i++) {
      const iv = merged[i];
      const qs = Math.floor(iv.start / SLOT) * SLOT;
      const qe = Math.ceil(iv.end / SLOT) * SLOT;
      quant.push(mkIv(qs, qe, iv.tag));
    }
    const data2: SnapshotData = {
      version: version,
      shareLevel: shareLevel,
      startEpochDay: startEpochDay,
      days: days,
      busy30: busy30,
      segments: mergeIntervals(quant)
    };
    return data2;
  }
}
