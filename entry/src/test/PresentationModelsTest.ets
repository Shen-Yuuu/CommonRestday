import { describe, it, expect } from '@ohos/hypium';
import {
  AnswerAction, AnswerKind, AnswerState, CommonTimePageData, ExperienceMode, FeatureFlags,
  HomeSummary, PlanSummary, QuickAnswer, TodaySummary, WindowChannel, WindowDetailData,
  WindowFilter, WindowFilterKey, WindowSummary
} from 'feature';

/**
 * 页面读模型契约测试：形状与枚举取值必须稳定（枚举承载语义，文案由查询服务填充）。
 */

function mkSummary(start: number, end: number, channel: WindowChannel, tags: string[]): WindowSummary {
  const s: WindowSummary = {
    start: start, end: end, durationMin: end - start, tags: tags, channel: channel,
    title: '周六 07:00 起 15小时30分', subtitle: '含晚餐 · 完整同休日'
  };
  return s;
}

function mkAnswer(kind: AnswerKind, state: AnswerState): QuickAnswer {
  const a: QuickAnswer = {
    kind: kind, state: state, headline: '今晚 19:00 可以一起吃',
    supportingText: '距现在 3 小时', windowStart: 1080, windowEnd: 1260, action: AnswerAction.OPEN_WINDOW
  };
  return a;
}

function mkHome(mode: ExperienceMode): HomeSummary {
  const today: TodaySummary = { myText: '今天 07:00 后有课', partnerText: '今天全天空闲', commonText: '共同空闲 4 小时' };
  const h: HomeSummary = {
    mode: mode,
    partnerName: '小陈',
    tonight: mkAnswer(AnswerKind.TONIGHT, AnswerState.AVAILABLE),
    fullRestDay: mkAnswer(AnswerKind.FULL_REST_DAY, AnswerState.UNAVAILABLE),
    trip: mkAnswer(AnswerKind.TRIP, AnswerState.UNKNOWN),
    nextWindow: mkSummary(29822820, 29823750, WindowChannel.REGULAR, ['MEAL']),
    conflictCount: 2,
    today: today,
    computedAt: 29822000,
    stale: false
  };
  return h;
}

