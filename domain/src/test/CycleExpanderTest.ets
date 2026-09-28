import { describe, it, expect } from '@ohos/hypium';
import { CycleTemplate, ScheduleOverride } from '../main/ets/model/Types';
import { expandCycle, cycleShiftAt } from '../main/ets/expand/CycleExpander';

function tpl(seq: string[], anchor: number): CycleTemplate {
  const t: CycleTemplate = { id: 't1', name: 'test', seq: seq, anchorEpochDay: anchor };
  return t;
}

function ov(day: number, id: string | null): ScheduleOverride {
  const o: ScheduleOverride = { epochDay: day, shiftTypeId: id };
  return o;
}

export default function cycleExpanderTest() {
  describe('cycleExpander', () => {
    it('basic_cycle_repeat', 0, () => {
      const t = tpl(['A', 'B', 'C'], 100);
      const r = expandCycle(t, [], 100, 5);
      expect(r.length).assertEqual(5);
      expect(r[0].typeId).assertEqual('A');
      expect(r[1].typeId).assertEqual('B');
      expect(r[2].typeId).assertEqual('C');
      expect(r[3].typeId).assertEqual('A');
      expect(r[4].typeId).assertEqual('B');
    });

    it('anchor_before_start', 0, () => {
      const t = tpl(['A', 'B', 'C'], 100);
      const r = expandCycle(t, [], 99, 1);
      expect(r.length).assertEqual(1);
      expect(r[0].typeId).assertEqual('C'); // (99-100+3)%3=2
    });

    it('override_replace_and_clear', 0, () => {
      const t = tpl(['A', 'B', 'A', 'A'], 100);
      const o1: ScheduleOverride[] = [ov(101, 'X'), ov(103, null)];
      const r = expandCycle(t, o1, 100, 4);
      expect(r.length).assertEqual(3);
      expect(r[0].typeId).assertEqual('A');
      expect(r[1].typeId).assertEqual('X');
      expect(r[2].typeId).assertEqual('A'); // 103 被清空跳过，102 正常
    });

    /**
     * D-55 第一条：null 覆盖是"这天强制休息"，不是"没有覆盖"。
     * 判据只能拿"有覆盖"与"无覆盖"两份展开**相减**——单看展开结果，涂成休息与本来排休长得一样。
     */
    it('clear_override_differs_from_no_override', 0, () => {
      const t = tpl(['A', 'B'], 100);
      const bare = expandCycle(t, [], 100, 3);
      const cleared = expandCycle(t, [ov(101, null)], 100, 3);
      expect(bare.length).assertEqual(3);
      expect(cleared.length).assertEqual(2);
      expect(cleared[0].epochDay).assertEqual(100);
      expect(cleared[1].epochDay).assertEqual(102); // 101 被涂成休息：循环层的 B 不露出来
    });

    /**
     * D-55 第二条：循环层缺位（seq 为空 / 没模板）只是推不出班，不许把覆盖层一起吃掉——
     * 「清空模板」后仍留在库里的涂班天要照原样画。
     */
    it('override_survives_empty_seq', 0, () => {
      const t = tpl([], 100);
      const r = expandCycle(t, [ov(100, 'X'), ov(101, null)], 100, 3);
      expect(r.length).assertEqual(1);
      expect(r[0].epochDay).assertEqual(100);
      expect(r[0].typeId).assertEqual('X');
    });

    it('cycleShiftAt_matches', 0, () => {
      const t = tpl(['A', 'B'], 100);
      expect(cycleShiftAt(t, 100)).assertEqual('A');
      expect(cycleShiftAt(t, 101)).assertEqual('B');
      expect(cycleShiftAt(t, 102)).assertEqual('A');
    });

    it('empty_seq_safe', 0, () => {
      const t = tpl([], 100);
      expect(expandCycle(t, [], 100, 3).length).assertEqual(0);
    });
  });
}
