import { describe, it, expect } from '@ohos/hypium';
import { Course, SectionTime, MIN_PER_DAY } from '../main/ets/model/Types';
import { epochDayOf } from '../main/ets/utils/TimeUtil';
import { expandCourses } from '../main/ets/expand/CourseExpander';

function mkCourse(parity: number, weekFrom: number, weekTo: number, weekday: number): Course {
  const c: Course = {
    id: 'c1', name: '高数', weekday: weekday, sectionStart: 1, sectionEnd: 2,
    weekFrom: weekFrom, weekTo: weekTo, parity: parity, place: ''
  };
  return c;
}

function sections(): SectionTime[] {
  const s1: SectionTime = { startMin: 480, endMin: 570 };
  const s2: SectionTime = { startMin: 580, endMin: 670 };
  const arr: SectionTime[] = [s1, s2];
  return arr;
}

export default function courseExpanderTest() {
  describe('courseExpander', () => {
    it('weekly_course_expands', 0, () => {
      const term = epochDayOf(2026, 9, 7); // 周一
      const ivs = expandCourses([mkCourse(0, 1, 16, 1)], sections(), term, term, 7);
      expect(ivs.length).assertEqual(1);
      expect(ivs[0].start).assertEqual(term * MIN_PER_DAY + 480);
      expect(ivs[0].end).assertEqual(term * MIN_PER_DAY + 670);
      expect(ivs[0].tag).assertEqual('COURSE');
    });

    it('out_of_week_range_empty', 0, () => {
      const term = epochDayOf(2026, 9, 7);
      // 第 17 周（term + 16*7）无课
      const ivs = expandCourses([mkCourse(0, 1, 16, 1)], sections(), term, term + 16 * 7, 1);
      expect(ivs.length).assertEqual(0);
    });

    it('odd_week_parity', 0, () => {
      const term = epochDayOf(2026, 9, 7);
      const odd = expandCourses([mkCourse(1, 1, 16, 1)], sections(), term, term, 1);
      const even = expandCourses([mkCourse(1, 1, 16, 1)], sections(), term, term + 7, 1);
      expect(odd.length).assertEqual(1);
      expect(even.length).assertEqual(0);
    });

    it('even_week_parity', 0, () => {
      const term = epochDayOf(2026, 9, 7);
      const odd = expandCourses([mkCourse(2, 1, 16, 1)], sections(), term, term, 1);
      const even = expandCourses([mkCourse(2, 1, 16, 1)], sections(), term, term + 7, 1);
      expect(odd.length).assertEqual(0);
      expect(even.length).assertEqual(1);
    });

    it('before_term_empty', 0, () => {
      const term = epochDayOf(2026, 9, 7);
      const ivs = expandCourses([mkCourse(0, 1, 16, 1)], sections(), term, term - 3, 2);
      expect(ivs.length).assertEqual(0);
    });

    it('weekday_filter', 0, () => {
      const term = epochDayOf(2026, 9, 7);
      const ivs = expandCourses([mkCourse(0, 1, 16, 3)], sections(), term, term, 2); // 周三课
      expect(ivs.length).assertEqual(0); // 前两天是周一/周二
    });
  });
}