export default function presentationModelsTest() {
  describe('presentationModels', () => {
    it('enum_values_are_stable_wire_strings', 0, () => {
      // 这些取值会写进路由参数与卡片数据，改名即破坏兼容（toString 后比较，避免枚举与字符串混比）
      expect(WindowChannel.REGULAR.toString()).assertEqual('REGULAR');
      expect(WindowChannel.TRIP.toString()).assertEqual('TRIP');
      expect(ExperienceMode.SOLO.toString()).assertEqual('SOLO');
      expect(ExperienceMode.LOCAL_PARTNER.toString()).assertEqual('LOCAL_PARTNER');
      expect(ExperienceMode.PAIRED.toString()).assertEqual('PAIRED');
      expect(AnswerState.AVAILABLE.toString()).assertEqual('AVAILABLE');
      expect(AnswerState.UNAVAILABLE.toString()).assertEqual('UNAVAILABLE');
      expect(AnswerState.UNKNOWN.toString()).assertEqual('UNKNOWN');
      expect(AnswerState.STALE.toString()).assertEqual('STALE');
      expect(AnswerKind.TONIGHT.toString()).assertEqual('TONIGHT');
      expect(AnswerKind.FULL_REST_DAY.toString()).assertEqual('FULL_REST_DAY');
      expect(AnswerKind.TRIP.toString()).assertEqual('TRIP');
      expect(AnswerAction.OPEN_WINDOW.toString()).assertEqual('OPEN_WINDOW');
      expect(AnswerAction.OPEN_SCHEDULE.toString()).assertEqual('OPEN_SCHEDULE');
      expect(AnswerAction.OPEN_PARTNER.toString()).assertEqual('OPEN_PARTNER');
      expect(WindowFilterKey.ALL.toString()).assertEqual('ALL');
      expect(WindowFilterKey.GTE_2H.toString()).assertEqual('GTE_2H');
      expect(WindowFilterKey.FULL_DAY.toString()).assertEqual('FULL_DAY');
      expect(WindowFilterKey.WEEKEND.toString()).assertEqual('WEEKEND');
      expect(WindowFilterKey.TRIP.toString()).assertEqual('TRIP');
    });

    it('home_summary_covers_every_mode_without_repo', 0, () => {
      // 三种形态全部可表达：单人无伴侣文案、本机代录、云端配对
      const solo = mkHome(ExperienceMode.SOLO);
      solo.partnerName = '';
      solo.tonight.state = AnswerState.UNKNOWN;
      solo.trip.windowStart = 0;
      solo.trip.windowEnd = 0;
      expect(solo.mode).assertEqual(ExperienceMode.SOLO);
      expect(solo.nextWindow != null).assertTrue();

      const stale = mkHome(ExperienceMode.PAIRED);
      stale.stale = true;
      stale.tonight.state = AnswerState.STALE;
      expect(stale.stale).assertTrue();

      const local = mkHome(ExperienceMode.LOCAL_PARTNER);
      local.nextWindow = null;
      expect(local.nextWindow == null).assertTrue();
      expect(local.conflictCount).assertEqual(2);
    });

    it('channel_is_carried_independently_of_tags', 0, () => {
      // 通道是计算事实，不来自标签：空标签窗口仍可携带 TRIP 通道
      const trip = mkSummary(29822400, 29825280, WindowChannel.TRIP, []);
      expect(trip.channel).assertEqual(WindowChannel.TRIP);
      expect(trip.tags.length).assertEqual(0);
      // 同一起止的常规窗口必须与旅行窗口可区分（UI 据此决定"今晚/出行"归属）
      const regular = mkSummary(29822400, 29825280, WindowChannel.REGULAR, ['TRIP']);
      expect(regular.channel).assertEqual(WindowChannel.REGULAR);
      expect(regular.start).assertEqual(trip.start);
      expect(regular.end).assertEqual(trip.end);
    });

    it('answer_text_is_not_baked_into_enums', 0, () => {
      // 同一枚举值可承载不同文案：文案与枚举分离，切换语言不触碰语义
      const a = mkAnswer(AnswerKind.TONIGHT, AnswerState.AVAILABLE);
      const b = mkAnswer(AnswerKind.TONIGHT, AnswerState.AVAILABLE);
      b.headline = '今晚没空，明天 18:00 再约';
      b.supportingText = '与你夜班结束时间冲突';
      b.action = AnswerAction.OPEN_SCHEDULE;
      expect(a.kind).assertEqual(b.kind);
      expect(a.state).assertEqual(b.state);
      expect(a.headline === b.headline).assertFalse();
      expect(a.action === b.action).assertFalse();
    });

    it('page_and_detail_readmodels_are_self_contained', 0, () => {
      const plan: PlanSummary = {
        id: 'p1', title: '一起吃饭', start: 29823480, end: 29823570,
        status: 'CONFIRMED', conflictText: '与 TA 的课冲突'
      };
      const page: CommonTimePageData = {
        windows: [mkSummary(29822400, 29823330, WindowChannel.REGULAR, ['MEAL'])],
        plans: [plan], computedAt: 29822000, stale: false
      };
      expect(page.windows.length).assertEqual(1);
      expect(page.plans[0].conflictText).assertEqual('与 TA 的课冲突');

      const filter: WindowFilter = { key: WindowFilterKey.GTE_2H, fromEpochMin: 29822400 };
      expect(filter.key).assertEqual(WindowFilterKey.GTE_2H);

      const detail: WindowDetailData = {
        window: page.windows[0], myBusyText: '你 22:30 就寝', partnerBusyText: 'TA 的忙碌未知', partnerShareLevel: 1
      };
      expect(detail.partnerShareLevel).assertEqual(1);
      expect(detail.window.durationMin).assertEqual(930);
    });

    it('feature_flags_gate_unreleased_capabilities', 0, () => {
      // 未过阶段门禁的能力必须默认关闭（newShell 随 BuildProfile 构建模式映射，release 下为 false）
      expect(FeatureFlags.cloudPairing).assertFalse();
      expect(FeatureFlags.scanPairing).assertFalse();
      expect(FeatureFlags.newCard).assertFalse();
      expect(FeatureFlags.responsiveV2).assertFalse();
    });
  });
}
