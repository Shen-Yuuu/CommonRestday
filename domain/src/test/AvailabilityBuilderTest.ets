import { describe, it, expect } from '@ohos/hypium';
import { defaultParams, MIN_PER_DAY, ShiftType, ShiftInstance } from '../main/ets/model/Types';
import { shiftToBlocks, isNightShift, buildNotAvailable } from '../main/ets/buffer/AvailabilityBuilder';
import { mkIv } from '../main/ets/merge/IntervalOps';

function dayShift(): ShiftType {
  const c: ShiftType = {
    id: 'day', name: '白班', color: '#FF8800', startMin: 540, endMin: 1080, crossDay: false,
    commuteInMin: 30, commuteOutMin: 20, recoveryMin: 0, nightMode: 0,
    allowActivity: false, kind: 'WORK'
  };
  return c;
}

function nightShift(): ShiftType {
  const c: ShiftType = {
    id: 'night', name: '夜班', color: '#2244AA', startMin: 1350, endMin: 480, crossDay: true,
    commuteInMin: 0, commuteOutMin: 40, recoveryMin: 360, nightMode: 0,
    allowActivity: false, kind: 'WORK'
  };
  return c;
}

function inst(day: number, id: string): ShiftInstance {
  const i: ShiftInstance = { epochDay: day, typeId: id };
  return i;
}

export default function availabilityBuilderTest() {
  describe('availabilityBuilder', () => {
    it('day_shift_commute_padding', 0, () => {
      const blocks = shiftToBlocks(inst(0, 'day'), dayShift(), defaultParams());
      expect(blocks.length).assertEqual(1);
      expect(blocks[0].start).assertEqual(540 - 30); // 前通勤
      expect(blocks[0].end).assertEqual(1080 + 20);  // 后通勤
    });

    it('night_shift_cross_day_and_recovery', 0, () => {
      const blocks = shiftToBlocks(inst(0, 'night'), nightShift(), defaultParams());
      expect(blocks.length).assertEqual(2);
      expect(blocks[0].start).assertEqual(1350);
      expect(blocks[0].end).assertEqual(480 + MIN_PER_DAY + 40); // 次日 08:40
      expect(blocks[1].tag).assertEqual('RECOVERY');
      expect(blocks[1].start).assertEqual(480 + MIN_PER_DAY + 40);
      expect(blocks[1].end).assertEqual(480 + MIN_PER_DAY + 40 + 360); // 次日 14:40
    });

    it('night_detection', 0, () => {
      expect(isNightShift(inst(0, 'night'), nightShift(), defaultParams())).assertTrue();
      expect(isNightShift(inst(0, 'day'), dayShift(), defaultParams())).assertFalse();
    });

    it('night_mode_force', 0, () => {
      const c = dayShift();
      c.nightMode = 1;
      expect(isNightShift(inst(0, 'day'), c, defaultParams())).assertTrue();
      const n = nightShift();
      n.nightMode = 2;
      expect(isNightShift(inst(0, 'night'), n, defaultParams())).assertFalse();
    });

    it('not_available_winddown_and_sleep', 0, () => {
      // 真忙 [600,1200]，收整 20 → [600,1220]；作息 wake=420 bed=1350
      const na = buildNotAvailable([mkIv(600, 1200, 'WORK')], 420, 1350, 20, 0, 1);
      const m = na;
      // 合并后：[0,420] + [600,1220] + [1350,1440]
      expect(m.length).assertEqual(3);
      expect(m[0].start).assertEqual(0);
      expect(m[0].end).assertEqual(420);
      expect(m[1].start).assertEqual(600);
      expect(m[1].end).assertEqual(1220);
      expect(m[2].start).assertEqual(1350);
      expect(m[2].end).assertEqual(1440);
    });

    it('night_window_cross_midnight_config', 0, () => {
      // 夜窗配置 22:00–05:00（nightEnd < nightStart，跨零点）
      const p = defaultParams();
      p.nightStartMin = 1320;
      p.nightEndMin = 300;
      // 23:00–07:00（end <= start 自动跨天）→ 夜班
      const overnight: ShiftType = {
        id: 'ov', name: '通宵', color: '#111111', startMin: 1380, endMin: 420, crossDay: false,
        commuteInMin: 0, commuteOutMin: 0, recoveryMin: 60, nightMode: 0,
        allowActivity: false, kind: 'WORK'
      };
      expect(isNightShift(inst(0, 'ov'), overnight, p)).assertTrue();
      // 02:00–04:00（落在前一日 22:00 起的夜窗内）→ 夜班
      const dawn: ShiftType = {
        id: 'dawn', name: '凌晨', color: '#222222', startMin: 120, endMin: 240, crossDay: false,
        commuteInMin: 0, commuteOutMin: 0, recoveryMin: 60, nightMode: 0,
        allowActivity: false, kind: 'WORK'
      };
      expect(isNightShift(inst(0, 'dawn'), dawn, p)).assertTrue();
      // 21:00–23:00（与当日 22:00 起的夜窗相交）→ 夜班
      const evening: ShiftType = {
        id: 'eve', name: '晚班', color: '#333333', startMin: 1260, endMin: 1380, crossDay: false,
        commuteInMin: 0, commuteOutMin: 0, recoveryMin: 60, nightMode: 0,
        allowActivity: false, kind: 'WORK'
      };
      expect(isNightShift(inst(0, 'eve'), evening, p)).assertTrue();
      // 09:00–18:00 → 非夜班
      expect(isNightShift(inst(0, 'day'), dayShift(), p)).assertFalse();
    });

    it('night_window_zero_length_config', 0, () => {
      // nightStart === nightEnd 视为未配置夜窗
      const p = defaultParams();
      p.nightStartMin = 300;
      p.nightEndMin = 300;
      expect(isNightShift(inst(0, 'night'), nightShift(), p)).assertFalse();
    });

    it('bed_crossing_midnight', 0, () => {
      // 就寝 01:00（=1500，即 1440+60）：次日凌晨并入不可用
      const na = buildNotAvailable([], 420, 1500, 0, 0, 2);
      // 第0天早晨 [0,420] 必须存在
      let foundMorning1 = false;
      // [1440,1500] 必须被某个不可用区间完整覆盖（可能与次日清晨区间合并）
      let coveredNext01 = false;
      for (let i = 0; i < na.length; i++) {
        if (na[i].start === 0 && na[i].end === 420) {
          foundMorning1 = true;
        }
        if (na[i].start <= 1440 && na[i].end >= 1500) {
          coveredNext01 = true;
        }
      }
      expect(foundMorning1).assertTrue();
      expect(coveredNext01).assertTrue();
    });
  });
}
