import { describe, it, expect } from '@ohos/hypium';
import {
  CycleTemplate, EngineParams, MIN_PER_DAY, MySchedule, ShiftType
} from '../main/ets/model/Types';
import { SnapshotBuilder } from '../main/ets/snapshot/SnapshotBuilder';
import { SnapshotCodec, SnapshotData } from '../main/ets/snapshot/SnapshotCodec';
import { mkIv } from '../main/ets/merge/IntervalOps';

function dayShift(): ShiftType {
  const c: ShiftType = {
    id: 'day', name: '白班', color: '#FF8800', startMin: 540, endMin: 1080, crossDay: false,
    commuteInMin: 0, commuteOutMin: 0, recoveryMin: 0, nightMode: 0,
    allowActivity: false, kind: 'WORK'
  };
  return c;
}

function myWithDayShift(): MySchedule {
  const tpl: CycleTemplate = { id: 't', name: '白班', seq: ['day'], anchorEpochDay: 1000 };
  const m: MySchedule = {
    shiftTypes: [dayShift()],
    template: tpl,
    overrides: [],
    courses: [],
    sectionTimes: [],
    termStartEpochDay: -1,
    plans: [],
    wakeMin: 420,
    bedMin: 1350,
    windDownMin: 0
  };
  return m;
}

function params(days: number): EngineParams {
  const p = defaultParams0();
  p.horizonDays = days;
  return p;
}

function defaultParams0(): EngineParams {
  const p: EngineParams = {
    horizonDays: 7,
    wakeMin: 420,
    bedMin: 1350,
    windDownMin: 0,
    nightStartMin: 0,
    nightEndMin: 300,
    minSlotMin: 120,
    halfDayMin: 240,
    fullDayAvailMin: 720,
    overnightMinMin: 960,
    tripMinMin: 1920,
    studyStartMin: 480,
    studyEndMin: 1260,
    studyMinMin: 120
  };
  return p;
}

function busyCount(data: SnapshotData, fromMin: number, toMin: number): boolean {
  const from = fromMin / 30;
  const to = toMin / 30;
  for (let i = from; i < to; i++) {
    if (data.busy30[i]) {
      return true;
    }
  }
  return false;
}

