import { describe, it, expect } from '@ohos/hypium';
import { parseCourseText, parseCourseLine, toCourse } from '../main/ets/parse/CourseTextParser';

export default function courseTextParserTest() {
  describe('courseTextParser', () => {
    it('full_format_line', 0, () => {
      const p = parseCourseLine('高等数学 周一 第1-2节 1-16周 单周');
      expect(p.ok).assertTrue();
      expect(p.name).assertEqual('高等数学');
      expect(p.weekday).assertEqual(1);
      expect(p.sectionStart).assertEqual(1);
      expect(p.sectionEnd).assertEqual(2);
      expect(p.weekFrom).assertEqual(1);
      expect(p.weekTo).assertEqual(16);
      expect(p.parity).assertEqual(1);
    });

    it('weekday_variants', 0, () => {
      expect(parseCourseLine('A 星期三').weekday).assertEqual(3);
      expect(parseCourseLine('B 周天').weekday).assertEqual(7);
      expect(parseCourseLine('C 周6').weekday).assertEqual(6);
    });

    it('missing_week_defaults', 0, () => {
      const p = parseCourseLine('大学英语 周三 3,4节');
      expect(p.ok).assertTrue();
      expect(p.weekFrom).assertEqual(1);
      expect(p.weekTo).assertEqual(16);
      expect(p.parity).assertEqual(0);
      expect(p.sectionStart).assertEqual(3);
      expect(p.sectionEnd).assertEqual(4);
    });

    it('single_section', 0, () => {
      const p = parseCourseLine('体育 星期五 第5节 2-16周 双周');
      expect(p.ok).assertTrue();
      expect(p.sectionStart).assertEqual(5);
      expect(p.sectionEnd).assertEqual(5);
      expect(p.parity).assertEqual(2);
      expect(p.weekFrom).assertEqual(2);
    });

    it('multiline_mixed_results', 0, () => {
      const r = parseCourseText('高数 周一 1-2节 1-16周\n\n英语 周三 3-4节\n垃圾行');
      expect(r.length).assertEqual(3);
      expect(r[0].ok).assertTrue();
      expect(r[1].ok).assertTrue();
      expect(r[2].ok).assertFalse();
      expect(r[2].error !== '').assertTrue();
    });

    it('missing_weekday_fails', 0, () => {
      const p = parseCourseLine('无名课 1-2节');
      expect(p.ok).assertFalse();
      expect(p.error === '未识别星期（如：周一）').assertTrue();
    });

    it('to_course_mapping', 0, () => {
      const p = parseCourseLine('物理 周二 6-7节 3-18周');
      const c = toCourse(p, 'id1');
      expect(c.id).assertEqual('id1');
      expect(c.name).assertEqual('物理');
      expect(c.weekday).assertEqual(2);
      expect(c.weekTo).assertEqual(18);
    });
  });
}
