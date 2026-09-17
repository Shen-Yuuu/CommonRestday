/** 计划类型选项（key 持久化到 plan.kind，label 用于展示）；PlansView / WindowDetailSheet / DayDetailSheet 共用。 */
export interface PlanKindOption {
  key: string;
  label: string;
}

/** 计划类型清单（与 plan.kind 存储值一一对应）。 */
export const PLAN_KINDS: PlanKindOption[] = [
  { key: 'meal', label: '一起吃饭' },
  { key: 'movie', label: '看电影' },
  { key: 'pickup', label: '接送孩子' },
  { key: 'parents', label: '回父母家' },
  { key: 'errand', label: '办证体检' },
  { key: 'trip', label: '短途旅行' },
  { key: 'study', label: '共同自习' },
  { key: 'custom', label: '自定义' }
];

/** kind → 展示文案；未知类型原样返回。 */
export function planKindLabel(kind: string): string {
  for (let i = 0; i < PLAN_KINDS.length; i++) {
    if (PLAN_KINDS[i].key === kind) {
      return PLAN_KINDS[i].label;
    }
  }
  return kind;
}

/** kind → 选项下标；未知类型回退"自定义"（最后一项）。 */
export function planKindIndex(key: string): number {
  for (let i = 0; i < PLAN_KINDS.length; i++) {
    if (PLAN_KINDS[i].key === key) {
      return i;
    }
  }
  return PLAN_KINDS.length - 1;
}
