import { describe, it, expect } from '@ohos/hypium';
import { Course, OWNER_ME, ScheduleOverride } from 'domain';
import { RECOMPUTE_COUNT_KEY, ScheduleCommandResult, ScheduleCommandService } from 'feature';

/**
 * 命令与重算的配对关系（阶段 2 Task 2.1）：一次用户保存 = 一次写入 + 恰好一次重算。
 * 断言只走设备侧同名广播键（AppStorage 的 recomputeCount），没用到测试专用字段，
 * 因此这些用例搬到真机 Hypium 仍然成立。仓储在离线 runner 里是类型壳，
 * 这里证明的是编排（写几次、重算几次、空批次是否白算），不是 SQL 落库。
 */
function recomputes(): number {
  return AppStorage.get<number>(RECOMPUTE_COUNT_KEY) ?? 0;
}

function course(id: string): Course {
  const c: Course = {
    id: id, name: '课' + id, weekday: 1, sectionStart: 1, sectionEnd: 2,
    weekFrom: 1, weekTo: 16, parity: 0, place: ''
  };
  return c;
}

function override(epochDay: number, shiftTypeId: string | null): ScheduleOverride {
  const o: ScheduleOverride = { epochDay: epochDay, shiftTypeId: shiftTypeId };
  return o;
}

export default function scheduleCommandServiceTest() {
  describe('scheduleCommandService', () => {

    it('set_day_shift_writes_once_and_recomputes_once', 0, async () => {
      const before = recomputes();
      const r: ScheduleCommandResult = await ScheduleCommandService.setDayShift(20000, 'shift-a', OWNER_ME);
      expect(r.ok).assertTrue();
      expect(r.changed).assertTrue();
      expect(r.recomputed).assertTrue();
      expect(r.errorCode).assertEqual('');
      expect(recomputes() - before).assertEqual(1);
    });

    it('clear_day_shift_recomputes_once', 0, async () => {
      const before = recomputes();
      const r = await ScheduleCommandService.clearDayShift(20001, OWNER_ME);
      expect(r.ok).assertTrue();
      expect(recomputes() - before).assertEqual(1);
    });

    it('forced_rest_override_accepts_null_shift', 0, async () => {
      const before = recomputes();
      const r = await ScheduleCommandService.paintDays([], [override(20002, null)], OWNER_ME);
      expect(r.ok).assertTrue();
      expect(recomputes() - before).assertEqual(1);
    });

    it('paint_batch_recomputes_once_not_per_day', 0, async () => {
      const before = recomputes();
      const sets: ScheduleOverride[] = [override(20010, 'shift-a'), override(20011, 'shift-b'),
        override(20012, null)];
      const r = await ScheduleCommandService.paintDays([20009, 20008], sets, OWNER_ME);
      expect(r.ok).assertTrue();
      expect(r.changed).assertTrue();
      expect(recomputes() - before).assertEqual(1);
    });

    it('empty_paint_batch_skips_write_and_recompute', 0, async () => {
      const before = recomputes();
      const r = await ScheduleCommandService.paintDays([], [], OWNER_ME);
      expect(r.ok).assertTrue();
      expect(r.changed).assertFalse();
      expect(r.recomputed).assertFalse();
      expect(recomputes()).assertEqual(before);
    });

    it('course_import_recomputes_once_for_the_whole_batch', 0, async () => {
      const before = recomputes();
      const r = await ScheduleCommandService.importCourses([course('c1'), course('c2'), course('c3')],
        OWNER_ME);
      expect(r.ok).assertTrue();
      expect(r.changed).assertTrue();
      expect(recomputes() - before).assertEqual(1);
    });

    it('empty_course_import_is_a_no_op', 0, async () => {
      const before = recomputes();
      const r = await ScheduleCommandService.importCourses([], OWNER_ME);
      expect(r.changed).assertFalse();
      expect(recomputes()).assertEqual(before);
    });

    it('shift_type_and_term_writes_each_recompute_once', 0, async () => {
      const before = recomputes();
      const a = await ScheduleCommandService.saveCourse(course('c9'), OWNER_ME);
      const b = await ScheduleCommandService.removeCourse('c9', OWNER_ME);
      // times 为空走默认节次模板，同样只重算一次
      const c = await ScheduleCommandService.saveTerm(20000, []);
      expect(a.ok && b.ok && c.ok).assertTrue();
      expect(recomputes() - before).assertEqual(3);
    });
  });
}
