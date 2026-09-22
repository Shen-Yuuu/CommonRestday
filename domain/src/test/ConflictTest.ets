import { describe, it, expect } from '@ohos/hypium';
import {
  ConflictHint, ConflictOutcome, ConflictSources, CONFLICT_REASON_MIXED, CONFLICT_REASON_MY_COURSE,
  CONFLICT_REASON_MY_RHYTHM, CONFLICT_REASON_MY_SHIFT, CONFLICT_REASON_PARTNER_CHANGED,
  CONFLICT_REASON_PARTNER_TIME, CONFLICT_REASON_UNKNOWN, CONFLICT_SOURCE_BOTH, CONFLICT_SOURCE_MINE,
  CONFLICT_SOURCE_PARTNER, Interval, MIN_PER_DAY, PlanLite, Window, WindowChannel
} from '../main/ets/model/Types';
import { epochDayOf } from '../main/ets/utils/TimeUtil';
import { mkIv, unionIntervals } from '../main/ets/merge/IntervalOps';
import {
  decodeConflictHint, detectConflicts, encodeConflictHint, findAlternativeWindow, hintFromOutcome,
  withKeepCarried
} from '../main/ets/conflict/PlanConflict';

function mkPlan(id: string, start: number, end: number): PlanLite {
  const p: PlanLite = { id: id, startMin: start, endMin: end };
  return p;
}

function mkWin(start: number, dur: number): Window {
  const w: Window = { start: start, end: start + dur, durationMin: dur, tags: [], channel: WindowChannel.REGULAR };
  return w;
}

