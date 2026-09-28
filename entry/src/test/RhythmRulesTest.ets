import { describe, it, expect } from '@ohos/hypium';
import { HORIZON_MAX_DAYS } from 'domain';
import {
  greetingOf, horizonError, horizonLabel, HORIZON_MAX, isCrossMidnight, NIGHT_MODE_LABELS,
  nightModeHint, nightModeIndex, nightModeOf, rhythmError
} from 'feature';

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

    it('the_gate_ceiling_is_the_number_the_engine_expands_to', 0, () => {
      // 上限不写第二份：设置页放行的那个数，就是引擎按日展开真正会算到头的那个数（D-57）。
      // 分家之后的形状是"保存得进去、算不出来"，画面上一句"未来 17 个月"底下只算了 12 个月。
      expect(HORIZON_MAX).assertEqual(HORIZON_MAX_DAYS);
      expect(horizonError('' + HORIZON_MAX_DAYS)).assertEqual('');
      expect(horizonError('' + (HORIZON_MAX_DAYS + 1)) === '').assertFalse();
    });

    it('horizon_label_reads_the_ceiling_not_the_stored_number', 0, () => {
      // 设置页有校验，但 Preferences 里那份 JSON 可能是备份/换机从别的版本带回来的：
      // 念的时候先收进引擎真正会算的天数，否则那句"未来 N 天"是一句兑现不了的承诺。
      expect(horizonLabel(HORIZON_MAX_DAYS + 134)).assertEqual('未来 12 个月');
      expect(horizonLabel(0)).assertEqual('未来 1 天');
      // 合法值照原样念，这一格只加"收拢"那一半
      expect(horizonLabel(120)).assertEqual('未来 4 个月');
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

    it('greeting_has_a_small_hours_bucket_before_noon', 0, () => {
      // D-39：0–4 点原来被 hour < 13 那一支接住，凌晨两点首页念「中午好」
      expect(greetingOf(0)).assertEqual('凌晨好');
      expect(greetingOf(2)).assertEqual('凌晨好');
      expect(greetingOf(4)).assertEqual('凌晨好');
      // 两端边界：05:00 归早上好，23:00 归夜深了
      expect(greetingOf(5)).assertEqual('早上好');
      expect(greetingOf(10)).assertEqual('早上好');
      expect(greetingOf(11)).assertEqual('中午好');
      expect(greetingOf(12)).assertEqual('中午好');
      expect(greetingOf(13)).assertEqual('下午好');
      expect(greetingOf(17)).assertEqual('下午好');
      expect(greetingOf(18)).assertEqual('晚上好');
      expect(greetingOf(22)).assertEqual('晚上好');
      expect(greetingOf(23)).assertEqual('夜深了');
    });
    it('night_mode_round_trips_including_the_third_value', 0, () => {
      // D-33：值 2（不触发夜班恢复）原来在编辑页被折成 0，下一次保存静默改掉它
      expect(nightModeIndex(0)).assertEqual(0);
      expect(nightModeIndex(1)).assertEqual(1);
      expect(nightModeIndex(2)).assertEqual(2);
      // 三档各自原值往返：编辑→保存→再读回来还是同一档
      expect(nightModeOf(nightModeIndex(0))).assertEqual(0);
      expect(nightModeOf(nightModeIndex(1))).assertEqual(1);
      expect(nightModeOf(nightModeIndex(2))).assertEqual(2);
      // 认不出的值（将来的新档、坏数据）落回自动档，而不是选中越界
      expect(nightModeIndex(7)).assertEqual(0);
      expect(nightModeIndex(-1)).assertEqual(0);
      expect(nightModeOf(5)).assertEqual(0);
      // 档位数量是"下标即值"这条不变量的前提，也是三行下拉文字的数量
      expect(NIGHT_MODE_LABELS.length).assertEqual(3);
      expect(NIGHT_MODE_LABELS[2]).assertEqual('不触发夜班恢复');
      // 每一档都得有自己的说明，不能只有中间那档带解释
      expect(nightModeHint(0) === nightModeHint(2)).assertFalse();
      expect(nightModeHint(2).indexOf('不生成恢复块') >= 0).assertTrue();
    });
  });
}
