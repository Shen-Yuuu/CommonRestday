/**
 * 计划类型（key 持久化到 plan.kind，label 只用于展示）。
 *
 * 可选分类与历史兼容表分开维护；分类不改变计划的时间计算和周历配色。
 */

/** 计划类型选项。 */
export interface PlanKindOption {
  key: string;
  label: string;
}

/**
 * 「其他」沿用它原来的 key：换一个新 key 就等于要求迁移历史行，
 * 而这里要的恰恰是"旧数据一行都不动"。它没有自己的默认标题，切换时保留当前标题，
 * 用户仍可自行修改；空标题由 planDraftError 挡住。
 */
export const OTHER_PLAN_KIND_KEY: string = 'custom';

/** 创建计划时可选的类型。 */
export const PLAN_KINDS: PlanKindOption[] = [
  { key: 'meal', label: '吃饭' },
  { key: 'movie', label: '看电影' },
  { key: 'walk', label: '散步' },
  { key: 'shopping', label: '购物' },
  { key: 'trip', label: '出游' },
  { key: OTHER_PLAN_KIND_KEY, label: '其他' }
];

/** 旧类型的展示兼容表：只用于读历史数据，不再作为选项出现。 */
const LEGACY_PLAN_KINDS: PlanKindOption[] = [
  { key: 'pickup', label: '接送孩子' },
  { key: 'parents', label: '回父母家' },
  { key: 'errand', label: '办证体检' },
  { key: 'study', label: '共同自习' }
];

/** kind → 展示文案；两份清单都不认识时原样返回，宁可显示原始值也不留空。 */
export function planKindLabel(kind: string): string {
  for (let i = 0; i < PLAN_KINDS.length; i++) {
    if (PLAN_KINDS[i].key === kind) {
      return PLAN_KINDS[i].label;
    }
  }
  for (let i = 0; i < LEGACY_PLAN_KINDS.length; i++) {
    if (LEGACY_PLAN_KINDS[i].key === kind) {
      return LEGACY_PLAN_KINDS[i].label;
    }
  }
  return kind;
}
