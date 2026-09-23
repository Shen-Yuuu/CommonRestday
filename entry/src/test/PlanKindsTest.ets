import { describe, it, expect } from '@ohos/hypium';
import { OTHER_PLAN_KIND_KEY, PlanDraft, PLAN_KINDS, planDraftError, planKindLabel } from 'feature';

/**
 * 计划类型口径（阶段 6R.4 / 验收报告 §5 D1 定稿）：
 * 创建界面只露「一起吃饭 / 其他」两项，旧 8 类的 key 靠兼容表继续念得出来。
 * 「其他」刻意复用已有的 custom key——换 key 就等于迁移历史数据，而这里要的恰恰是不迁移。
 */

/** 历史数据里出现过的全部 key（顺序与旧清单一致）。 */
const LEGACY_KEYS: string[] = ['meal', 'movie', 'pickup', 'parents', 'errand', 'trip', 'study', 'custom'];

function draftOf(title: string, kind: string): PlanDraft {
  return { title: title, kind: kind, start: 600, end: 660 };
}

export default function planKindsTest() {
  describe('planKinds', () => {

    it('creation_offers_exactly_two_kinds', 0, () => {
      expect(PLAN_KINDS.length).assertEqual(2);
      expect(PLAN_KINDS[0].key).assertEqual('meal');
      expect(PLAN_KINDS[0].label).assertEqual('一起吃饭');
      expect(PLAN_KINDS[1].label).assertEqual('其他');
    });

    it('the_other_option_reuses_the_custom_key', 0, () => {
      // 新增 key 会让旧库里 'custom' 的行变成不认识的类型；复用同一个 key 才谈得上"不迁移"
      expect(PLAN_KINDS[1].key).assertEqual('custom');
      expect(PLAN_KINDS[1].key).assertEqual(OTHER_PLAN_KIND_KEY);
    });

    it('legacy_kind_labels_still_render', 0, () => {
      expect(planKindLabel('meal')).assertEqual('一起吃饭');
      expect(planKindLabel('movie')).assertEqual('看电影');
      expect(planKindLabel('pickup')).assertEqual('接送孩子');
      expect(planKindLabel('parents')).assertEqual('回父母家');
      expect(planKindLabel('errand')).assertEqual('办证体检');
      expect(planKindLabel('trip')).assertEqual('短途旅行');
      expect(planKindLabel('study')).assertEqual('共同自习');
      expect(planKindLabel('custom')).assertEqual('其他');
      // 兼容表必须覆盖全部历史 key：任何一个都不能退化成把原始英文码摊给用户看
      for (let i = 0; i < LEGACY_KEYS.length; i++) {
        expect(planKindLabel(LEGACY_KEYS[i]) !== LEGACY_KEYS[i]).assertTrue();
      }
    });

    it('unknown_kind_reads_itself_instead_of_going_blank', 0, () => {
      expect(planKindLabel('dance')).assertEqual('dance');
      expect(planKindLabel('')).assertEqual('');
    });

    it('the_other_kind_demands_a_written_title', 0, () => {
      // 「其他」没有默认名，标题为空就要被草稿校验挡回去（创建按钮因此不可用）
      expect(planDraftError(draftOf('  ', OTHER_PLAN_KIND_KEY), 600, 700)).assertEqual('请填写计划标题');
      expect(planDraftError(draftOf('一起自习', OTHER_PLAN_KIND_KEY), 600, 700)).assertEqual('');
    });
  });
}
