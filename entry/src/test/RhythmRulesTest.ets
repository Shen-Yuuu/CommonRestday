import { describe, it, expect } from '@ohos/hypium';
import { horizonError, horizonLabel, HORIZON_MAX, isCrossMidnight, rhythmError } from 'feature';

/**
 * 作息输入口径（阶段 1R / R2）：轮班与夜猫子的"就寝 00:30"必须能保存。
 * 起床 07:00 配就寝 01:00 在数值上"早于"起床，但语义是次日凌晨就寝，
 * 由领域层按跨零点解释；只有两者同一时刻才算非法。
 */
export default function rhythmRulesTest() {
  describe('rhythmRules', () => {

    it('normal_day_rhythm_is_valid', 0, () => {
      expect(rhythmError('07:00', '22:30', '20')).assertEqual('');
      expect(isCrossMidnight('07:00', '22:30')).assertFalse();
    });

    it('cross_midnight_bedtime_is_valid', 0, () => {
      // 00:30 与 01:00 都是"次日凌晨睡"，不能按数值大小拒收
      expect(rhythmError('07:00', '00:30', '20')).assertEqual('');
      expect(rhythmError('07:00', '01:00', '0')).assertEqual('');
      expect(isCrossMidnight('07:00', '01:00')).assertTrue();
      expect(isCrossMidnight('07:00', '00:30')).assertTrue();
    });

    it('late_shift_wake_after_bed_is_valid', 0, () => {
      // 下午起床上班、当晚就寝：起床数值大于就寝同样合法
      expect(rhythmError('16:00', '01:00', '30')).assertEqual('');
      expect(isCrossMidnight('16:00', '01:00')).assertTrue();
    });

    it('same_moment_is_the_only_order_error', 0, () => {
      expect(rhythmError('22:30', '22:30', '20') === '').assertFalse();
      expect(rhythmError('00:00', '00:00', '20') === '').assertFalse();
    });

    it('bad_formats_and_negative_buffer_are_rejected', 0, () => {
      expect(rhythmError('7点', '22:30', '20') === '').assertFalse();
      expect(rhythmError('07:00', '22:70', '20') === '').assertFalse();
      expect(rhythmError('07:00', '22:30', '-5') === '').assertFalse();
      expect(rhythmError('07:00', '22:30', '二十') === '').assertFalse();
    });

    it('horizon_bounds_use_the_same_numbers_as_copy', 0, () => {
      expect(horizonError('7')).assertEqual('');
      expect(horizonError('' + HORIZON_MAX)).assertEqual('');
      expect(horizonError('6') === '').assertFalse();
      expect(horizonError('367') === '').assertFalse();
      expect(horizonError('abc') === '').assertFalse();
      // 提示语里的区间数字要跟着常量走，避免文案与校验各说一套
      expect(horizonError('367').indexOf('7–366') >= 0).assertTrue();
    });

    it('horizon_label_rounds_to_months_and_keeps_short_views_in_days', 0, () => {
      // 默认视界 120 天念作"未来 4 个月"，与原型页头同一口径
      expect(horizonLabel(120)).assertEqual('未来 4 个月');
      expect(horizonLabel(366)).assertEqual('未来 12 个月');
      expect(horizonLabel(30)).assertEqual('未来 1 个月');
      // 不足一个月不折成"0 个月"：允许的最短视界就是"只看本周"那一档
      expect(horizonLabel(7)).assertEqual('未来 7 天');
      expect(horizonLabel(14)).assertEqual('未来 14 天');
    });
  });
}