export default function conflictTest() {
  describe('planConflict', () => {
    const mon = epochDayOf(2026, 9, 14); // 周一
    const base = mon * MIN_PER_DAY;

    it('conflict_when_overlap', 0, () => {
      // 计划 19:00–21:30，新课程 19:30–21:00 与之交叠
      const plan = mkPlan('p1', base + 1140, base + 1290);
      const busy: Interval[] = [mkIv(base + 1170, base + 1260, 'COURSE')];
      const r = detectConflicts([plan], busy, []);
      expect(r.length).assertEqual(1);
      expect(r[0].planId).assertEqual('p1');
      expect(r[0].conflict).assertTrue();
    });

    it('boundary_touch_not_conflict', 0, () => {
      // 忙区间起点 == 计划终点 / 终点 == 计划起点（半开区间相接，不算冲突）
      const plan = mkPlan('p1', base + 1140, base + 1290);
      const busy: Interval[] = [
        mkIv(base + 1290, base + 1380, 'COURSE'),
        mkIv(base + 600, base + 1140, 'COURSE')
      ];
      const r = detectConflicts([plan], busy, []);
      expect(r[0].conflict).assertFalse();
    });

    it('no_conflict_when_disjoint', 0, () => {
      const plan = mkPlan('p1', base + 1140, base + 1290);
      const busy: Interval[] = [mkIv(base + 600, base + 900, 'COURSE')];
      const r = detectConflicts([plan], busy, []);
      expect(r[0].conflict).assertFalse();
      expect(r[0].alternativeStartMin).assertEqual(0);
      expect(r[0].alternativeEndMin).assertEqual(0);
    });

    it('alternative_picks_closest_duration_and_later_start', 0, () => {
      // 计划 19:00–20:30（90min），冲突后应推荐时长最接近（≥90）且起点更晚的窗口
      const plan = mkPlan('p1', base + 1140, base + 1230);
      const busy: Interval[] = [mkIv(base + 1140, base + 1230, 'COURSE')];
      const windows: Window[] = [
        mkWin(base + 600, 91),   // 起点早于计划 → 忽略
        mkWin(base + 1300, 180), // 时长差 90
        mkWin(base + 1380, 95),  // 时长差 5 ← 期望
        mkWin(base + 1320, 100), // 时长差 10
        mkWin(base + 1400, 60)   // 时长不足 → 忽略
      ];
      const r = detectConflicts([plan], busy, windows);
      expect(r[0].conflict).assertTrue();
      expect(r[0].alternativeStartMin).assertEqual(base + 1380);
      expect(r[0].alternativeEndMin).assertEqual(base + 1380 + 95);
      // 直接验证排序函数：w3 最接近
      const alt = findAlternativeWindow(plan, windows);
      expect(alt != null).assertTrue();
      expect((alt as Window).durationMin).assertEqual(95);
    });

    it('no_alternative_returns_zero', 0, () => {
      const plan = mkPlan('p1', base + 1140, base + 1290); // 150min
      const busy: Interval[] = [mkIv(base + 1140, base + 1290, 'COURSE')];
      const windows: Window[] = [
        mkWin(base + 600, 200),   // 起点早于计划
        mkWin(base + 1300, 100),  // 时长不足
        mkWin(base + 1400, 149)   // 时长不足
      ];
      const r = detectConflicts([plan], busy, windows);
      expect(r[0].conflict).assertTrue();
      expect(r[0].alternativeStartMin).assertEqual(0);
      expect(r[0].alternativeEndMin).assertEqual(0);
    });

    it('plan_plan_overlap_alone_not_conflict', 0, () => {
      // busyUnion 由调用方排除计划自身占用：两个计划互相交叠但无班表冲突 → 均不冲突
      const plans: PlanLite[] = [
        mkPlan('a', base + 1140, base + 1290),
        mkPlan('b', base + 1200, base + 1350)
      ];
      const busy: Interval[] = [];
      const r = detectConflicts(plans, busy, []);
      expect(r.length).assertEqual(2);
      expect(r[0].conflict).assertFalse();
      expect(r[1].conflict).assertFalse();
    });

    it('reason_follows_my_interval_tag_and_clips_affected_range', 0, () => {
      // 计划 19:00–21:30，我的课 19:30–21:00：受影响区间是交叠那一段，不是整条计划
      const plan = mkPlan('p1', base + 1140, base + 1290);
      const busy: Interval[] = [mkIv(base + 1170, base + 1260, 'COURSE')];
      const courseSrc: ConflictSources = { my: busy, partner: null };
      const mine = detectConflicts([plan], busy, [], courseSrc)[0];
      expect(mine.reasonCode).assertEqual(CONFLICT_REASON_MY_COURSE);
      expect(mine.sourceLevel).assertEqual(CONFLICT_SOURCE_MINE);
      expect(mine.overlapStartMin).assertEqual(base + 1170);
      expect(mine.overlapEndMin).assertEqual(base + 1260);

      const shift: Interval[] = [mkIv(base + 1140, base + 1290, 'WORK')];
      const shiftSrc: ConflictSources = { my: shift, partner: null };
      expect(detectConflicts([plan], shift, [], shiftSrc)[0].reasonCode)
        .assertEqual(CONFLICT_REASON_MY_SHIFT);
      // 作息段（睡眠/起床边界）既不是课也不是班
      const sleep: Interval[] = [mkIv(base + 1200, base + 1230, 'SLEEP')];
      const sleepSrc: ConflictSources = { my: sleep, partner: null };
      expect(detectConflicts([plan], sleep, [], sleepSrc)[0].reasonCode)
        .assertEqual(CONFLICT_REASON_MY_RHYTHM);
    });

    it('coarse_partner_data_never_gets_a_shift_explanation', 0, () => {
      // L1/L2 位图解码出来标签全是 BUSY：这种数据里睡眠和班次分不开，只能报"对方时间发生变化"
      const plan = mkPlan('p1', base + 1140, base + 1290);
      const coarse: Interval[] = [mkIv(base + 1150, base + 1200, 'BUSY')];
      const coarseSrc: ConflictSources = { my: [], partner: coarse };
      const r = detectConflicts([plan], coarse, [], coarseSrc)[0];
      expect(r.conflict).assertTrue();
      expect(r.reasonCode).assertEqual(CONFLICT_REASON_PARTNER_CHANGED);
      expect(r.sourceLevel).assertEqual(CONFLICT_SOURCE_PARTNER);

      // 对方共享到 L3（或本机代录）才带得出班次语义
      const detail: Interval[] = [mkIv(base + 1150, base + 1200, 'WORK')];
      const detailSrc: ConflictSources = { my: [], partner: detail };
      expect(detectConflicts([plan], detail, [], detailSrc)[0].reasonCode)
        .assertEqual(CONFLICT_REASON_PARTNER_TIME);
    });

    it('both_sides_report_mixed_and_omit_reason_when_sources_absent', 0, () => {
      const plan = mkPlan('p1', base + 1140, base + 1290);
      const mine: Interval[] = [mkIv(base + 1140, base + 1200, 'COURSE')];
      const partner: Interval[] = [mkIv(base + 1230, base + 1260, 'BUSY')];
      const bothSrc: ConflictSources = { my: mine, partner: partner };
      const union = unionIntervals(mine, partner);
      const both = detectConflicts([plan], union, [], bothSrc)[0];
      expect(both.reasonCode).assertEqual(CONFLICT_REASON_MIXED);
      expect(both.sourceLevel).assertEqual(CONFLICT_SOURCE_BOTH);
      // 受影响区间给交叠更大的一侧（60min 的课 vs 30min 的对方段）
      expect(both.overlapStartMin).assertEqual(base + 1140);
      expect(both.overlapEndMin).assertEqual(base + 1200);

      // 没带 sources 的调用（含 Task 2.3 之前的口径）：冲突照样判，但不归因、不猜
      const blind = detectConflicts([plan], union, [])[0];
      expect(blind.conflict).assertTrue();
      expect(blind.reasonCode).assertEqual(CONFLICT_REASON_UNKNOWN);
      expect(blind.overlapStartMin).assertEqual(0);
    });

    it('hint_round_trips_and_still_reads_legacy_format', 0, () => {
      const oc: ConflictOutcome = {
        planId: 'p1', conflict: true,
        alternativeStartMin: base + 1300, alternativeEndMin: base + 1395,
        reasonCode: CONFLICT_REASON_MY_COURSE, sourceLevel: CONFLICT_SOURCE_MINE,
        overlapStartMin: base + 1170, overlapEndMin: base + 1260
      };
      const h = hintFromOutcome(oc, false);
      const back = decodeConflictHint(encodeConflictHint(h));
      expect(back != null).assertTrue();
      const got = back as ConflictHint;
      expect(got.reasonCode).assertEqual(CONFLICT_REASON_MY_COURSE);
      expect(got.altStartMin).assertEqual(base + 1300);
      expect(got.altEndMin).assertEqual(base + 1395);
      expect(got.kept).assertFalse();

      // 旧格式（Task 2.3 之前只存替代窗口）：认得出窗口，原因码留空而不是编一个
      const legacy = decodeConflictHint('{"altStart":' + (base + 1300) + ',"altEnd":' + (base + 1395) + '}');
      expect(legacy != null).assertTrue();
      expect((legacy as ConflictHint).reasonCode).assertEqual(CONFLICT_REASON_UNKNOWN);
      expect((legacy as ConflictHint).altStartMin).assertEqual(base + 1300);

      expect(decodeConflictHint('')).assertNull();
      expect(decodeConflictHint('not json')).assertNull();
      expect(decodeConflictHint('{}')).assertNull();
    });

    it('keep_flag_only_carries_over_the_same_conflict', 0, () => {
      const acknowledged: ConflictOutcome = {
        planId: 'p1', conflict: true, alternativeStartMin: base + 1300, alternativeEndMin: base + 1395,
        reasonCode: CONFLICT_REASON_MY_COURSE, sourceLevel: CONFLICT_SOURCE_MINE,
        overlapStartMin: base + 1170, overlapEndMin: base + 1260
      };
      const prev = decodeConflictHint(encodeConflictHint(hintFromOutcome(acknowledged, true))) as ConflictHint;

      // 同一条冲突（原因 + 受影响区间都没变）：用户那句"保留原计划"继续有效
      const same = hintFromOutcome(acknowledged, false);
      expect(withKeepCarried(same, prev).kept).assertTrue();

      // 受影响区间变了 = 日程又动了一次 = 新冲突，得重新问
      const moved: ConflictOutcome = {
        planId: 'p1', conflict: true, alternativeStartMin: 0, alternativeEndMin: 0,
        reasonCode: CONFLICT_REASON_MY_COURSE, sourceLevel: CONFLICT_SOURCE_MINE,
        overlapStartMin: base + 1170, overlapEndMin: base + 1290
      };
      expect(withKeepCarried(hintFromOutcome(moved, false), prev).kept).assertFalse();

      // 归因换到对方身上，同样是新冲突
      const other: ConflictOutcome = {
        planId: 'p1', conflict: true, alternativeStartMin: 0, alternativeEndMin: 0,
        reasonCode: CONFLICT_REASON_PARTNER_CHANGED, sourceLevel: CONFLICT_SOURCE_PARTNER,
        overlapStartMin: base + 1170, overlapEndMin: base + 1260
      };
      expect(withKeepCarried(hintFromOutcome(other, false), prev).kept).assertFalse();
      expect(withKeepCarried(same, null).kept).assertFalse();
    });
  });
}
