import { describe, it, expect } from '@ohos/hypium';
import { defaultParams, Interval, MIN_PER_DAY, WindowTag } from '../main/ets/model/Types';
import { epochDayOf } from '../main/ets/utils/TimeUtil';
import { classifyWindows, mealInterval } from '../main/ets/classify/WindowClassifier';
import { mkIv } from '../main/ets/merge/IntervalOps';

function hasTag(tags: string[], t: string): boolean {
  for (let i = 0; i < tags.length; i++) {
    if (tags[i] === t) {
      return true;
    }
  }
  return false;
}

export default function classifierTest() {
  describe('windowClassifier', () => {
    it('meal_overlap', 0, () => {
      const p = defaultParams();
      const sat = epochDayOf(2026, 9, 19);
      // 窗口 15:00–22:30 覆盖晚餐
      const free: Interval[] = [mkIv(sat * MIN_PER_DAY + 900, sat * MIN_PER_DAY + 1350, 'FREE')];
      const r = classifyWindows(free, [], [], p, p.wakeMin, p.bedMin, sat, 1);
      expect(r.windows.length).assertEqual(1);
      expect(hasTag(r.windows[0].tags, WindowTag.MEAL)).assertTrue();
      expect(hasTag(r.windows[0].tags, WindowTag.WEEKEND)).assertTrue();
      expect(hasTag(r.windows[0].tags, WindowTag.HALF_DAY)).assertTrue();
      expect(hasTag(r.windows[0].tags, WindowTag.FULL_DAY)).assertFalse();
    });

    it('full_day_when_both_idle', 0, () => {
      const p = defaultParams();
      const mon = epochDayOf(2026, 9, 14);
      // 全天无忙 → 共同空闲 = wake..bed = 930min ≥ 720
      const free: Interval[] = [mkIv(mon * MIN_PER_DAY + p.wakeMin, mon * MIN_PER_DAY + p.bedMin, 'FREE')];
      const r = classifyWindows(free, [], [], p, p.wakeMin, p.bedMin, mon, 1);
      expect(r.fullDays.length).assertEqual(1);
      expect(r.fullDays[0]).assertEqual(mon);
      expect(hasTag(r.windows[0].tags, WindowTag.FULL_DAY)).assertTrue();
    });

    it('no_full_day_when_busy', 0, () => {
      const p = defaultParams();
      const mon = epochDayOf(2026, 9, 14);
      const busy: Interval[] = [mkIv(mon * MIN_PER_DAY + 600, mon * MIN_PER_DAY + 700, 'WORK')];
      const free: Interval[] = [mkIv(mon * MIN_PER_DAY + p.wakeMin, mon * MIN_PER_DAY + 600, 'FREE')];
      const r = classifyWindows(free, busy, [], p, p.wakeMin, p.bedMin, mon, 1);
      expect(r.fullDays.length).assertEqual(0);
    });

    it('two_days_and_trip', 0, () => {
      const p = defaultParams();
      const sat = epochDayOf(2026, 9, 19);
      const sun = sat + 1;
      // 覆盖周六日整天核心
      const free: Interval[] = [mkIv(sat * MIN_PER_DAY + p.wakeMin, sun * MIN_PER_DAY + p.bedMin, 'FREE')];
      const r = classifyWindows(free, [], [], p, p.wakeMin, p.bedMin, sat, 2);
      expect(r.fullDays.length).assertEqual(2);
      expect(hasTag(r.windows[0].tags, WindowTag.FULL_DAY)).assertTrue();
      expect(hasTag(r.windows[0].tags, WindowTag.TWO_DAYS)).assertTrue();
      expect(hasTag(r.windows[0].tags, WindowTag.TRIP)).assertTrue();
      expect(hasTag(r.windows[0].tags, WindowTag.OVERNIGHT_TRIP)).assertTrue();
    });

    it('short_window_filtered_out', 0, () => {
      const p = defaultParams();
      const mon = epochDayOf(2026, 9, 14);
      const free: Interval[] = [mkIv(mon * MIN_PER_DAY + 600, mon * MIN_PER_DAY + 660, 'FREE')]; // 60min
      const r = classifyWindows(free, [], [], p, p.wakeMin, p.bedMin, mon, 1);
      expect(r.windows.length).assertEqual(0);
    });

    it('mealInterval_helper', 0, () => {
      const m = mealInterval(100, true);
      expect(m.start).assertEqual(100 * MIN_PER_DAY + 1080);
      expect(m.end).assertEqual(100 * MIN_PER_DAY + 1170);
    });

    it('study_weekday_daytime_hit', 0, () => {
      const p = defaultParams();
      const mon = epochDayOf(2026, 9, 14); // 周一
      // 09:00–12:00（180min ≥ 120），落在 08:00–21:00 内
      const free: Interval[] = [mkIv(mon * MIN_PER_DAY + 540, mon * MIN_PER_DAY + 720, 'FREE')];
      const r = classifyWindows(free, [], [], p, p.wakeMin, p.bedMin, mon, 1);
      expect(r.windows.length).assertEqual(1);
      expect(hasTag(r.windows[0].tags, WindowTag.STUDY)).assertTrue();
    });

    it('study_weekend_miss', 0, () => {
      const p = defaultParams();
      const sat = epochDayOf(2026, 9, 19); // 周六
      const free: Interval[] = [mkIv(sat * MIN_PER_DAY + 540, sat * MIN_PER_DAY + 720, 'FREE')];
      const r = classifyWindows(free, [], [], p, p.wakeMin, p.bedMin, sat, 1);
      expect(r.windows.length).assertEqual(1);
      expect(hasTag(r.windows[0].tags, WindowTag.STUDY)).assertFalse();
    });

    it('study_too_short_miss', 0, () => {
      const p = defaultParams();
      p.studyMinMin = 200; // 高于窗口时长的门槛
      const mon = epochDayOf(2026, 9, 14);
      const free: Interval[] = [mkIv(mon * MIN_PER_DAY + 540, mon * MIN_PER_DAY + 720, 'FREE')]; // 180min
      const r = classifyWindows(free, [], [], p, p.wakeMin, p.bedMin, mon, 1);
      expect(r.windows.length).assertEqual(1); // minSlot=120 仍通过
      expect(hasTag(r.windows[0].tags, WindowTag.STUDY)).assertFalse();
    });

    it('study_cross_day_long_window_miss', 0, () => {
      const p = defaultParams();
      const mon = epochDayOf(2026, 9, 14);
      const tue = mon + 1;
      // 周一 20:00 → 周二 10:00 的跨天长窗口（840min）
      const free: Interval[] = [mkIv(mon * MIN_PER_DAY + 1200, tue * MIN_PER_DAY + 600, 'FREE')];
      const r = classifyWindows(free, [], [], p, p.wakeMin, p.bedMin, mon, 2);
      expect(r.windows.length).assertEqual(1);
      expect(hasTag(r.windows[0].tags, WindowTag.STUDY)).assertFalse();
    });

    it('study_evening_out_of_range_miss', 0, () => {
      const p = defaultParams();
      const mon = epochDayOf(2026, 9, 14);
      // 19:00–22:30（210min），终点 1350 > studyEndMin=1260
      const free: Interval[] = [mkIv(mon * MIN_PER_DAY + 1140, mon * MIN_PER_DAY + 1350, 'FREE')];
      const r = classifyWindows(free, [], [], p, p.wakeMin, p.bedMin, mon, 1);
      expect(r.windows.length).assertEqual(1);
      expect(hasTag(r.windows[0].tags, WindowTag.STUDY)).assertFalse();
    });
  });
}
