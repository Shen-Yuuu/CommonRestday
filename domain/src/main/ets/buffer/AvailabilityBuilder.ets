import { BlockTag, EngineParams, Interval, MIN_PER_DAY, ShiftInstance, ShiftType } from '../model/Types';
import { mkIv, mergeIntervals } from '../merge/IntervalOps';

/**
 * 缓冲层：把班次实例转换为忙碌块（含通勤），生成个人"不可用"区间。
 *
 * 规则（与 PRD F4 / 技术文档 5.1 一致）：
 * 1. 班次核心时间 ± 前后通勤 → WORK 忙碌块；
 * 2. 夜班（核心时间与夜班窗口相交）结束（到家）后追加 RECOVERY 恢复块；
 * 3. 忙碌块尾部追加收整缓冲 windDownMin（忙→闲转换后才能进入可安排状态）；
 * 4. 每日 [00:00, wake) 与 [bed, 24:00) 为不可用（bed < wake 时视为跨零点）。
 */

/** 单个班次实例 → 忙碌块（WORK + 可能的 RECOVERY），不合并。 */
export function shiftToBlocks(inst: ShiftInstance, cfg: ShiftType, params: EngineParams): Interval[] {
  const base = inst.epochDay * MIN_PER_DAY;
  let endMin = cfg.endMin;
  if (cfg.crossDay || cfg.endMin <= cfg.startMin) {
    endMin += MIN_PER_DAY;
  }
  const s = base + cfg.startMin - cfg.commuteInMin;
  const workEnd = base + endMin;
  const e = workEnd + cfg.commuteOutMin;
  const blocks: Interval[] = [];
  blocks.push(mkIv(s, e, BlockTag.WORK));
  if (cfg.recoveryMin > 0 && isNightShift(inst, cfg, params)) {
    blocks.push(mkIv(e, e + cfg.recoveryMin, BlockTag.RECOVERY));
  }
  return blocks;
}

/** 夜班判定：班次核心时间（不含通勤）与夜班窗口相交。 */
export function isNightShift(inst: ShiftInstance, cfg: ShiftType, params: EngineParams): boolean {
  if (cfg.nightMode === 1) {
    return true;
  }
  if (cfg.nightMode === 2) {
    return false;
  }
  const base = inst.epochDay * MIN_PER_DAY;
  let endMin = cfg.endMin;
  if (cfg.crossDay || cfg.endMin <= cfg.startMin) {
    endMin += MIN_PER_DAY;
  }
  const workStart = base + cfg.startMin;
  const workEnd = base + endMin;
  // 夜窗长度：nightEnd <= nightStart（如 22:00–05:00）表示跨零点夜窗，从当日起点延伸到次日
  const nightLen = (params.nightEndMin - params.nightStartMin + MIN_PER_DAY) % MIN_PER_DAY;
  if (nightLen === 0) {
    return false; // 未配置夜窗
  }
  // 检查班次覆盖到的每个自然日的夜班窗口（跨零点夜窗需额外回看前一天开始的窗口）
  const firstDay = Math.floor(workStart / MIN_PER_DAY) - 1;
  const lastDay = Math.floor((workEnd - 1) / MIN_PER_DAY);
  for (let d = firstDay; d <= lastDay; d++) {
    const ns = d * MIN_PER_DAY + params.nightStartMin;
    const ne = ns + nightLen;
    if (workStart < ne && workEnd > ns) {
      return true;
    }
  }
  return false;
}

/**
 * 生成个人"不可用"区间：忙碌块（+收整缓冲）∪ 每日作息窗口外。
 * 这些区间求并后与对方区间合并、取补，即为共同空闲。
 */
export function buildNotAvailable(busyTrue: Interval[], wakeMin: number, bedMin: number,
  windDownMin: number, startEpochDay: number, days: number): Interval[] {
  const notAvail: Interval[] = [];
  // 忙碌块尾部加收整缓冲
  for (let i = 0; i < busyTrue.length; i++) {
    const iv = busyTrue[i];
    notAvail.push(mkIv(iv.start, iv.end + windDownMin, iv.tag));
  }
  // 每日作息窗口外
  const b = bedMin < wakeMin ? bedMin + MIN_PER_DAY : bedMin;
  for (let i = 0; i < days; i++) {
    const base = (startEpochDay + i) * MIN_PER_DAY;
    if (wakeMin > 0) {
      notAvail.push(mkIv(base, base + wakeMin, 'SLEEP'));
    }
    if (b < MIN_PER_DAY) {
      notAvail.push(mkIv(base + b, base + MIN_PER_DAY, 'SLEEP'));
    } else {
      // 跨零点的就寝时间：当天 bed→24:00 全部 + 次日 00:00→(bed-1440)
      notAvail.push(mkIv(base + Math.min(b, MIN_PER_DAY), base + MIN_PER_DAY, 'SLEEP'));
      // 边界取舍：视野最后一晚的跨零点延伸段已超出视野，不再加入不可用集
      if (i + 1 < days) {
        notAvail.push(mkIv((startEpochDay + i + 1) * MIN_PER_DAY, (startEpochDay + i + 1) * MIN_PER_DAY + (b - MIN_PER_DAY), 'SLEEP'));
      }
    }
  }
  return mergeIntervals(notAvail);
}
