import { ConflictOutcome, Interval, PlanLite, Window } from '../model/Types';
import { overlapMin } from '../merge/IntervalOps';

/**
 * 计划冲突检测（PRD F7 / 技术文档 6.2）：
 * - busyUnion 为"排除所有计划自身占用后"的双方忙区间并集（由调用方构建）；
 * - 计划与 busyUnion 任一区间交叠 > 0（半开区间，边界相接不算）→ 冲突；
 * - 冲突计划在 windows 中找替代窗口：起点晚于计划起点、时长 ≥ 计划时长、时长最接近者优先；
 * - 纯函数、零 Kit 依赖；回写 plan 状态由 feature 编排层负责。
 */

/** 检测全部计划的冲突状态并推荐替代窗口。 */
export function detectConflicts(plans: PlanLite[], busyUnion: Interval[], windows: Window[]): ConflictOutcome[] {
  const out: ConflictOutcome[] = [];
  for (let i = 0; i < plans.length; i++) {
    const plan = plans[i];
    let conflict = false;
    for (let j = 0; j < busyUnion.length; j++) {
      if (overlapMin(plan.startMin, plan.endMin, busyUnion[j].start, busyUnion[j].end) > 0) {
        conflict = true;
        break;
      }
    }
    const alt: Window | null = conflict ? findAlternativeWindow(plan, windows) : null;
    const r: ConflictOutcome = {
      planId: plan.id,
      conflict: conflict,
      alternativeStartMin: alt != null ? alt.start : 0,
      alternativeEndMin: alt != null ? alt.end : 0
    };
    out.push(r);
  }
  return out;
}

/**
 * 替代窗口：在 windows 中选 startMin > plan.startMin 且时长 ≥ 计划时长的窗口里，
 * 时长与计划时长最接近者；无满足条件的窗口返回 null。
 */
export function findAlternativeWindow(plan: PlanLite, windows: Window[]): Window | null {
  const need = plan.endMin - plan.startMin;
  let best: Window | null = null;
  let bestDiff = -1;
  for (let i = 0; i < windows.length; i++) {
    const w = windows[i];
    if (w.start <= plan.startMin || w.durationMin < need) {
      continue;
    }
    const diff = w.durationMin - need;
    if (best == null || diff < bestDiff) {
      best = w;
      bestDiff = diff;
    }
  }
  return best;
}
