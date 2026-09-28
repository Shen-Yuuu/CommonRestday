import { describe, it, expect } from '@ohos/hypium';
import {
  clampHorizonDays, Course, CycleTemplate, defaultParams, EngineInput, EngineParams, HORIZON_MAX_DAYS,
  Interval, MIN_PER_DAY, MySchedule, PartnerSchedule, ScheduleOverride, SectionTime, ShiftType,
  Window, WindowChannel, WindowTag
} from '../main/ets/model/Types';
import { dayOfEnd, dayOfStart, daySpan, epochDayOf } from '../main/ets/utils/TimeUtil';
import { clipInto } from '../main/ets/merge/IntervalOps';
import { CommonFreeEngine, buildAvailability } from '../main/ets/engine/CommonFreeEngine';

function hasTag(tags: string[], t: string): boolean {
  for (let i = 0; i < tags.length; i++) {
    if (tags[i] === t) {
      return true;
    }
  }
  return false;
}

function nightShiftType(): ShiftType {
  const c: ShiftType = {
    id: 'night', name: '夜班', color: '#2244AA', startMin: 1350, endMin: 480, crossDay: true,
    commuteInMin: 0, commuteOutMin: 40, recoveryMin: 360, nightMode: 0,
    allowActivity: false, kind: 'WORK'
  };
  return c;
}

function mkMy(template: CycleTemplate | null): MySchedule {
  const m: MySchedule = {
    shiftTypes: [nightShiftType()],
    template: template,
    overrides: [],
    courses: [],
    sectionTimes: [],
    termStartEpochDay: -1,
    plans: [],
    wakeMin: 420,
    bedMin: 1350,
    windDownMin: 20
  };
  return m;
}

function mkMyOvs(template: CycleTemplate | null, ovs: ScheduleOverride[]): MySchedule {
  const m = mkMy(template);
  m.overrides = ovs;
  return m;
}

function ov(day: number, id: string | null): ScheduleOverride {
  const o: ScheduleOverride = { epochDay: day, shiftTypeId: id };
  return o;
}

/** 忙碌块清单（排序后拼串）：比的是"同一批块"，不比生成顺序。 */
function busySig(list: Interval[]): string {
  const parts: string[] = [];
  for (let i = 0; i < list.length; i++) {
    parts.push(list[i].start + '~' + list[i].end + '#' + list[i].tag);
  }
  parts.sort();
  let s = '';
  for (let i = 0; i < parts.length; i++) {
    s += parts[i] + ';';
  }
  return s;
}

function mkInput(my: MySchedule, partnerBusy: Interval[], startDay: number, days: number,
  partnerTripBusy?: Interval[]): EngineInput {
  const partner: PartnerSchedule = {
    shareLevel: 1, busyIntervals: partnerBusy, tripBusyIntervals: partnerTripBusy ?? null
  };
  const input: EngineInput = {
    my: my,
    partner: partner,
    params: defaultParamsWith(days),
    horizonStartEpochDay: startDay
  };
  return input;
}

function defaultParamsWith(days: number): EngineParams {
  const p = defaultParams();
  p.horizonDays = days;
  return p;
}

/** 无班次、可自定义课程与作息的通用排程构造（双人装配用例共用）。 */
function mkSched(courses: Course[], sectionTimes: SectionTime[], termStart: number,
  wake: number, bed: number, wind: number): MySchedule {
  const m: MySchedule = {
    shiftTypes: [],
    template: null,
    overrides: [],
    courses: courses,
    sectionTimes: sectionTimes,
    termStartEpochDay: termStart,
    plans: [],
    wakeMin: wake,
    bedMin: bed,
    windDownMin: wind
  };
  return m;
}

function mkCourse1to2(): Course {
  const c: Course = {
    id: 'pc1', name: '高数', weekday: 1, sectionStart: 1, sectionEnd: 2,
    weekFrom: 1, weekTo: 16, parity: 0, place: ''
  };
  return c;
}

function twoSections(): SectionTime[] {
  const s1: SectionTime = { startMin: 480, endMin: 570 };
  const s2: SectionTime = { startMin: 580, endMin: 670 };
  return [s1, s2];
}

/**
 * PRD F4 示例（技术文档 5.3）：
 * 小王周五 22:30 上夜班，周六 08:00 下班；后置通勤 40min；恢复 6h；
 * 收整缓冲 20min；就寝 22:30。小陈周六休息（完全空闲）。
 * 期望：周六共同窗口 = 15:00—22:30，共 450 分钟（7.5h）。
 */
