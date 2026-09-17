import { describe, it, expect } from '@ohos/hypium';
import { epochDayOf, minToHHmm, hhmmToMin, weekdayOf, termWeekOf, isWeekend } from '../main/ets/utils/TimeUtil';

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
  });
}
