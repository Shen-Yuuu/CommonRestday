import {
  BlockTag, ConflictOutcome, ConflictSources, CONFLICT_REASON_MIXED, CONFLICT_REASON_MY_COURSE,
  CONFLICT_REASON_MY_RHYTHM, CONFLICT_REASON_MY_SHIFT, CONFLICT_REASON_PARTNER_CHANGED,
  CONFLICT_REASON_PARTNER_TIME, CONFLICT_REASON_UNKNOWN, CONFLICT_SOURCE_BOTH, CONFLICT_SOURCE_MINE,
  CONFLICT_SOURCE_PARTNER, Interval, PlanLite, Window
} from '../model/Types';
import { overlapMin } from '../merge/IntervalOps';

/**
 * 计划冲突检测（PRD F7 / 阶段 2 Task 2.3）：
 * - busyUnion 为"排除所有计划自身占用后"的双方忙区间并集（由调用方构建）；
 * - 计划与 busyUnion 任一区间交叠 > 0（半开区间，边界相接不算）→ 冲突；
 * - 冲突计划在 windows 中找替代窗口：起点晚于计划起点、时长 ≥ 计划时长、时长最接近者优先；
 * - 传 sources（分侧忙区间）时顺带归因：原因码 + 来源级别 + 受影响区间；
 *   对方只给粗粒度忙闲时归因到 PARTNER_CHANGED，绝不替对方说出具体班次；
 * - 纯函数、零 Kit 依赖；回写 plan 状态由 feature 编排层负责。
 */

/** 单侧最大交叠命中（内部归因用）。 */
interface OverlapHit {
  start: number;
  end: number;
  minutes: number;
  tag: string;
}

/** 归因结果。 */
interface Attribution {
  reasonCode: string;
  sourceLevel: string;
  overlapStartMin: number;
  overlapEndMin: number;
}