export default function engineTest() {
  describe('commonFreeEngine', () => {
    it('prd_f4_example_night_shift_saturday', 0, () => {
      const fri = epochDayOf(2026, 9, 18); // 周五
      const sat = fri + 1;
      const sun = fri + 2;
      // 循环：夜班/休/休（seq 长度必须 ≥2，否则每天都排夜班）
      const tpl: CycleTemplate = { id: 't', name: '夜休休', seq: ['night', 'rest', 'rest'], anchorEpochDay: fri };
      const input = mkInput(mkMy(tpl), [], fri, 3);
      const r = CommonFreeEngine.compute(input);

      // 找到周六常规窗口（v1.2 起同起点可能另有旅行窗口，需按起止双字段匹配）
      let satWinStart = -1;
      let satWinEnd = -1;
      let satWinDur = -1;
      let satWinTags: string[] = [];
      for (let i = 0; i < r.windows.length; i++) {
        if (r.windows[i].start === sat * MIN_PER_DAY + 900 && r.windows[i].end === sat * MIN_PER_DAY + 1350) {
          satWinStart = r.windows[i].start;
          satWinEnd = r.windows[i].end;
          satWinDur = r.windows[i].durationMin;
          satWinTags = r.windows[i].tags;
        }
      }
      expect(satWinStart).assertEqual(sat * MIN_PER_DAY + 900);       // 15:00
      expect(satWinEnd).assertEqual(sat * MIN_PER_DAY + 1350);        // 22:30
      expect(satWinDur).assertEqual(450);                              // 7h30m
      expect(hasTag(satWinTags, WindowTag.MEAL)).assertTrue();
      expect(hasTag(satWinTags, WindowTag.WEEKEND)).assertTrue();
      expect(hasTag(satWinTags, WindowTag.FULL_DAY)).assertFalse();   // 周六有夜班尾忙

      // 周五：夜班 22:30 起，白天 07:00–22:30 共同空闲（930 分钟）
      let friFound = false;
      for (let i = 0; i < r.windows.length; i++) {
        if (r.windows[i].start === fri * MIN_PER_DAY + 420
          && r.windows[i].end === fri * MIN_PER_DAY + 1350) {
          friFound = true;
        }
      }
      expect(friFound).assertTrue();

      // 周日：双方全闲 → 完整同休日
      let sunFull = false;
      for (let i = 0; i < r.fullDays.length; i++) {
        if (r.fullDays[i] === sun) {
          sunFull = true;
        }
      }
      expect(sunFull).assertTrue();
    });

    it('partner_busy_blocks_window', 0, () => {
      const mon = epochDayOf(2026, 9, 14);
      const tpl: CycleTemplate = { id: 't', name: '无班', seq: [], anchorEpochDay: mon };
      // 我方无班（锚点远处），对方忙 10:00–11:00（600–660）
      const pb: Interval[] = [{ start: mon * MIN_PER_DAY + 600, end: mon * MIN_PER_DAY + 660, tag: 'BUSY' }];
      const input = mkInput(mkMy(tpl), pb, mon, 1);
      const r = CommonFreeEngine.compute(input);
      // 共同空闲应被切成两段：07:00–10:00 与 11:00–22:30（对方睡眠未知，其快照即其不可用）
      expect(r.windows.length).assertEqual(2);
      expect(r.windows[0].start).assertEqual(mon * MIN_PER_DAY + 420);
      expect(r.windows[0].end).assertEqual(mon * MIN_PER_DAY + 600);
      expect(r.windows[1].start).assertEqual(mon * MIN_PER_DAY + 660);
      expect(r.windows[1].end).assertEqual(mon * MIN_PER_DAY + 1350);
    });

    it('compute_is_fast', 0, () => {
      const fri = epochDayOf(2026, 9, 18);
      const tpl: CycleTemplate = { id: 't', name: '夜休休', seq: ['night', 'rest', 'rest'], anchorEpochDay: fri };
      const input = mkInput(mkMy(tpl), [], fri, 120);
      CommonFreeEngine.compute(input); // 预热（JIT/类初始化）
      const r = CommonFreeEngine.compute(input);
      // 本地 Node 运行器实测约 75ms（解释执行）；<50ms 的预算以真机 Profiler 为准（M7 验证）
      expect(r.computeMs < 200).assertTrue();
    });

    it('partner_course_cuts_common_window', 0, () => {
      // 双课表交叠切除：伴侣周一 1-2 节（08:00–11:10）有课，我全闲
      const mon = epochDayOf(2026, 9, 14);
      const params = defaultParamsWith(1);
      const partnerSched = mkSched([mkCourse1to2()], twoSections(), mon, 420, 1350, 20);
      const partnerAvail = buildAvailability(partnerSched, params, mon, 1);
      const my = mkSched([], [], -1, 420, 1350, 20);
      const input = mkInput(my, partnerAvail.notAvailable, mon, 1);
      const r = CommonFreeEngine.compute(input);
      // 伴侣忙区间 = 睡眠 [0,420)∪课程+收整 [480,690)∪[1350,1440)
      // 共同空闲 = 07:00–08:00（60min 被过滤）∪ 11:30–22:30（660min）
      expect(r.windows.length).assertEqual(1);
      expect(r.windows[0].start).assertEqual(mon * MIN_PER_DAY + 690);
      expect(r.windows[0].end).assertEqual(mon * MIN_PER_DAY + 1350);
      expect(r.windows[0].durationMin).assertEqual(660);
    });

    it('partner_all_idle_equals_single', 0, () => {
      // 伴侣全闲（无班表无课程）时，共同结果 = 我的单人空闲
      const mon = epochDayOf(2026, 9, 14);
      const params = defaultParamsWith(1);
      const my = mkSched([mkCourse1to2()], twoSections(), mon, 420, 1350, 20);
      const single = CommonFreeEngine.compute(mkInput(my, [], mon, 1));
      const partnerSched = mkSched([], [], -1, 420, 1350, 20);
      const partnerAvail = buildAvailability(partnerSched, params, mon, 1);
      const coupled = CommonFreeEngine.compute(mkInput(my, partnerAvail.notAvailable, mon, 1));
      expect(coupled.windows.length).assertEqual(single.windows.length);
      for (let i = 0; i < single.windows.length; i++) {
        expect(coupled.windows[i].start).assertEqual(single.windows[i].start);
        expect(coupled.windows[i].end).assertEqual(single.windows[i].end);
        expect(coupled.windows[i].durationMin).assertEqual(single.windows[i].durationMin);
      }
    });

    it('partner_independent_bedtime_shortens_window', 0, () => {
      // 伴侣独立参数：伴侣就寝 21:30 早于我的 22:30 → 窗口终点提前到 21:30
      const mon = epochDayOf(2026, 9, 14);
      const params = defaultParamsWith(1);
      const my = mkSched([], [], -1, 420, 1350, 20);
      const partnerSched = mkSched([], [], -1, 420, 1290, 20);
      const partnerAvail = buildAvailability(partnerSched, params, mon, 1);
      const r = CommonFreeEngine.compute(mkInput(my, partnerAvail.notAvailable, mon, 1));
      expect(r.windows.length).assertEqual(1);
      expect(r.windows[0].start).assertEqual(mon * MIN_PER_DAY + 420);
      expect(r.windows[0].end).assertEqual(mon * MIN_PER_DAY + 1290);
      expect(r.windows[0].durationMin).assertEqual(870);
    });

    it('partner_full_day_and_trip_local_both_idle', 0, () => {
      // 回归（v1.2）：双人本机代录、周六周日双方均无班次/课程。
      // 修复前：classify 收到对方含睡眠的不可用 → peerBusy 恒 >0 → FULL_DAY 永不触发。
      const sat = epochDayOf(2026, 9, 19);
      const sun = sat + 1;
      const my = mkSched([], [], -1, 420, 1350, 20);
      // 伴侣不可用 = 两天睡眠块（与我的作息一致）；不含睡眠的真忙为空
      const pb: Interval[] = [
        { start: sat * MIN_PER_DAY, end: sat * MIN_PER_DAY + 420, tag: 'SLEEP' },
        { start: sat * MIN_PER_DAY + 1350, end: (sat + 1) * MIN_PER_DAY, tag: 'SLEEP' },
        { start: sun * MIN_PER_DAY, end: sun * MIN_PER_DAY + 420, tag: 'SLEEP' },
        { start: sun * MIN_PER_DAY + 1350, end: (sun + 1) * MIN_PER_DAY, tag: 'SLEEP' }
      ];
      const r = CommonFreeEngine.compute(mkInput(my, pb, sat, 2, []));

      // 两个完整同休日
      expect(r.fullDays.length).assertEqual(2);
      // 常规窗口（每天 [wake, bed)）带 FULL_DAY 标签
      let regFull = false;
      for (let i = 0; i < r.windows.length; i++) {
        if (r.windows[i].start === sat * MIN_PER_DAY + 420 && hasTag(r.windows[i].tags, WindowTag.FULL_DAY)) {
          regFull = true;
        }
      }
      expect(regFull).assertTrue();
      // 旅行窗口：跨睡眠连续空档 [sat 00:00, sun 24:00) 48h，带 TRIP/OVERNIGHT_TRIP
      let tripFound = false;
      for (let i = 0; i < r.windows.length; i++) {
        const w = r.windows[i];
        if (w.start === sat * MIN_PER_DAY && w.end === (sat + 2) * MIN_PER_DAY) {
          tripFound = hasTag(w.tags, WindowTag.TRIP) && hasTag(w.tags, WindowTag.OVERNIGHT_TRIP);
        }
      }
      expect(tripFound).assertTrue();
    });

    it('partner_l1_snapshot_full_day_conservative', 0, () => {
      // L1 快照：忙碌位图含对方睡眠（'BUSY' 标签，不可剥离）→ 同休日判定保守不触发；
      // 常规窗口计算不受影响。
      const mon = epochDayOf(2026, 9, 14);
      const my = mkSched([], [], -1, 420, 1350, 20);
      const pb: Interval[] = [
        { start: mon * MIN_PER_DAY, end: mon * MIN_PER_DAY + 420, tag: 'BUSY' },
        { start: mon * MIN_PER_DAY + 1350, end: (mon + 1) * MIN_PER_DAY, tag: 'BUSY' }
      ];
      const r = CommonFreeEngine.compute(mkInput(my, pb, mon, 1));
      expect(r.fullDays.length).assertEqual(0);
      expect(r.windows.length).assertEqual(1);
      expect(r.windows[0].start).assertEqual(mon * MIN_PER_DAY + 420);
      expect(r.windows[0].end).assertEqual(mon * MIN_PER_DAY + 1350);
    });

    it('partner_trip_window_skips_busy_morning', 0, () => {
      // 旅行窗口语义（v1.2）：睡眠可被跨越、真忙+收整切断。
      // 伴侣周六上午有课（08:00–11:50 含收整），周六下午起至周日深夜为连续旅行空档。
      const sat = epochDayOf(2026, 9, 19);
      const sun = sat + 1;
      const my = mkSched([], [], -1, 420, 1350, 20);
      const pb: Interval[] = [
        { start: sat * MIN_PER_DAY, end: sat * MIN_PER_DAY + 420, tag: 'SLEEP' },
        { start: sat * MIN_PER_DAY + 480, end: sat * MIN_PER_DAY + 710, tag: 'COURSE' },
        { start: sat * MIN_PER_DAY + 1350, end: (sat + 1) * MIN_PER_DAY, tag: 'SLEEP' },
        { start: sun * MIN_PER_DAY, end: sun * MIN_PER_DAY + 420, tag: 'SLEEP' },
        { start: sun * MIN_PER_DAY + 1350, end: (sun + 1) * MIN_PER_DAY, tag: 'SLEEP' }
      ];
      const tripBusy: Interval[] = [
        { start: sat * MIN_PER_DAY + 480, end: sat * MIN_PER_DAY + 710, tag: 'COURSE' }
      ];
      const r = CommonFreeEngine.compute(mkInput(my, pb, sat, 2, tripBusy));

      // 常规窗口：周六 11:50–22:30、周日 07:00–22:30
      let satWin = false;
      let sunWin = false;
      for (let i = 0; i < r.windows.length; i++) {
        const w = r.windows[i];
        if (w.start === sat * MIN_PER_DAY + 710 && w.end === sat * MIN_PER_DAY + 1350) {
          satWin = true;
        }
        if (w.start === sun * MIN_PER_DAY + 420 && w.end === sun * MIN_PER_DAY + 1350) {
          sunWin = true;
        }
      }
      expect(satWin).assertTrue();
      expect(sunWin).assertTrue();
      // 周日为完整同休日（周六伴侣有课不算）
      expect(r.fullDays.length).assertEqual(1);
      expect(r.fullDays[0]).assertEqual(sun);
      // 旅行窗口：周六 11:50 → 周一 00:00（≥32h 且跨零点）
      let tripFound = false;
      for (let i = 0; i < r.windows.length; i++) {
        const w = r.windows[i];
        if (w.start === sat * MIN_PER_DAY + 710 && w.end === (sat + 2) * MIN_PER_DAY) {
          tripFound = hasTag(w.tags, WindowTag.TRIP) && hasTag(w.tags, WindowTag.OVERNIGHT_TRIP);
        }
      }
      expect(tripFound).assertTrue();
    });

    /**
     * D-56：buildAvailability 不再自己抄一份 override 循环，有没有循环模板都走 expandCycle 那一条合流。
     * 下面四格钉的是"并轨前后同一批忙碌块"，而不是某个顺序：一次读数的顺序随 overrides 数组，
     * 引擎那份随视界里的天——合流之后只剩后者这一种。
     */
    it('no_template_painted_shift_equals_template_layer', 0, () => {
      // 从没建过循环模板、只把周五涂成夜班 ≡ 循环本身就是"夜班/休/休"且周五排在夜班那一格
      const fri = epochDayOf(2026, 9, 18);
      const p = defaultParamsWith(1);
      const painted = buildAvailability(mkMyOvs(null, [ov(fri, 'night')]), p, fri, 1);
      const tpl: CycleTemplate = { id: 't', name: '夜休休', seq: ['night', 'rest', 'rest'], anchorEpochDay: fri };
      const cyclic = buildAvailability(mkMyOvs(tpl, []), p, fri, 1);
      expect(painted.trueBusy.length > 0).assertTrue();
      expect(busySig(painted.trueBusy)).assertEqual(busySig(cyclic.trueBusy));
    });

    it('painted_rest_is_a_real_override_not_absence', 0, () => {
      // 同一条数据：涂休息（shiftTypeId=null）不产实例，涂班产实例——两条并成一路后仍要分开
      const fri = epochDayOf(2026, 9, 18);
      const p = defaultParamsWith(3);
      const rest = buildAvailability(mkMyOvs(null, [ov(fri, null)]), p, fri, 3);
      expect(rest.trueBusy.length).assertEqual(0);
      const mixed = buildAvailability(mkMyOvs(null, [ov(fri, null), ov(fri + 1, 'night')]), p, fri, 3);
      expect(mixed.trueBusy.length > 0).assertTrue();
      expect(mixed.trueBusy.length > rest.trueBusy.length).assertTrue();
    });

    it('override_outside_horizon_dropped', 0, () => {
      // 合流按视界逐日走，越界的覆盖不会漏进来（旧那份额外循环靠显式区间判，并轨后这条口径要有凭据）
      const fri = epochDayOf(2026, 9, 18);
      const avail = buildAvailability(mkMyOvs(null, [ov(fri + 5, 'night')]), defaultParamsWith(1), fri, 1);
      expect(avail.trueBusy.length).assertEqual(0);
    });

    it('painted_rest_clears_template_shift_for_common_time', 0, () => {
      // D-55 的另一半：涂成休息的那天，共同时间也不该再算它忙（相减的形状——单看展开结果，
      // 涂休息与循环本来就休长得一模一样）
      const fri = epochDayOf(2026, 9, 18);
      const p = defaultParamsWith(1);
      const tpl: CycleTemplate = { id: 't', name: '夜休休', seq: ['night', 'rest', 'rest'], anchorEpochDay: fri };
      const before = buildAvailability(mkMyOvs(tpl, []), p, fri, 1);
      const after = buildAvailability(mkMyOvs(tpl, [ov(fri, null)]), p, fri, 1);
      expect(before.trueBusy.length > 0).assertTrue();
      expect(after.trueBusy.length).assertEqual(0);
      // 换了读者：清空之后那天整天（07:00–22:30）都是共同空闲
      const r = CommonFreeEngine.compute(mkInput(mkMyOvs(tpl, [ov(fri, null)]), [], fri, 1));
      let freeAllDay = false;
      for (let i = 0; i < r.windows.length; i++) {
        if (r.windows[i].start === fri * MIN_PER_DAY + 420 && r.windows[i].end === fri * MIN_PER_DAY + 1350) {
          freeAllDay = true;
        }
      }
      expect(freeAllDay).assertTrue();
    });

    it('horizon_days_clamp_at_both_ends', 0, () => {
      // 视界那一道闸只管上下两头：中间的值照原样过，越界的收进来（D-57）
      expect(clampHorizonDays(120)).assertEqual(120);
      expect(clampHorizonDays(HORIZON_MAX_DAYS)).assertEqual(HORIZON_MAX_DAYS);
      expect(clampHorizonDays(5000)).assertEqual(HORIZON_MAX_DAYS);
      expect(clampHorizonDays(0)).assertEqual(1);
      expect(clampHorizonDays(-400)).assertEqual(1);
    });

    it('compute_stops_at_the_horizon_ceiling_when_params_dont', 0, () => {
      // 一份从别处带回来的超大视界（设置页的校验管不到 Preferences 里那份 JSON）：
      // 引擎按上限展开，两头都要判得住——上限那天还在算，之后一天都不许有窗口。
      const mon = epochDayOf(2026, 9, 14);
      const tpl: CycleTemplate = { id: 't', name: '无班', seq: [], anchorEpochDay: mon };
      const r = CommonFreeEngine.compute(mkInput(mkMy(tpl), [], mon, 5000));
      expect(r.fullDays.length).assertEqual(HORIZON_MAX_DAYS);
      const ceilingEnd = (mon + HORIZON_MAX_DAYS) * MIN_PER_DAY;
      let lastDayFree = false;
      for (let i = 0; i < r.windows.length; i++) {
        expect(r.windows[i].end <= ceilingEnd).assertTrue();
        if (r.windows[i].start >= (mon + HORIZON_MAX_DAYS - 1) * MIN_PER_DAY) {
          lastDayFree = true;
        }
      }
      expect(lastDayFree).assertTrue();
    });

    /**
     * AK 的设备判据要的是"跨零点的常规窗口"。先钉住引擎每天的两道睡眠栅栏：起床前的晨段与
     * 前一晚跨零点的尾巴**都从当日 00:00 起算**，所以按日作息产不出跨过午夜的常规窗口——
     * 日详情页头"整段相加"与"裁进当日"因此必然同值（设备上 10/2、10/3 改前改后都念 17小时）。
     * 旅行通道天生跨整天，它才是两种算法的分岔口，所以下面逐条先按通道分流。
     */
    it('cross_midnight_bed_never_lets_a_regular_window_leave_its_day', 0, () => {
      const mon = epochDayOf(2026, 9, 14);
      // 起床 07:00／就寝 01:00：就寝早于起床＝次日凌晨就寝，页面上那句"算作第二天"说的就是它
      const late = mkSched([], [], -1, 420, 60, 20);
      const r = CommonFreeEngine.compute(mkInput(late, [], mon, 10));
      let regular = 0;
      for (let i = 0; i < r.windows.length; i++) {
        const w: Window = r.windows[i];
        if (w.channel !== WindowChannel.REGULAR) {
          continue;
        }
        regular += 1;
        expect(dayOfEnd(w.end)).assertEqual(dayOfStart(w.start));
        expect(w.durationMin).assertEqual(1020);
      }
      expect(regular).assertEqual(10);
    });

    /**
     * 唯一能造出跨零点常规窗口的合法作息：起床 00:00 ＋ 就寝 24:00（整天清醒）。
     * `rhythmError` 只挡"两个时间填成一样"，这两头都不挡，于是当日 00:00 处一道栅栏也没有，
     * 常规窗口一路跨过午夜、一整个视界连成一段。这时候页头若照 `durationMin` 整段相加，
     * 念的是 10 天而不是当天——这才是 `clipInto` 那道闸真正管住的输入。
     */
    it('all_day_rhythm_is_the_only_regular_window_that_walks_past_midnight', 0, () => {
      const mon = epochDayOf(2026, 9, 14);
      const awake = mkSched([], [], -1, 0, 1440, 0);
      const r = CommonFreeEngine.compute(mkInput(awake, [], mon, 10));
      const day2 = (mon + 2) * MIN_PER_DAY;
      let crossings = 0;
      let whole = 0;
      let clipped = 0;
      for (let i = 0; i < r.windows.length; i++) {
        const w: Window = r.windows[i];
        if (w.channel !== WindowChannel.REGULAR || daySpan(w.start, w.end) <= 1) {
          continue;
        }
        crossings += 1;
        whole = w.durationMin;
        const c = clipInto(w.start, w.end, day2, day2 + MIN_PER_DAY);
        clipped = c == null ? 0 : c.end - c.start;
      }
      expect(crossings).assertEqual(1);
      expect(whole).assertEqual(10 * MIN_PER_DAY);
      expect(clipped).assertEqual(MIN_PER_DAY);
    });
  });
}
