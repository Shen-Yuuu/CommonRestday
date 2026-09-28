import { describe, it, expect } from '@ohos/hypium';
import { MIN_PER_DAY } from '../main/ets/model/Types';
import { epochDayOf, minToHHmm, hhmmToMin, weekdayOf, termWeekOf, isWeekend,
  epochMinOf, nowEpochMin, todayEpochDay, dayOfStart, dayOfEnd, daySpan,
  bedCrossesMidnight, bedEndMin } from '../main/ets/utils/TimeUtil';

export default function timeUtilTest() {
  describe('timeUtil', () => {
    it('epochDay_of_known_date', 0, () => {
      // 2026-09-14 是周一
      const mon = epochDayOf(2026, 9, 14);
      expect(weekdayOf(mon)).assertEqual(1);
      expect(weekdayOf(mon + 5)).assertEqual(6); // 周六
      expect(weekdayOf(mon + 6)).assertEqual(7); // 周日
      expect(isWeekend(mon)).assertFalse();
      expect(isWeekend(mon + 5)).assertTrue();
    });

    it('epochDay_linear_days', 0, () => {
      const d1 = epochDayOf(2026, 9, 30);
      const d2 = epochDayOf(2026, 10, 1);
      expect(d2 - d1).assertEqual(1);
      const d3 = epochDayOf(2026, 12, 31);
      const d4 = epochDayOf(2027, 1, 1);
      expect(d4 - d3).assertEqual(1);
    });

    it('hhmm_roundtrip', 0, () => {
      expect(minToHHmm(0)).assertEqual('00:00');
      expect(minToHHmm(480)).assertEqual('08:00');
      expect(minToHHmm(1350)).assertEqual('22:30');
      expect(hhmmToMin('08:00')).assertEqual(480);
      expect(hhmmToMin('22:30')).assertEqual(1350);
      expect(hhmmToMin('bad')).assertEqual(-1);
    });

    it('term_week', 0, () => {
      const start = epochDayOf(2026, 9, 7); // 周一
      expect(termWeekOf(start, start)).assertEqual(1);
      expect(termWeekOf(start, start + 6)).assertEqual(1);
      expect(termWeekOf(start, start + 7)).assertEqual(2);
      expect(termWeekOf(start, start - 1)).assertEqual(0);
    });

    it('epochMin_single_clock_reading_across_midnight', 0, () => {
      const late = new Date(2026, 8, 28, 23, 59, 59, 999);
      const next = new Date(2026, 8, 29, 0, 0, 0, 0);
      const day = epochDayOf(2026, 9, 28);
      const m1 = epochMinOf(late);
      const m2 = epochMinOf(next);
      expect(m1).assertEqual(day * MIN_PER_DAY + 23 * 60 + 59);
      expect(m2).assertEqual((day + 1) * MIN_PER_DAY);
      // 跨午夜只差 1 分钟：日和时分同源于一次读数，拼不出偏一整天的 epochMin
      expect(m2 - m1).assertEqual(1);
      expect(Math.floor(m1 / MIN_PER_DAY)).assertEqual(todayEpochDay(late.getTime()));
      expect(Math.floor(m2 / MIN_PER_DAY)).assertEqual(todayEpochDay(next.getTime()));
      expect(nowEpochMin(late.getTime())).assertEqual(m1);
      expect(nowEpochMin(next.getTime())).assertEqual(m2);
    });

    it('dayOfEnd_puts_a_midnight_end_back_on_the_previous_day', 0, () => {
      // 半开区间 [start, end) 的两端归日规则不同：整零点当起点是"次日开始"，当终点是"当天结束"。
      // 抄成同一个 floor 的话，夜班次日的 00:00 会多占一天；抄成同一个 ceil-1，非整零点的终点会少一天。
      const d = epochDayOf(2026, 9, 25);
      const noon = d * MIN_PER_DAY + 720;
      expect(dayOfStart(noon)).assertEqual(d);
      expect(dayOfEnd(noon)).assertEqual(d);
      const midnight = (d + 1) * MIN_PER_DAY;
      expect(dayOfStart(midnight)).assertEqual(d + 1);
      expect(dayOfEnd(midnight)).assertEqual(d);
      expect(dayOfStart(d * MIN_PER_DAY)).assertEqual(d);
      expect(dayOfEnd(d * MIN_PER_DAY)).assertEqual(d - 1);
    });

    it('daySpan_counts_the_calendar_days_a_window_touches', 0, () => {
      const d = epochDayOf(2026, 9, 25);
      const s = d * MIN_PER_DAY + 1200; // 20:00
      // 夜班「20:00–24:00」跨的是同一天，不是两天（D-58 的读法在这里对应成日数）
      expect(daySpan(s, s + 240)).assertEqual(1);
      expect(daySpan(s, s + 241)).assertEqual(2);
      // 整日窗口 [D, D+3) 占三天：终点退回一天之后再加一，正好把"三天"念对
      expect(daySpan(d * MIN_PER_DAY, (d + 3) * MIN_PER_DAY)).assertEqual(3);
      expect(daySpan(d * MIN_PER_DAY, (d + 1) * MIN_PER_DAY)).assertEqual(1);
      // 退化形给 0，不给 1 也不给负数：零长度不占任何一天
      expect(daySpan(s, s)).assertEqual(0);
      expect(daySpan(s, s - 60)).assertEqual(0);
    });

    it('bedCrossesMidnight_is_the_only_place_that_shifts_the_bed_edge', 0, () => {
      expect(bedCrossesMidnight(420, 1350)).assertFalse(); // 07:00 起 / 22:30 睡
      expect(bedCrossesMidnight(420, 60)).assertTrue();    // 07:00 起 / 次日 01:00 睡
      // 同一个时间是校验层管的退化输入（rhythmError 报错），在这条口径里不算跨零点
      expect(bedCrossesMidnight(420, 420)).assertFalse();
      expect(bedEndMin(420, 1350)).assertEqual(1350);
      expect(bedEndMin(420, 60)).assertEqual(MIN_PER_DAY + 60);
      // 引擎的睡眠段与分类器的"当日可安排核心"共用这份延后，两份判据不会各说各话
      expect(bedEndMin(420, 420)).assertEqual(420);
    });
  });
}
