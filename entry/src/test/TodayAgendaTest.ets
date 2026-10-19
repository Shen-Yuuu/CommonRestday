import { describe, it, expect } from '@ohos/hypium';
import { AgendaSource, buildTodayAgenda } from 'feature';
import { MIN_PER_DAY, dayOfStart, epochDayOf, nowEpochMin } from 'domain';

function source(id: string, start: number, end: number, kind: string = 'COURSE'): AgendaSource {
  return { id: id, start: start, end: end, name: id, kind: kind };
}

export default function todayAgendaTest() {
  describe('todayAgenda', () => {
    it('real_calendar_day_keeps_the_two_today_entries_visible', 0, () => {
      const today = epochDayOf(2026, 10, 3);
      const now = nowEpochMin(new Date(2026, 9, 3, 10, 0).getTime());
      const queryDay = dayOfStart(now);
      expect(queryDay).assertEqual(today);
      const base = today * MIN_PER_DAY;
      const rows = buildTodayAgenda([
        source('课程', base + 510, base + 630),
        source('班次', base + 840, base + 1020, 'SHIFT')
      ], queryDay);
      expect(rows.length).assertEqual(2);
      expect(rows[0].timeText).assertEqual('08:30–10:30');
      expect(rows[1].timeText).assertEqual('14:00–17:00');
    });
    it('captured_minute_selects_the_correct_day_on_each_side_of_midnight', 0, () => {
      const base = epochDayOf(2026, 10, 3) * MIN_PER_DAY;
      const night = source('夜班', base + 1380, base + MIN_PER_DAY + 420, 'SHIFT_COMMUTE');
      const before = nowEpochMin(new Date(2026, 9, 3, 23, 59).getTime());
      const after = nowEpochMin(new Date(2026, 9, 4, 0, 0).getTime());
      const first = buildTodayAgenda([night], dayOfStart(before));
      const second = buildTodayAgenda([night], dayOfStart(after));
      expect(first.length).assertEqual(1);
      expect(first[0].timeText).assertEqual('23:00–明天 07:00');
      expect(second.length).assertEqual(1);
      expect(second[0].timeText).assertEqual('昨晚 23:00–07:00');
      expect(second[0].kind).assertEqual('SHIFT_COMMUTE');
    });
    it('shows_today_only_and_sorts_without_mutating_the_source', 0, () => {
      const input: AgendaSource[] = [source('晚饭', 1110, 1170, 'PLAN'), source('课', 540, 660),
        source('昨天', -120, 0), source('明天', 1440, 1500)];
      const rows = buildTodayAgenda(input, 0);
      expect(rows.length).assertEqual(2);
      expect(rows[0].name).assertEqual('课');
      expect(rows[0].timeText).assertEqual('09:00–11:00');
      expect(rows[1].kind).assertEqual('PLAN');
      expect(input[0].id).assertEqual('晚饭');
    });
    it('labels_overnight_edges_and_keeps_midnight_as_24', 0, () => {
      const rows = buildTodayAgenda([source('夜班', -120, 420, 'SHIFT'),
        source('晚课', 1380, 1440), source('跨天', 1410, 1500, 'PLAN')], 0);
      expect(rows[0].timeText).assertEqual('昨晚 22:00–07:00');
      expect(rows[1].timeText).assertEqual('23:00–24:00');
      expect(rows[2].timeText).assertEqual('23:30–明天 01:00');
    });
    it('invalid_and_recovery_blocks_are_not_user_agenda', 0, () => {
      const rows = buildTodayAgenda([source('零', 500, 500), source('反', 700, 600),
        source('坏', Number.NaN, 600), source('恢复', 300, 600, 'RECOVERY')], 0);
      expect(rows.length).assertEqual(0);
      expect(buildTodayAgenda([], 0).length).assertEqual(0);
    });
    it('uses_dates_for_edges_beyond_yesterday_or_tomorrow', 0, () => {
      const rows = buildTodayAgenda([source('长计划', -2880, 4320, 'PLAN')], 0);
      expect(rows[0].timeText.indexOf('12月30日')).assertEqual(0);
      expect(rows[0].timeText.indexOf('1月3日') > 0).assertTrue();
    });
    it('same_time_entries_keep_distinct_stable_ids', 0, () => {
      const rows = buildTodayAgenda([source('b', 540, 660), source('a', 540, 660)], 0);
      expect(rows.length).assertEqual(2);
      expect(rows[0].id).assertEqual('a');
      expect(rows[1].id).assertEqual('b');
    });
    it('commute_inclusive_shifts_keep_their_display_annotation', 0, () => {
      const rows = buildTodayAgenda([source('早班', 510, 1050, 'SHIFT_COMMUTE')], 0);
      expect(rows.length).assertEqual(1);
      expect(rows[0].kind).assertEqual('SHIFT_COMMUTE');
      expect(rows[0].timeText).assertEqual('08:30–17:30');
    });
  });
}