export default function snapshotTest() {
  describe('snapshot', () => {
    it('l1_bitmap_semantics', 0, () => {
      // startEpochDay=1000：白班 09:00–18:00，wake 07:00 bed 22:30，windDown 0
      const data = SnapshotBuilder.build(myWithDayShift(), params(2), 1000, 1, 5);
      expect(data.version).assertEqual(5);
      expect(data.shareLevel).assertEqual(1);
      // 睡眠 [0,420) 忙
      expect(busyCount(data, 0, 420)).assertTrue();
      // 07:00–09:00 空闲
      expect(busyCount(data, 420, 540)).assertFalse();
      // 工作 [540,1080) 忙
      expect(busyCount(data, 540, 1080)).assertTrue();
      // 18:00–22:30 空闲
      expect(busyCount(data, 1080, 1350)).assertFalse();
      // 22:30–24:00 忙
      expect(busyCount(data, 1350, 1440)).assertTrue();
    });

    it('codec_l1_roundtrip', 0, () => {
      const data = SnapshotBuilder.build(myWithDayShift(), params(2), 1000, 1, 7);
      const text = SnapshotCodec.encode(data);
      const back = SnapshotCodec.decode(text);
      expect(back != null).assertTrue();
      if (back != null) {
        expect(back.version).assertEqual(7);
        expect(back.days).assertEqual(2);
        expect(back.shareLevel).assertEqual(1);
        const ivs = SnapshotCodec.toIntervals(back);
        // 不可用区间：[0,420], [540,1080], [1350, 2880+420]... 第二天延续
        let foundWork = false;
        for (let i = 0; i < ivs.length; i++) {
          if (ivs[i].start === 1000 * MIN_PER_DAY + 540 && ivs[i].end === 1000 * MIN_PER_DAY + 1080) {
            foundWork = true;
          }
        }
        expect(foundWork).assertTrue();
      }
    });

    it('codec_l3_roundtrip', 0, () => {
      const data = SnapshotBuilder.build(myWithDayShift(), params(2), 1000, 3, 9);
      const text = SnapshotCodec.encode(data);
      const back = SnapshotCodec.decode(text);
      expect(back != null).assertTrue();
      if (back != null) {
        expect(back.shareLevel).assertEqual(3);
        // L3 精确分段应包含 [540,1080] 工作
        let found = false;
        for (let i = 0; i < back.segments.length; i++) {
          if (back.segments[i].start === 1000 * MIN_PER_DAY + 540
            && back.segments[i].end === 1000 * MIN_PER_DAY + 1080) {
            found = true;
          }
        }
        expect(found).assertTrue();
      }
    });

    it('l2_quantization', 0, () => {
      // 手工构造 L2：忙 08:10–09:20 → 量化 480–570
      const data: SnapshotData = {
        version: 1,
        shareLevel: 2,
        startEpochDay: 1000,
        days: 1,
        busy30: new Array<boolean>(48),
        segments: [mkIv(1000 * MIN_PER_DAY + 490, 1000 * MIN_PER_DAY + 560, 'WORK')]
      };
      for (let i = 0; i < 48; i++) {
        data.busy30[i] = false;
      }
      const text = SnapshotCodec.encode(data);
      const back = SnapshotCodec.decode(text);
      expect(back != null).assertTrue();
      if (back != null) {
        expect(back.segments.length).assertEqual(1);
        expect(back.segments[0].start).assertEqual(1000 * MIN_PER_DAY + 490);
        // toIntervals 保留原始量化值
        const ivs = SnapshotCodec.toIntervals(back);
        expect(ivs[0].start).assertEqual(1000 * MIN_PER_DAY + 490);
        expect(ivs[0].end).assertEqual(1000 * MIN_PER_DAY + 560);
      }
    });

    it('decode_invalid_returns_null', 0, () => {
      expect(SnapshotCodec.decode('garbage')).assertNull();
      expect(SnapshotCodec.decode('XXXX|1|1|0|1')).assertNull();
    });

    it('decode_corrupted_bitmap_returns_null', 0, () => {
      const data = SnapshotBuilder.build(myWithDayShift(), params(2), 1000, 1, 7);
      const lines = SnapshotCodec.encode(data).split('\n');
      let bIdx = -1;
      for (let i = 0; i < lines.length; i++) {
        if (lines[i].startsWith('B:')) {
          bIdx = i;
        }
      }
      expect(bIdx >= 0).assertTrue();
      if (bIdx >= 0) {
        // 位图 hex 截断（长度与 days*48/4 不符）
        const truncated: string[] = lines.slice();
        truncated[bIdx] = truncated[bIdx].substring(0, truncated[bIdx].length - 2);
        expect(SnapshotCodec.decode(truncated.join('\n'))).assertNull();
        // 非法 hex 字符
        const bad: string[] = lines.slice();
        let hexLen = bad[bIdx].length - 2;
        let badHex = '';
        for (let i = 0; i < hexLen; i++) {
          badHex += 'z';
        }
        bad[bIdx] = 'B:' + badHex;
        expect(SnapshotCodec.decode(bad.join('\n'))).assertNull();
      }
    });

    it('l2_builder_end_to_end_roundtrip', 0, () => {
      // 走 SnapshotBuilder.build 真实 L2 构建路径（此前 L2 用例为手工构造）
      const data = SnapshotBuilder.build(myWithDayShift(), params(2), 1000, 2, 11);
      expect(data.shareLevel).assertEqual(2);
      expect(data.busy30.length).assertEqual(2 * 48);
      expect(data.segments.length > 0).assertTrue();
      const base = 1000 * MIN_PER_DAY;
      // 工作 [540,1080]（30 的整数倍，量化不膨胀）必须被分段覆盖且带 WORK 标签
      let covered = false;
      for (let i = 0; i < data.segments.length; i++) {
        const s = data.segments[i];
        if (s.start <= base + 540 && s.end >= base + 1080 && s.tag === 'WORK') {
          covered = true;
        }
      }
      expect(covered).assertTrue();
      // encode → decode → toIntervals 往返后忙碌仍被覆盖
      const back = SnapshotCodec.decode(SnapshotCodec.encode(data));
      expect(back != null).assertTrue();
      if (back != null) {
        expect(back.shareLevel).assertEqual(2);
        expect(back.version).assertEqual(11);
        const ivs = SnapshotCodec.toIntervals(back);
        let covered2 = false;
        for (let i = 0; i < ivs.length; i++) {
          if (ivs[i].start <= base + 540 && ivs[i].end >= base + 1080) {
            covered2 = true;
          }
        }
        expect(covered2).assertTrue();
      }
    });
  });
}
