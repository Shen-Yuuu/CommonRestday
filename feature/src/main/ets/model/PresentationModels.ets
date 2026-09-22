import { WindowChannel } from 'domain';

export { WindowChannel };

/**
 * 页面读模型：UI 只消费本文件的类型，不导入 domain 计算结果或 data 仓储。
 * 枚举负责语义、文案由 feature 查询服务填充（枚举与文案分离）。
 *
 * 体验形态：决定首页三答案的口径与"TA"相关入口是否出现。
 */
export enum ExperienceMode {
  SOLO = 'SOLO',
  LOCAL_PARTNER = 'LOCAL_PARTNER',
  PAIRED = 'PAIRED'
}

/** 答案可用性：UNKNOWN=缺少对方数据，STALE=计算结果已过期（两者文案不同，不得合并）。 */
export enum AnswerState {
  AVAILABLE = 'AVAILABLE',
  UNAVAILABLE = 'UNAVAILABLE',
  UNKNOWN = 'UNKNOWN',
  STALE = 'STALE'
}

/** 首页三答案。 */
export enum AnswerKind {
  TONIGHT = 'TONIGHT',
  FULL_REST_DAY = 'FULL_REST_DAY',
  TRIP = 'TRIP'
}

/** 答案行点击后的跳转意图（页面不自行推断跳转目标）。 */
export enum AnswerAction {
  OPEN_WINDOW = 'OPEN_WINDOW',
  OPEN_SCHEDULE = 'OPEN_SCHEDULE',
  OPEN_PARTNER = 'OPEN_PARTNER'
}

/** 共同时间页筛选（精简版五档）。 */
export enum WindowFilterKey {
  ALL = 'ALL',
  GTE_2H = 'GTE_2H',
  FULL_DAY = 'FULL_DAY',
  WEEKEND = 'WEEKEND',
  TRIP = 'TRIP'
}

/**
 * 单个共同时间窗口的展示模型。channel 来自 domain 计算结果，不得由 tags 反推。
 * tags 是全量领域标签（筛选与详情页用）；displayTags 是压缩后的卡片标签。
 */
export interface WindowSummary {
  start: number;
  end: number;
  durationMin: number;
  tags: string[];
  /** 卡片展示标签：最多三个（完整同休日 / 周末 / 可出行），取值仍是 WindowTag。 */
  displayTags: string[];
  channel: WindowChannel;
  title: string;
  subtitle: string;
}

/** 首页一条答案（今晚 / 完整同休日 / 可出行）。 */
export interface QuickAnswer {
  kind: AnswerKind;
  state: AnswerState;
  headline: string;
  supportingText: string;
  windowStart: number;
  windowEnd: number;
  action: AnswerAction;
}

/** 首页"今天"概览三行。 */
export interface TodaySummary {
  myText: string;
  partnerText: string;
  commonText: string;
}

/** 首页整体读模型。 */
export interface HomeSummary {
  mode: ExperienceMode;
  partnerName: string;
  tonight: QuickAnswer;
  fullRestDay: QuickAnswer;
  trip: QuickAnswer;
  nextWindow: WindowSummary | null;
  conflictCount: number;
  today: TodaySummary;
  computedAt: number;
  stale: boolean;
}

/** 共同时间页查询条件。fromEpochMin 为本地平铺起点（含）。 */
export interface WindowFilter {
  key: WindowFilterKey;
  fromEpochMin: number;
}

/** 计划条目展示模型。 */
export interface PlanSummary {
  id: string;
  title: string;
  start: number;
  end: number;
  status: string;
  conflictText: string;
}

/**
 * 共同时间页整体读模型。
 * windows 是当前筛选下的全部窗口（两个通道都在内，周历按日绘制用它）；
 * rows 是列表展示行：同一天只留最长的一段，常规与旅行通道的重叠顺带去重。
 */
export interface CommonTimePageData {
  rows: WindowSummary[];
  windows: WindowSummary[];
  plans: PlanSummary[];
  mode: ExperienceMode;
  partnerName: string;
  /** 已配对/代录却拿不到对方数据时为 false：此时窗口只是"我的空闲"，不能宣称共同时间。 */
  partnerKnown: boolean;
  computedAt: number;
  stale: boolean;
}

/** 窗口详情读模型（含双方忙闲说明与对方隐私等级，用于差异化渲染）。 */
export interface WindowDetailData {
  window: WindowSummary;
  myBusyText: string;
  partnerBusyText: string;
  partnerShareLevel: number;
}
