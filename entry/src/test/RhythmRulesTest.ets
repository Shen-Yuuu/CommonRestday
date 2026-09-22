import { describe, it, expect } from '@ohos/hypium';
import { horizonError, HORIZON_MAX, isCrossMidnight, rhythmError } from 'feature';

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
  });
}