/** 检测全部计划的冲突状态、原因与替代窗口。sources 省略时只做交叠判定（原因码留空）。 */
export function detectConflicts(plans: PlanLite[], busyUnion: Interval[], windows: Window[],
  sources?: ConflictSources | null): ConflictOutcome[] {
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
    const at: Attribution = conflict ? attributeOf(plan, sources) : noneAttribution();
    const r: ConflictOutcome = {
      planId: plan.id,
      conflict: conflict,
      alternativeStartMin: alt != null ? alt.start : 0,
      alternativeEndMin: alt != null ? alt.end : 0,
      reasonCode: at.reasonCode,
      sourceLevel: at.sourceLevel,
      overlapStartMin: at.overlapStartMin,
      overlapEndMin: at.overlapEndMin
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

function noneAttribution(): Attribution {
  const a: Attribution = {
    reasonCode: CONFLICT_REASON_UNKNOWN, sourceLevel: CONFLICT_REASON_UNKNOWN,
    overlapStartMin: 0, overlapEndMin: 0
  };
  return a;
}

/** 分侧取最大交叠后归因；没带 sources 时不猜（原因码空串）。 */
function attributeOf(plan: PlanLite, sources?: ConflictSources | null): Attribution {
  if (sources == null) {
    return noneAttribution();
  }
  const my = maxOverlap(plan, sources.my);
  const partner = maxOverlap(plan, sources.partner);
  if (my != null && partner != null) {
    // 受影响区间给交叠更大的那一侧：改期要挪开的是最实在的那一段。
    return attribution(CONFLICT_REASON_MIXED, CONFLICT_SOURCE_BOTH, my.minutes >= partner.minutes ? my : partner);
  }
  if (my != null) {
    return attribution(myReasonOf(my.tag), CONFLICT_SOURCE_MINE, my);
  }
  if (partner != null) {
    // 位图快照的标签一律是 BUSY：这种数据里睡眠和班次分不开，说"TA 的班次"就是编造。
    const code = partner.tag === BlockTag.BUSY ? CONFLICT_REASON_PARTNER_CHANGED : CONFLICT_REASON_PARTNER_TIME;
    return attribution(code, CONFLICT_SOURCE_PARTNER, partner);
  }
  return noneAttribution();
}

function attribution(code: string, source: string, hit: OverlapHit): Attribution {
  const a: Attribution = {
    reasonCode: code, sourceLevel: source,
    overlapStartMin: hit.start, overlapEndMin: hit.end
  };
  return a;
}

/** 我的不可用区间 tag → 原因码；作息段（SLEEP）与无 tag 都归到"作息时段外"。 */
function myReasonOf(tag: string): string {
  if (tag === BlockTag.COURSE) {
    return CONFLICT_REASON_MY_COURSE;
  }
  if (tag === BlockTag.WORK || tag === BlockTag.RECOVERY) {
    return CONFLICT_REASON_MY_SHIFT;
  }
  return CONFLICT_REASON_MY_RHYTHM;
}

function maxOverlap(plan: PlanLite, ivs: Interval[] | null): OverlapHit | null {
  if (ivs == null) {
    return null;
  }
  let best: OverlapHit | null = null;
  for (let i = 0; i < ivs.length; i++) {
    const iv = ivs[i];
    const minutes = overlapMin(plan.startMin, plan.endMin, iv.start, iv.end);
    if (minutes <= 0) {
      continue;
    }
    if (best == null || minutes > best.minutes) {
      const hit: OverlapHit = {
        start: Math.max(plan.startMin, iv.start), end: Math.min(plan.endMin, iv.end),
        minutes: minutes, tag: iv.tag
      };
      best = hit;
    }
  }
  return best;
}

/** conflict_hint 的持久结构（列为 TEXT，内容按此编解码；UI 不再手拆 JSON）。 */
export interface ConflictHint {
  reasonCode: string;
  sourceLevel: string;
  overlapStartMin: number;
  overlapEndMin: number;
  altStartMin: number;
  altEndMin: number;
  /** 用户点过"保留原计划"：只在同一冲突签名下成立，安排再变则自动失效。 */
  kept: boolean;
}

/** 冲突签名：原因 + 受影响区间。区间或归因一变就是新冲突，"已保留"不再适用。 */
export function conflictSignature(h: ConflictHint): string {
  return h.reasonCode + '|' + h.overlapStartMin + '|' + h.overlapEndMin;
}

/** 检测结果 → 持久结构；kept 由调用方决定是否从上一条 hint 结转。 */
export function hintFromOutcome(oc: ConflictOutcome, kept: boolean): ConflictHint {
  const h: ConflictHint = {
    reasonCode: oc.reasonCode,
    sourceLevel: oc.sourceLevel,
    overlapStartMin: oc.overlapStartMin,
    overlapEndMin: oc.overlapEndMin,
    altStartMin: oc.alternativeStartMin,
    altEndMin: oc.alternativeEndMin,
    kept: kept
  };
  return h;
}

/**
 * "保留原计划"标记的结转：只有冲突签名（原因 + 受影响区间）没变才延续。
 * 日程又动了一次就是新冲突，不能拿上一次那句"算了"替用户决定。
 */
export function withKeepCarried(next: ConflictHint, prev: ConflictHint | null): ConflictHint {
  const kept = prev != null && prev.kept && conflictSignature(prev) === conflictSignature(next);
  const h: ConflictHint = {
    reasonCode: next.reasonCode,
    sourceLevel: next.sourceLevel,
    overlapStartMin: next.overlapStartMin,
    overlapEndMin: next.overlapEndMin,
    altStartMin: next.altStartMin,
    altEndMin: next.altEndMin,
    kept: kept
  };
  return h;
}

/** 持久结构 → conflict_hint 文本。 */
export function encodeConflictHint(h: ConflictHint): string {
  const o: Record<string, Object> = {
    'r': h.reasonCode, 's': h.sourceLevel,
    'os': h.overlapStartMin, 'oe': h.overlapEndMin,
    'as': h.altStartMin, 'ae': h.altEndMin, 'k': h.kept ? 1 : 0
  };
  return JSON.stringify(o);
}

/**
 * conflict_hint 文本 → 持久结构；空串/非法/旧格式都给出可用结果：
 * 旧格式（Task 2.3 之前写的 {"altStart":..,"altEnd":..}）只认得出替代窗口，原因码留空。
 */
export function decodeConflictHint(text: string): ConflictHint | null {
  if (text === '') {
    return null;
  }
  let o: Record<string, Object>;
  try {
    o = JSON.parse(text) as Record<string, Object>;
  } catch (e) {
    return null;
  }
  const h: ConflictHint = {
    reasonCode: strOf(o, 'r'),
    sourceLevel: strOf(o, 's'),
    overlapStartMin: numOf(o, 'os'),
    overlapEndMin: numOf(o, 'oe'),
    altStartMin: numOf(o, 'as') > 0 ? numOf(o, 'as') : numOf(o, 'altStart'),
    altEndMin: numOf(o, 'ae') > 0 ? numOf(o, 'ae') : numOf(o, 'altEnd'),
    kept: numOf(o, 'k') === 1
  };
  if (h.altStartMin <= 0 && h.overlapStartMin <= 0 && h.reasonCode === '') {
    return null;
  }
  return h;
}

function strOf(o: Record<string, Object>, key: string): string {
  const v = o[key];
  return typeof v === 'string' ? v as string : '';
}

function numOf(o: Record<string, Object>, key: string): number {
  const v = o[key];
  return typeof v === 'number' ? v as number : 0;
}
