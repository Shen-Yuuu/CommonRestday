/**
 * 计划类型（key 持久化到 plan.kind，label 只用于展示）。
 *
 * 清单分成两份是因为两件事各自在变：**能选什么**（首发按验收报告 §5 D1 精简为两项）
 * 与**已经存过的 key 怎么念**（旧类型继续显示，不做数据迁移）。合成一份的话，
 * 每次收窄选项都会让历史计划的类型变成空白或裸英文码。
 */

/** 计划类型选项。 */
export interface PlanKindOption {
  key: string;
  label: string;
}

/**
 * 「其他」沿用它原来的 key：换一个新 key 就等于要求迁移历史行，
 * 而这里要的恰恰是"旧数据一行都不动"。它没有默认标题，标题必须用户自填
 * （空标题由 planDraftError 挡住）。
 */
export const OTHER_PLAN_KIND_KEY: string = 'custom';

/** 创建计划时可选的类型。 */
export const PLAN_KINDS: PlanKindOption[] = [
  { key: 'meal', label: '一起吃饭' },
  { key: OTHER_PLAN_KIND_KEY, label: '其他' }
];

/** 旧类型的展示兼容表：只用于读历史数据，不再作为选项出现。 */
const LEGACY_PLAN_KINDS: PlanKindOption[] = [
  { key: 'movie', label: '看电影' },
  { key: 'pickup', label: '接送孩子' },
  { key: 'parents', label: '回父母家' },
  { key: 'errand', label: '办证体检' },
  { key: 'trip', label: '短途旅行' },
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
