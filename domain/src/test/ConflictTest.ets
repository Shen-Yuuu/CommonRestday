import { describe, it, expect } from '@ohos/hypium';
import { Interval, MIN_PER_DAY, PlanLite, Window } from '../main/ets/model/Types';
import { epochDayOf } from '../main/ets/utils/TimeUtil';
import { mkIv } from '../main/ets/merge/IntervalOps';
import { detectConflicts, findAlternativeWindow } from '../main/ets/conflict/PlanConflict';

function mkPlan(id: string, start: number, end: number): PlanLite {
  const p: PlanLite = { id: id, startMin: start, endMin: end };
  return p;
}

function mkWin(start: number, dur: number): Window {
  const w: Window = { start: start, end: start + dur, durationMin: dur, tags: [] };
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
  });
}
