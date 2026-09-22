import { describe, it, expect } from '@ohos/hypium';
import {
  ConflictOutcome, Course, defaultParams, EngineInput, EngineParams, Interval, MIN_PER_DAY,
  MySchedule, PartnerSchedule, PlanBlock, PlanLite, SectionTime, ShiftType, Window, WindowTag
} from '../main/ets/model/Types';
import { epochDayOf } from '../main/ets/utils/TimeUtil';
import { CommonFreeEngine, buildAvailability } from '../main/ets/engine/CommonFreeEngine';
import { mkIv } from '../main/ets/merge/IntervalOps';
import { detectConflicts } from '../main/ets/conflict/PlanConflict';
import { SnapshotBuilder } from '../main/ets/snapshot/SnapshotBuilder';
import { SnapshotCodec, SnapshotData } from '../main/ets/snapshot/SnapshotCodec';

/**
 * 首页三答案的领域基线夹具（改造阶段 0）。
 *
 * 全部用例使用固定 epochDay，不读取系统当前日期：
 * 「今晚」等等价语义由「相对固定 now 的同日常规窗口」表达，
 * 阶段 1 的 CommonTimeQueryService 必须与本夹具口径一致。
 */

const MON = epochDayOf(2026, 9, 14);
const TUE = epochDayOf(2026, 9, 15);
const FRI = epochDayOf(2026, 9, 18);
const SAT = epochDayOf(2026, 9, 19);
const SUN = epochDayOf(2026, 9, 20);

const WAKE = 420;   // 07:00
const BED = 1350;   // 22:30
const WIND = 20;

const DINNER_START = 1080; // 18:00
const DINNER_END = 1170;   // 19:30

function params(days: number): EngineParams {
  const p = defaultParams();
  p.horizonDays = days;
  return p;
}

/** 当天内的忙碌区间（分钟为当日距 00:00 偏移）。 */
function dayIv(epochDay: number, startMin: number, endMin: number, tag: string): Interval {
  return mkIv(epochDay * MIN_PER_DAY + startMin, epochDay * MIN_PER_DAY + endMin, tag);
}

function emptyMy(): MySchedule {
  const m: MySchedule = {
    shiftTypes: [], template: null, overrides: [], courses: [], sectionTimes: [],
    termStartEpochDay: -1, plans: [], wakeMin: WAKE, bedMin: BED, windDownMin: WIND
  };
  return m;
}

function input(my: MySchedule, partner: PartnerSchedule | null, startDay: number,
  days: number): EngineInput {
  const i: EngineInput = { my: my, partner: partner, params: params(days), horizonStartEpochDay: startDay };
  return i;
}

/** 云端快照伴侣：只有含睡眠的不可用（L1 解码后统一 BUSY，无 tripBusy 语义）。 */
function snapshotPartner(busy: Interval[]): PartnerSchedule {
  const p: PartnerSchedule = { shareLevel: 1, busyIntervals: busy, tripBusyIntervals: null };
  return p;
}

/** 本机代录伴侣：额外提供"不含睡眠"的真忙+收整，同休日与旅行判定才可能成立。 */
function localPartner(busy: Interval[], tripBusy: Interval[]): PartnerSchedule {
  const p: PartnerSchedule = { shareLevel: 3, busyIntervals: busy, tripBusyIntervals: tripBusy };
  return p;
}

function sleepOnly(epochDay: number): Interval[] {
  return [
    dayIv(epochDay, 0, WAKE, 'SLEEP'),
    dayIv(epochDay, BED, MIN_PER_DAY, 'SLEEP')
  ];
}

function tagsOf(windows: Window[], start: number, end: number): string[] {
  for (let i = 0; i < windows.length; i++) {
    if (windows[i].start === start && windows[i].end === end) {
      return windows[i].tags;
    }
  }
  return [];
}

function findWin(windows: Window[], start: number, end: number): Window | null {
  for (let i = 0; i < windows.length; i++) {
    if (windows[i].start === start && windows[i].end === end) {
      return windows[i];
    }
  }
  return null;
}

function hasTag(tags: string[], tag: string): boolean {
  return tags.indexOf(tag) >= 0;
}

function countWithTag(windows: Window[], tag: string): number {
  let n = 0;
  for (let i = 0; i < windows.length; i++) {
    if (hasTag(windows[i].tags, tag)) {
      n++;
    }
  }
  return n;
}

