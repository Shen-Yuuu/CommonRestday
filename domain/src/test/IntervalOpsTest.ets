import { describe, it, expect } from '@ohos/hypium';
import { Interval, MIN_PER_DAY } from '../main/ets/model/Types';
import { mergeIntervals, complement, totalOverlap, unionIntervals, mkIv, clipInto, overlapMin } from '../main/ets/merge/IntervalOps';

export default function intervalOpsTest() {
  describe('intervalOps', () => {
    it('merge_overlapping_and_adjacent', 0, () => {
      const r = mergeIntervals([mkIv(10, 20, 'A'), mkIv(15, 25, 'B'), mkIv(25, 30, 'C'), mkIv(40, 50, 'D')]);
      expect(r.length).assertEqual(2);
      expect(r[0].start).assertEqual(10);
      expect(r[0].end).assertEqual(30);
      expect(r[1].start).assertEqual(40);
    });

    it('merge_drops_invalid', 0, () => {
      const r = mergeIntervals([mkIv(10, 10, 'A'), mkIv(20, 5, 'B')]);
      expect(r.length).assertEqual(0);
    });

    it('complement_basic', 0, () => {
      const busy = mergeIntervals([mkIv(100, 200, 'A'), mkIv(300, 400, 'B')]);
      const free = complement(busy, 0, 500);
      expect(free.length).assertEqual(3);
      expect(free[0].start).assertEqual(0);
      expect(free[0].end).assertEqual(100);
      expect(free[1].start).assertEqual(200);
      expect(free[1].end).assertEqual(300);
      expect(free[2].start).assertEqual(400);
      expect(free[2].end).assertEqual(500);
    });

    it('complement_full_and_empty', 0, () => {
      const full = complement(mergeIntervals([mkIv(0, 100, 'A')]), 0, 100);
      expect(full.length).assertEqual(0);
      const empty = complement([], 0, 100);
      expect(empty.length).assertEqual(1);
      expect(empty[0].end - empty[0].start).assertEqual(100);
    });

    it('union_two_lists', 0, () => {
      const u = unionIntervals([mkIv(0, 50, 'A')], [mkIv(40, 80, 'B')]);
      expect(u.length).assertEqual(1);
      expect(u[0].end).assertEqual(80);
    });

    it('totalOverlap', 0, () => {
      const t = totalOverlap([mkIv(0, 60, 'A'), mkIv(50, 120, 'B'), mkIv(200, 220, 'C')], 0, 1440);
      expect(t).assertEqual(140);
    });

    it('overlapMin', 0, () => {
      expect(overlapMin(0, 10, 5, 20)).assertEqual(5);
      expect(overlapMin(0, 10, 10, 20)).assertEqual(0);
    });

    it('clip_into_treats_touching_as_empty', 0, () => {
      // 相接不算：`[0,10)` 裁进 `[10,20)` 得空，而不是零长度那一段
      expect(clipInto(0, 10, 10, 20) == null).assertTrue();
      expect(clipInto(10, 20, 0, 10) == null).assertTrue();
      expect(clipInto(5, 5, 0, 10) == null).assertTrue();
      const left = clipInto(0, 10, 5, 20);
      if (left != null) {
        expect(left.start).assertEqual(5);
        expect(left.end).assertEqual(10);
      }
      const wrapped = clipInto(3, 7, 0, 100);
      if (wrapped != null) {
        expect(wrapped.start).assertEqual(3);
        expect(wrapped.end).assertEqual(7);
      }
      // 三份读数共用这一个家：裁空 ⇒ overlapMin 为 0、totalOverlap 也不计数
      expect(overlapMin(0, 10, 10, 20)).assertEqual(0);
      expect(totalOverlap([mkIv(0, 10, 'A')], 10, 20)).assertEqual(0);
      expect(totalOverlap([mkIv(0, 10, 'A')], 5, 20)).assertEqual(5);
      // 补集同理：忙碌段恰好压在窗口起点上，窗口开头不留一段零长度空闲
      const free = complement(mergeIntervals([mkIv(0, 100, 'A'), mkIv(100, 200, 'B')]), 100, 300);
      expect(free.length).assertEqual(1);
      expect(free[0].start).assertEqual(200);
    });
  });
}