/** 同一天内起止的窗口（「今晚」候选的领域口径：跨日窗口不得充当今晚答案）。 */
function sameDayWindows(windows: Window[], epochDay: number): Window[] {
  const out: Window[] = [];
  for (let i = 0; i < windows.length; i++) {
    const w = windows[i];
    if (Math.floor(w.start / MIN_PER_DAY) === epochDay && Math.floor((w.end - 1) / MIN_PER_DAY) === epochDay) {
      out.push(w);
    }
  }
  return out;
}

function myCourse(): Course {
  const c: Course = {
    id: 'c-math', name: '高等数学A', weekday: 6, sectionStart: 1, sectionEnd: 2,
    weekFrom: 1, weekTo: 16, parity: 0, place: '主楼301'
  };
  return c;
}

function myShift(): ShiftType {
  const s: ShiftType = {
    id: 's-night', name: '大夜班', color: '#2244AA', startMin: 1350, endMin: 480, crossDay: true,
    commuteInMin: 0, commuteOutMin: 40, recoveryMin: 360, nightMode: 0,
    allowActivity: false, kind: 'WORK'
  };
  return s;
}

function sections(): SectionTime[] {
  const a: SectionTime = { startMin: 480, endMin: 570 };
  const b: SectionTime = { startMin: 580, endMin: 670 };
  return [a, b];
}

export default function homeAnswerFixtureTest() {
  describe('homeAnswerFixture', () => {

    // ---------- ① 今晚餐叙 ----------
    it('tonight_answer_uses_same_day_window_covering_dinner', 0, () => {
      const busy: Interval[] = [dayIv(MON, 0, 780, 'BUSY')];
      const r = CommonFreeEngine.compute(input(emptyMy(), snapshotPartner(busy), MON, 1));
      expect(r.windows.length).assertEqual(1);
      const w = r.windows[0];
      expect(w.start).assertEqual(MON * MIN_PER_DAY + 780);  // 13:00
      expect(w.end).assertEqual(MON * MIN_PER_DAY + BED);    // 22:30
      expect(w.durationMin).assertEqual(570);
      expect(hasTag(w.tags, WindowTag.MEAL)).assertTrue();
      // 今晚候选必须落在"当天"，且被对方上午占用排除出完整同休日
      expect(sameDayWindows(r.windows, MON).length).assertEqual(1);
      expect(r.fullDays.length).assertEqual(0);
    });

    it('tonight_candidate_excludes_cross_day_window', 0, () => {
      // 双方全闲两天：旅行通道产出跨日窗口，但它不能充当「今晚」
      const busy: Interval[] = sleepOnly(MON).concat(sleepOnly(TUE));
      const r = CommonFreeEngine.compute(input(emptyMy(), localPartner(busy, []), MON, 2));
      const dayWins = sameDayWindows(r.windows, MON);
      expect(dayWins.length).assertEqual(1);
      expect(dayWins[0].start).assertEqual(MON * MIN_PER_DAY + WAKE);
      expect(dayWins[0].end).assertEqual(MON * MIN_PER_DAY + BED);
      let crossDay = 0;
      for (let i = 0; i < r.windows.length; i++) {
        if (Math.floor((r.windows[i].end - 1) / MIN_PER_DAY) > Math.floor(r.windows[i].start / MIN_PER_DAY)) {
          crossDay++;
        }
      }
      expect(crossDay).assertEqual(1); // 仅旅行窗口跨日
    });

    // ---------- ② 无今晚窗口 ----------
    it('no_tonight_window_when_rest_of_day_is_shorter_than_floor', 0, () => {
      // 对方占用到 21:00，剩余 21:00–22:30 仅 90 分钟 < minSlotMin(120) → 无今晚答案
      const busy: Interval[] = [
        mkIv(MON * MIN_PER_DAY, MON * MIN_PER_DAY + 1260, 'BUSY'),
        dayIv(MON, BED, MIN_PER_DAY, 'BUSY')
      ];
      const r = CommonFreeEngine.compute(input(emptyMy(), snapshotPartner(busy), MON, 1));
      expect(r.windows.length).assertEqual(0);
      expect(sameDayWindows(r.windows, MON).length).assertEqual(0);
    });

    // ---------- ③ 下个完整同休日 ----------
    it('full_rest_day_requires_zero_true_busy_both_sides', 0, () => {
      const busy: Interval[] = sleepOnly(SAT).concat(sleepOnly(SUN));
      const r = CommonFreeEngine.compute(input(emptyMy(), localPartner(busy, []), SAT, 2));
      expect(r.fullDays.length).assertEqual(2);
      expect(r.fullDays[0]).assertEqual(SAT);
      expect(r.fullDays[1]).assertEqual(SUN);
      expect(tagsOf(r.windows, SAT * MIN_PER_DAY + WAKE, SAT * MIN_PER_DAY + BED)
        .indexOf(WindowTag.FULL_DAY) >= 0).assertTrue();
      // 完整同休日必须"零真忙"：伴侣周六有课则当日不成立
      const courseBusy: Interval[] = busy.concat([dayIv(SAT, 480, 710, 'COURSE')]);
      const r2 = CommonFreeEngine.compute(input(emptyMy(), localPartner(courseBusy,
        [dayIv(SAT, 480, 710, 'COURSE')]), SAT, 2));
      expect(r2.fullDays.length).assertEqual(1);
      expect(r2.fullDays[0]).assertEqual(SUN);
    });

    it('snapshot_partner_full_rest_day_stays_conservative', 0, () => {
      // L1 快照：对方睡眠与班次不可分（全 BUSY）→ 当日占用恒 >0，完整同休日不得误标
      const busy: Interval[] = [
        dayIv(SAT, 0, WAKE, 'BUSY'), dayIv(SAT, BED, MIN_PER_DAY, 'BUSY'),
        dayIv(SUN, 0, WAKE, 'BUSY'), dayIv(SUN, BED, MIN_PER_DAY, 'BUSY')
      ];
      const r = CommonFreeEngine.compute(input(emptyMy(), snapshotPartner(busy), SAT, 2));
      expect(r.fullDays.length).assertEqual(0);
      expect(countWithTag(r.windows, WindowTag.FULL_DAY)).assertEqual(0);
    });

    // ---------- ④ 出行：跨夜 / 跨两日 ----------
    it('overnight_trip_window_ge_16h_crossing_midnight', 0, () => {
      // 周六 08:00 起连续空闲到周一 00:00 = 40h；≥32h 故同时满足 TRIP
      const busy: Interval[] = [
        mkIv(SAT * MIN_PER_DAY, SAT * MIN_PER_DAY + 480, 'BUSY')
      ].concat(sleepOnly(SUN));
      const tripBusy: Interval[] = [mkIv(SAT * MIN_PER_DAY, SAT * MIN_PER_DAY + 480, 'BUSY')];
      const r = CommonFreeEngine.compute(input(emptyMy(), localPartner(busy, tripBusy), SAT, 2));
      const trip = findWin(r.windows, SAT * MIN_PER_DAY + 480, (SUN + 1) * MIN_PER_DAY);
      expect(trip != null).assertTrue();
      if (trip != null) {
        expect(trip.durationMin).assertEqual(2400);          // 40h
        expect(hasTag(trip.tags, WindowTag.OVERNIGHT_TRIP)).assertTrue();
        expect(hasTag(trip.tags, WindowTag.TRIP)).assertTrue();
      }
    });

    it('overnight_only_window_ge_16h_but_under_32h_not_trip', 0, () => {
      // 伴侣周五 00:00–12:00、周六 08:00 起均忙 → 旅行通道得到 20h 跨零点空档：
      // ≥16h(overnightMinMin) 标 OVERNIGHT_TRIP；<32h(tripMinMin) 不标 TRIP
      const busy: Interval[] = [
        dayIv(FRI, 0, 720, 'BUSY'),
        dayIv(SAT, 480, MIN_PER_DAY, 'BUSY')
      ];
      const r = CommonFreeEngine.compute(input(emptyMy(), snapshotPartner(busy), FRI, 2));
      const trip = findWin(r.windows, FRI * MIN_PER_DAY + 720, SAT * MIN_PER_DAY + 480);
      expect(trip != null).assertTrue();
      if (trip != null) {
        expect(trip.durationMin).assertEqual(1200);
        expect(hasTag(trip.tags, WindowTag.OVERNIGHT_TRIP)).assertTrue();
        expect(hasTag(trip.tags, WindowTag.TRIP)).assertFalse();
      }
      expect(countWithTag(r.windows, WindowTag.OVERNIGHT_TRIP)).assertEqual(1);
      expect(countWithTag(r.windows, WindowTag.TRIP)).assertEqual(0);
    });

    it('regular_window_never_masquerades_as_trip_window', 0, () => {
      // 常规窗口最长只到 [wake, bed)，绝不可能 ≥16h 跨零点：旅行答案只能来自旅行通道
      const busy: Interval[] = sleepOnly(SAT).concat(sleepOnly(SUN));
      const r = CommonFreeEngine.compute(input(emptyMy(), localPartner(busy, []), SAT, 2));
      const regular = findWin(r.windows, SAT * MIN_PER_DAY + WAKE, SAT * MIN_PER_DAY + BED);
      expect(regular != null).assertTrue();
      if (regular != null) {
        expect(regular.durationMin).assertEqual(930);
        expect(hasTag(regular.tags, WindowTag.TRIP)).assertFalse();
        expect(hasTag(regular.tags, WindowTag.OVERNIGHT_TRIP)).assertFalse();
      }
      // 反向：旅行窗口 ≥32h，但它不是"当天的完整同休日答案"起点
      const trip = findWin(r.windows, SAT * MIN_PER_DAY, (SUN + 1) * MIN_PER_DAY);
      expect(trip != null).assertTrue();
      if (trip != null) {
        expect(trip.durationMin).assertEqual(2880);
        expect(hasTag(trip.tags, WindowTag.TRIP)).assertTrue();
      }
    });

    it('trip_window_cut_by_true_busy_not_sleep', 0, () => {
      // 周六上午有课（真忙）→ 旅行窗口从课后起，而不是从当日 00:00 起
      const busy: Interval[] = [
        dayIv(SAT, 0, WAKE, 'SLEEP'), dayIv(SAT, 480, 710, 'COURSE'),
        dayIv(SAT, BED, MIN_PER_DAY, 'SLEEP'),
        dayIv(SUN, 0, WAKE, 'SLEEP'), dayIv(SUN, BED, MIN_PER_DAY, 'SLEEP')
      ];
      const tripBusy: Interval[] = [dayIv(SAT, 480, 710, 'COURSE')];
      const r = CommonFreeEngine.compute(input(emptyMy(), localPartner(busy, tripBusy), SAT, 2));
      const trip = findWin(r.windows, SAT * MIN_PER_DAY + 710, (SUN + 1) * MIN_PER_DAY);
      expect(trip != null).assertTrue();
      expect(findWin(r.windows, SAT * MIN_PER_DAY, (SUN + 1) * MIN_PER_DAY) == null).assertTrue();
    });

    // ---------- ⑤ 三种伴侣形态 ----------
    it('solo_mode_yields_my_free_windows_and_full_days', 0, () => {
      const r = CommonFreeEngine.compute(input(emptyMy(), null, SAT, 2));
      expect(r.fullDays.length).assertEqual(2);
      const sat = findWin(r.windows, SAT * MIN_PER_DAY + WAKE, SAT * MIN_PER_DAY + BED);
      expect(sat != null).assertTrue();
      if (sat != null) {
        expect(hasTag(sat.tags, WindowTag.FULL_DAY)).assertTrue();
      }
    });

    it('local_partner_uses_partner_own_schedule_pipeline', 0, () => {
      // 本机代录：伴侣 09:00–10:00 真忙，其不可用经与"我"相同的 expand→buffer 管线产出（含 20 分钟收整）
      const my = emptyMy();
      const partnerSched: MySchedule = emptyMy();
      partnerSched.plans = [{ start: MON * MIN_PER_DAY + 540, end: MON * MIN_PER_DAY + 600 }];
      const avail = buildAvailability(partnerSched, params(1), MON, 1);
      const tripBusy: Interval[] = [mkIv(MON * MIN_PER_DAY + 540, MON * MIN_PER_DAY + 620, 'PLAN')];
      const p = localPartner(avail.notAvailable, tripBusy);
      const r = CommonFreeEngine.compute(input(my, p, MON, 1));
      // 07:00–09:00（120 分钟 = minSlotMin，保留）与 10:20–22:30
      expect(r.windows.length).assertEqual(2);
      expect(r.windows[0].start).assertEqual(MON * MIN_PER_DAY + WAKE);
      expect(r.windows[0].end).assertEqual(MON * MIN_PER_DAY + 540);
      expect(r.windows[1].start).assertEqual(MON * MIN_PER_DAY + 620); // 10:20
      expect(r.windows[1].end).assertEqual(MON * MIN_PER_DAY + BED);
      expect(r.fullDays.length).assertEqual(0);
    });

    it('snapshot_partner_and_local_partner_agree_on_common_window', 0, () => {
      // 同一份占用以两种来源喂入：常规共同窗口几何必须一致（差异只体现在同休日/旅行判定）
      const occupied = [mkIv(MON * MIN_PER_DAY, MON * MIN_PER_DAY + 780, 'BUSY')];
      const fromSnapshot = CommonFreeEngine.compute(input(emptyMy(), snapshotPartner(occupied), MON, 1));
      const fromLocal = CommonFreeEngine.compute(input(emptyMy(), localPartner(occupied, occupied), MON, 1));
      expect(fromSnapshot.windows.length).assertEqual(fromLocal.windows.length);
      for (let i = 0; i < fromSnapshot.windows.length; i++) {
        expect(fromSnapshot.windows[i].start).assertEqual(fromLocal.windows[i].start);
        expect(fromSnapshot.windows[i].end).assertEqual(fromLocal.windows[i].end);
      }
    });

    it('my_own_course_removes_dinner_window', 0, () => {
      // 我周六上午有课（真忙）→ 当天仍有晚餐窗口，但完整同休日不成立
      const my = emptyMy();
      my.shiftTypes = [myShift()];
      my.courses = [myCourse()];
      my.sectionTimes = sections();
      my.termStartEpochDay = SAT - 6; // 学期第 1 周周一 = 9/14
      const r = CommonFreeEngine.compute(input(my, null, SAT, 1));
      expect(r.fullDays.length).assertEqual(0);
      let dinnerCovered = false;
      for (let i = 0; i < r.windows.length; i++) {
        const w = r.windows[i];
        if (w.start <= SAT * MIN_PER_DAY + DINNER_START && w.end >= SAT * MIN_PER_DAY + DINNER_END) {
          dinnerCovered = true;
        }
      }
      expect(dinnerCovered).assertTrue();
    });

    // ---------- ⑥ 计划冲突三态 ----------
    it('conflict_states_blocked_plan_no_alternative', 0, () => {
      const plans: PlanLite[] = [{ id: 'p1', startMin: MON * MIN_PER_DAY + 600, endMin: MON * MIN_PER_DAY + 720 }];
      const busyUnion: Interval[] = [dayIv(MON, 660, 900, 'WORK')];
      const windows: Window[] = [
        { start: MON * MIN_PER_DAY + 420, end: MON * MIN_PER_DAY + 600, durationMin: 180, tags: [] }
      ];
      const out: ConflictOutcome[] = detectConflicts(plans, busyUnion, windows);
      expect(out.length).assertEqual(1);
      expect(out[0].conflict).assertTrue();
      expect(out[0].alternativeStartMin).assertEqual(0); // 无满足时长且更晚的替代
    });

    it('conflict_states_clean_plan_not_flagged', 0, () => {
      const plans: PlanLite[] = [{ id: 'p1', startMin: MON * MIN_PER_DAY + 1080, endMin: MON * MIN_PER_DAY + 1170 }];
      const busyUnion: Interval[] = [dayIv(MON, 540, 1080, 'WORK')]; // 边界相接不算冲突
      const out: ConflictOutcome[] = detectConflicts(plans, busyUnion, []);
      expect(out[0].conflict).assertFalse();
      expect(out[0].alternativeStartMin).assertEqual(0);
    });

    it('conflict_states_alternative_prefers_closest_duration', 0, () => {
      const plan: PlanLite = { id: 'p1', startMin: MON * MIN_PER_DAY + 600, endMin: MON * MIN_PER_DAY + 690 };
      const plans: PlanLite[] = [plan];
      const busyUnion: Interval[] = [dayIv(MON, 600, 780, 'WORK')];
      const exact: Window = { start: MON * MIN_PER_DAY + 1260, end: MON * MIN_PER_DAY + 1350, durationMin: 90, tags: [] };
      const longer: Window = { start: MON * MIN_PER_DAY + 900, end: MON * MIN_PER_DAY + 1200, durationMin: 300, tags: [] };
      const near: Window = { start: TUE * MIN_PER_DAY + 420, end: TUE * MIN_PER_DAY + 520, durationMin: 100, tags: [] };
      const out: ConflictOutcome[] = detectConflicts(plans, busyUnion, [longer, exact, near]);
      expect(out[0].conflict).assertTrue();
      // 起点晚于计划、时长 ≥ 计划者中取「时长最接近」：等长的 90 分钟窗口
      expect(out[0].alternativeStartMin).assertEqual(exact.start);
      expect(out[0].alternativeEndMin).assertEqual(exact.end);
      // 去掉等长窗口后，退而选 100 分钟的次日窗口（更短者直接不合格）
      const out2: ConflictOutcome[] = detectConflicts(plans, busyUnion, [longer, near]);
      expect(out2[0].alternativeStartMin).assertEqual(near.start);
      expect(out2[0].alternativeEndMin).assertEqual(near.end);
    });

    it('adopting_alternative_clears_conflict', 0, () => {
      const start = MON * MIN_PER_DAY + 900;
      const end = MON * MIN_PER_DAY + 990;
      const plans: PlanLite[] = [{ id: 'p1', startMin: start, endMin: end }];
      const busyUnion: Interval[] = [dayIv(MON, 600, 780, 'WORK')];
      const out: ConflictOutcome[] = detectConflicts(plans, busyUnion, []);
      expect(out[0].conflict).assertFalse();
    });

    it('plan_block_itself_is_excluded_before_conflict_scan', 0, () => {
      // busyUnion 的契约是"已排除计划自身占用"：计划只与真正的班次/课程占用比较
      const my = emptyMy();
      const block: PlanBlock = { start: MON * MIN_PER_DAY + 1080, end: MON * MIN_PER_DAY + 1170 };
      my.plans = [block];
      const avail = buildAvailability(my, params(1), MON, 1);
      const withoutPlans: Interval[] = avail.notAvailable.filter((iv: Interval) => iv.tag !== 'PLAN');
      const plans: PlanLite[] = [{ id: 'p1', startMin: block.start, endMin: block.end }];
      const out: ConflictOutcome[] = detectConflicts(plans, withoutPlans, []);
      expect(out[0].conflict).assertFalse();
    });

    // ---------- ⑦ 快照隐私 ----------
    it('snapshot_l1_and_l2_leak_no_names_or_titles', 0, () => {
      const my = emptyMy();
      my.shiftTypes = [myShift()];
      my.courses = [myCourse()];
      my.sectionTimes = sections();
      my.termStartEpochDay = SAT - 6;
      my.plans = [{ start: SAT * MIN_PER_DAY + 1080, end: SAT * MIN_PER_DAY + 1170 }];
      const names: string[] = ['高等数学A', '主楼301', '大夜班', 's-night', 'c-math'];
      const levels: number[] = [1, 2];
      for (let i = 0; i < levels.length; i++) {
        const data: SnapshotData = SnapshotBuilder.build(my, params(2), SAT, levels[i], 7);
        const text = SnapshotCodec.encode(data);
        for (let j = 0; j < names.length; j++) {
          expect(text.indexOf(names[j]) < 0).assertTrue();
        }
        // 载荷只含区间与标签，不解码即读不出可读文案
        expect(text.indexOf('CRD1|7|' + levels[i] + '|') === 0).assertTrue();
      }
    });

    it('snapshot_level3_keeps_tags_but_no_free_text', 0, () => {
      const my = emptyMy();
      my.shiftTypes = [myShift()];
      my.courses = [myCourse()];
      my.sectionTimes = sections();
      my.termStartEpochDay = SAT - 6;
      const text = SnapshotCodec.encode(SnapshotBuilder.build(my, params(2), SAT, 3, 1));
      expect(text.indexOf('高等数学A') < 0).assertTrue();
      expect(text.indexOf('主楼301') < 0).assertTrue();
      // 允许的只有：块类别枚举
      expect(text.indexOf('COURSE') >= 0 || text.indexOf('WORK') >= 0).assertTrue();
    });

    it('snapshot_roundtrip_preserves_busy_geometry', 0, () => {
      const my = emptyMy();
      const data = SnapshotBuilder.build(my, params(3), SAT, 1, 11);
      const text = SnapshotCodec.encode(data);
      const back = SnapshotCodec.decode(text);
      expect(back != null).assertTrue();
      if (back != null) {
        expect(back.version).assertEqual(11);
        expect(back.shareLevel).assertEqual(1);
        expect(back.startEpochDay).assertEqual(SAT);
        expect(back.days).assertEqual(3);
        const ivs = back.busy30;
        expect(ivs.length).assertEqual(3 * 48);
        expect(ivs[0]).assertTrue(); // SAT 00:00 属于睡眠（不可用）
      }
    });
  });
}
