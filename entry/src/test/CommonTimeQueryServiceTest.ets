import { describe, it, expect } from '@ohos/hypium';
import { Interval, MIN_PER_DAY, Window, WindowChannel, WindowTag } from 'domain';
import { PlanRow } from 'data';
import {
  AnswerAction, AnswerKind, AnswerState, CommonTimePageData, DayBusy, DetailInput, ExperienceMode,
  HomeInput, HomeSummary, PageInput, WindowDetailData, WindowFilter, WindowFilterKey,
  CommonTimeQueryService
} from 'feature';

/**
 * 答案优先查询服务契约测试：三类答案的口径、降级与新鲜度必须稳定。
 * 只驱动纯装配函数（assembleXxx / pickXxx），不触碰仓储，因此可离线运行。
 */

/** 2026-09-22（周二）为"今天"；epochDay 与本地日历日一一对应。 */
const DAY = 20718;
/** 今天 19:00。 */
const NOW = DAY * MIN_PER_DAY + 1140;
const DAY_START = DAY * MIN_PER_DAY;
const DAY_END = DAY_START + MIN_PER_DAY;

/** 本地日历日构造时间戳：避免测试随运行机器时区漂移。 */
function localMs(dayOffset: number, minuteOfDay: number): number {
  return new Date(2026, 8, 22 + dayOffset, 0, minuteOfDay, 0, 0).getTime();
}

const FRESH = localMs(0, 600);
const YESTERDAY = localMs(-1, 1200);

function win(startDay: number, startMin: number, endDay: number, endMin: number,
  channel: WindowChannel, tags: string[]): Window {
  const s = startDay * MIN_PER_DAY + startMin;
  const e = endDay * MIN_PER_DAY + endMin;
  const w: Window = { start: s, end: e, durationMin: e - s, tags: tags, channel: channel };
  return w;
}

function iv(day: number, startMin: number, endMin: number, tag: string): Interval {
  const i: Interval = { start: day * MIN_PER_DAY + startMin, end: day * MIN_PER_DAY + endMin, tag: tag };
  return i;
}

function plan(id: string, status: string, hint: string, startMin: number, endMin: number): PlanRow {
  const p: PlanRow = {
    start: DAY_START + startMin, end: DAY_START + endMin,
    id: id, title: '一起吃饭', kind: 'MEAL', status: status, createdBy: 'ME', windowRef: '',
    conflictHint: hint, myEventId: '', reminderId: -1, updatedAt: 0,
    calendarState: 'NOT_REQUESTED', syncState: 'LOCAL_ONLY'
  };
  return p;
}

function day(source: string, level: number, myBusy: Interval[], partnerBusy: Interval[] | null): DayBusy {
  const d: DayBusy = {
    epochDay: DAY, myBusy: myBusy, partnerBusy: partnerBusy,
    partnerSource: source, partnerShareLevel: level
  };
  return d;
}

function home(mode: ExperienceMode, windows: Window[], plans: PlanRow[], d: DayBusy,
  computedAt: number, partnerName: string): HomeSummary {
  const input: HomeInput = {
    mode: mode, partnerName: partnerName, windows: windows, plans: plans,
    day: d, computedAt: computedAt, nowEpochMin: NOW
  };
  return CommonTimeQueryService.assembleHome(input);
}

/** 无伴侣数据、当天只有一段晚间空闲的最小场景。 */
function soloDay(): DayBusy {
  return day('NONE', 0, [iv(DAY, 1350, 1860, 'SLEEP')], null);
}

function pageOf(all: Window[], key: WindowFilterKey): CommonTimePageData {
  const f: WindowFilter = { key: key, fromEpochMin: NOW };
  const input: PageInput = {
    windows: all, plans: [], filter: f, computedAt: FRESH, nowEpochMin: NOW
  };
  return CommonTimeQueryService.assemblePage(input);
}

const TONIGHT_W = win(DAY, 1170, DAY, 1350, WindowChannel.REGULAR, [WindowTag.MEAL]);
const FULL_W = win(DAY + 4, 420, DAY + 4, 1350, WindowChannel.REGULAR,
  [WindowTag.FULL_DAY, WindowTag.HALF_DAY]);
const OVERNIGHT_W = win(DAY + 6, 1080, DAY + 7, 600, WindowChannel.REGULAR, [WindowTag.OVERNIGHT_TRIP]);
const TRIP_W = win(DAY + 10, 480, DAY + 12, 1080, WindowChannel.REGULAR,
  [WindowTag.TRIP, WindowTag.TWO_DAYS]);

export default function commonTimeQueryServiceTest() {
  describe('commonTimeQueryService', () => {

    it('three_answers_use_their_own_rule', 0, () => {
      const h = home(ExperienceMode.PAIRED, [TONIGHT_W, FULL_W, OVERNIGHT_W, TRIP_W], [],
        day('SNAPSHOT', 3, [], []), FRESH, '小陈');

      // 今晚：当天剩余的常规窗口
      expect(h.tonight.kind).assertEqual(AnswerKind.TONIGHT);
      expect(h.tonight.state).assertEqual(AnswerState.AVAILABLE);
      expect(h.tonight.windowStart).assertEqual(TONIGHT_W.start);
      expect(h.tonight.windowEnd).assertEqual(TONIGHT_W.end);
      expect(h.tonight.headline.indexOf('19:30') >= 0).assertTrue();
      expect(h.tonight.action).assertEqual(AnswerAction.OPEN_WINDOW);

      // 完整同休日：只认 FULL_DAY 标签
      expect(h.fullRestDay.state).assertEqual(AnswerState.AVAILABLE);
      expect(h.fullRestDay.windowStart).assertEqual(FULL_W.start);
      expect(h.fullRestDay.headline.indexOf('完整同休日') >= 0).assertTrue();

      // 出行：TRIP 优先于更早出现的 OVERNIGHT_TRIP，并明确跨日天数
      expect(h.trip.state).assertEqual(AnswerState.AVAILABLE);
      expect(h.trip.windowStart).assertEqual(TRIP_W.start);
      expect(h.trip.headline.indexOf('3 天') >= 0).assertTrue();
      expect(h.trip.headline.indexOf('跨夜') >= 0).assertFalse();

      // 下个窗口只取常规通道里最近的一个
      const next = h.nextWindow;
      expect(next != null).assertTrue();
      if (next != null) {
        expect(next.start).assertEqual(TONIGHT_W.start);
        expect(next.channel).assertEqual(WindowChannel.REGULAR);
        expect(next.subtitle.indexOf('含餐点') >= 0).assertTrue();
      }

      expect(h.mode).assertEqual(ExperienceMode.PAIRED);
      expect(h.partnerName).assertEqual('小陈');
      expect(h.computedAt).assertEqual(FRESH);
      expect(h.stale).assertFalse();
    });

    it('tonight_is_not_hijacked_by_trip_channel', 0, () => {
      // 旅行通道窗口从今天 18:00 起横跨三天，起点比常规窗口更早
      const tripSpan = win(DAY, 1080, DAY + 2, 1200, WindowChannel.TRIP, [WindowTag.TRIP]);
      const regular = win(DAY, 1260, DAY, 1380, WindowChannel.REGULAR, []);

      const picked = CommonTimeQueryService.pickTonight([tripSpan, regular], NOW);
      expect(picked != null).assertTrue();
      if (picked != null) {
        expect(picked.start).assertEqual(regular.start);
        expect(picked.channel).assertEqual(WindowChannel.REGULAR);
      }

      // 只有旅行通道时，今晚必须回答"没有"，不能拿出行窗口顶替
      expect(CommonTimeQueryService.pickTonight([tripSpan], NOW) == null).assertTrue();

      const h = home(ExperienceMode.PAIRED, [tripSpan], [], day('SNAPSHOT', 3, [], []), FRESH, '小陈');
      expect(h.tonight.state).assertEqual(AnswerState.UNAVAILABLE);
      expect(h.tonight.windowStart).assertEqual(0);
      expect(h.tonight.action).assertEqual(AnswerAction.OPEN_SCHEDULE);
    });

    it('solo_still_answers_with_my_free_time', 0, () => {
      const h = home(ExperienceMode.SOLO, [TONIGHT_W], [], soloDay(), FRESH, '');

      expect(h.mode).assertEqual(ExperienceMode.SOLO);
      // 单人不是"缺数据"：三答案照常给结论，只是口径换成"我"
      expect(h.tonight.state).assertEqual(AnswerState.AVAILABLE);
      expect(h.tonight.headline.indexOf('我们') >= 0).assertFalse();
      expect(h.tonight.headline.indexOf('我') >= 0).assertTrue();
      expect(h.fullRestDay.state).assertEqual(AnswerState.UNAVAILABLE);
      expect(h.trip.state).assertEqual(AnswerState.UNAVAILABLE);

      expect(h.today.partnerText).assertEqual('今天 TA 的忙碌未知');
      // 睡眠段不计入忙碌，否则"全天空闲"永不成立
      expect(h.today.myText).assertEqual('今天 全天空闲');
      expect(h.today.commonText).assertEqual('今天 共同空闲 3小时');
    });

    it('local_partner_reads_local_busy_without_sleep', 0, () => {
      const d = day('LOCAL', 3,
        [iv(DAY, 540, 1020, 'WORK'), iv(DAY, 1350, 1860, 'SLEEP')],
        [iv(DAY, 480, 1020, 'COURSE'), iv(DAY, 1350, 1860, 'SLEEP')]);
      const h = home(ExperienceMode.LOCAL_PARTNER, [TONIGHT_W], [], d, FRESH, '小陈');

      expect(h.mode).assertEqual(ExperienceMode.LOCAL_PARTNER);
      expect(h.today.myText).assertEqual('今天 09:00–17:00 忙碌');
      expect(h.today.partnerText).assertEqual('今天 TA 08:00–17:00 忙碌');
      // 本机代录是全量细节（L3），可以给出确切时刻
      expect(h.today.partnerText.indexOf('22:30') >= 0).assertFalse();
      expect(h.tonight.state).assertEqual(AnswerState.AVAILABLE);
    });

    it('paired_old_snapshot_stays_paired_and_coarse', 0, () => {
      // 已配对 + 旧快照（L1 只有 30 分钟位图）：形态仍是 PAIRED，但文案不假装精确
      const d = day('SNAPSHOT', 1, [], [iv(DAY, 480, 780, 'BUSY'), iv(DAY, 900, 1020, 'BUSY')]);
      const h = home(ExperienceMode.PAIRED, [TONIGHT_W], [], d, FRESH, '小陈');

      expect(h.mode).assertEqual(ExperienceMode.PAIRED);
      expect(h.today.partnerText).assertEqual('今天 TA 约 2 段忙碌');
      expect(h.today.partnerText.indexOf(':') >= 0).assertFalse();
      expect(h.tonight.state).assertEqual(AnswerState.AVAILABLE);

      // 已配对但此刻完全拿不到对方数据：缓存里的窗口只是"我的空闲"，不能当共同空闲作答
      const blind = home(ExperienceMode.PAIRED, [TONIGHT_W], [], day('NONE', 0, [], null), FRESH, '小陈');
      expect(blind.mode).assertEqual(ExperienceMode.PAIRED);
      expect(blind.tonight.state).assertEqual(AnswerState.UNKNOWN);
      expect(blind.fullRestDay.state).assertEqual(AnswerState.UNKNOWN);
      expect(blind.trip.state).assertEqual(AnswerState.UNKNOWN);
      expect(blind.tonight.action).assertEqual(AnswerAction.OPEN_PARTNER);
      expect(blind.today.partnerText).assertEqual('今天 TA 的忙碌未知');
    });

    it('stale_cache_keeps_results_and_never_claims_absent', 0, () => {
      const d = day('SNAPSHOT', 3, [], []);
      const stale = home(ExperienceMode.PAIRED, [TONIGHT_W], [], d, YESTERDAY, '小陈');
      // 已有结果照常保留，只打过期标记
      expect(stale.stale).assertTrue();
      expect(stale.tonight.state).assertEqual(AnswerState.AVAILABLE);
      expect(stale.tonight.windowStart).assertEqual(TONIGHT_W.start);
      // 无候选时不能断言"没有"：过期缓存证明不了不存在
      expect(stale.fullRestDay.state).assertEqual(AnswerState.STALE);
      expect(stale.trip.state).assertEqual(AnswerState.STALE);

      const never = home(ExperienceMode.PAIRED, [], [], d, 0, '小陈');
      expect(never.stale).assertTrue();
      expect(never.tonight.state).assertEqual(AnswerState.STALE);

      const fresh = home(ExperienceMode.PAIRED, [TONIGHT_W], [], d, FRESH, '小陈');
      expect(fresh.stale).assertFalse();
      expect(fresh.fullRestDay.state).assertEqual(AnswerState.UNAVAILABLE);
    });

    it('empty_cache_answers_without_crash', 0, () => {
      const h = home(ExperienceMode.SOLO, [], [], soloDay(), FRESH, '');
      expect(h.tonight.state).assertEqual(AnswerState.UNAVAILABLE);
      expect(h.fullRestDay.state).assertEqual(AnswerState.UNAVAILABLE);
      expect(h.trip.state).assertEqual(AnswerState.UNAVAILABLE);
      expect(h.nextWindow == null).assertTrue();
      expect(h.conflictCount).assertEqual(0);
      expect(h.today.commonText).assertEqual('今天 暂无共同空闲');
    });

    it('page_filter_matches_classification_tags', 0, () => {
      const short = win(DAY + 1, 600, DAY + 1, 690, WindowChannel.REGULAR, []);
      const long = win(DAY + 1, 600, DAY + 1, 780, WindowChannel.REGULAR, [WindowTag.HALF_DAY]);
      const weekend = win(DAY + 4, 420, DAY + 4, 1350, WindowChannel.REGULAR,
        [WindowTag.WEEKEND, WindowTag.FULL_DAY]);
      const finished = win(DAY, 480, DAY, 600, WindowChannel.REGULAR, []);
      const all = [TONIGHT_W, short, long, weekend, OVERNIGHT_W, TRIP_W, finished];

      // 已结束的窗口不进任何档
      expect(pageOf(all, WindowFilterKey.ALL).windows.length).assertEqual(6);
      expect(pageOf(all, WindowFilterKey.GTE_2H).windows.length).assertEqual(5);
      expect(pageOf(all, WindowFilterKey.FULL_DAY).windows.length).assertEqual(1);
      expect(pageOf(all, WindowFilterKey.FULL_DAY).windows[0].start).assertEqual(weekend.start);
      expect(pageOf(all, WindowFilterKey.WEEKEND).windows.length).assertEqual(1);
      // 出行档读分类标签：TRIP 与 OVERNIGHT_TRIP 都算
      expect(pageOf(all, WindowFilterKey.TRIP).windows.length).assertEqual(2);
      expect(pageOf(all, WindowFilterKey.TRIP).windows[0].start).assertEqual(OVERNIGHT_W.start);
      // 升序，UI 可直接用 start+end+channel 作为稳定 key
      const tripPage = pageOf(all, WindowFilterKey.TRIP);
      expect(tripPage.windows[0].start < tripPage.windows[1].start).assertTrue();
      expect(tripPage.windows[1].channel).assertEqual(WindowChannel.REGULAR);
      expect(tripPage.stale).assertFalse();
      expect(tripPage.computedAt).assertEqual(FRESH);
    });

    it('plan_conflict_text_is_generated_not_stored', 0, () => {
      const altStart = (DAY + 1) * MIN_PER_DAY + 1080;
      const altEnd = (DAY + 1) * MIN_PER_DAY + 1260;
      const hint = '{"altStart":' + altStart + ',"altEnd":' + altEnd + '}';
      const ok = plan('p1', 'OK', '', 1200, 1290);
      const conflictAlt = plan('p2', 'CONFLICT', hint, 1200, 1290);
      const conflictNoAlt = plan('p3', 'CONFLICT', '', 1200, 1290);
      const finished = plan('p4', 'CONFLICT', hint, 60, 120);

      expect(CommonTimeQueryService.countConflicts([ok, conflictAlt, conflictNoAlt, finished]))
        .assertEqual(3);

      const sums = CommonTimeQueryService.planSummaries([ok, conflictAlt, conflictNoAlt, finished], NOW);
      // 已结束的计划不进列表
      expect(sums.length).assertEqual(3);
      expect(sums[0].id).assertEqual('p1');
      expect(sums[0].conflictText).assertEqual('');
      expect(sums[1].conflictText.indexOf('可改到') >= 0).assertTrue();
      expect(sums[1].conflictText.indexOf('18:00') >= 0).assertTrue();
      expect(sums[2].conflictText).assertEqual('与日程冲突 · 暂无替代时段');
    });

    it('detail_clamps_busy_to_the_window_start_day', 0, () => {
      // 跨零点窗口 + 起始日之前/之后的忙碌：只说明起始日，且排除睡眠
      const w = win(DAY, 1080, DAY + 1, 600, WindowChannel.REGULAR, [WindowTag.OVERNIGHT_TRIP]);
      const d = day('LOCAL', 3,
        [iv(DAY, 480, 600, 'WORK'), iv(DAY, 1350, 1860, 'SLEEP')],
        [iv(DAY, 1140, 1260, 'COURSE')]);
      const input: DetailInput = { window: w, day: d };
      const detail: WindowDetailData = CommonTimeQueryService.assembleDetail(input);

      expect(detail.window.start).assertEqual(w.start);
      expect(detail.window.subtitle.indexOf('旅行窗口') >= 0).assertFalse();
      expect(detail.window.subtitle.indexOf('可跨夜') >= 0).assertTrue();
      // 09:00 之前的班不在窗口内，睡眠不算忙碌 → 窗口这段我是空的
      expect(detail.myBusyText).assertEqual('今天 这段时间空闲');
      expect(detail.partnerBusyText).assertEqual('TA 19:00–21:00 忙碌');
      expect(detail.partnerShareLevel).assertEqual(3);
    });

    it('channel_is_reported_from_the_engine_not_from_tags', 0, () => {
      const tripChannel = win(DAY + 2, 480, DAY + 4, 1080, WindowChannel.TRIP, []);
      const s = CommonTimeQueryService.summaryOf(tripChannel);
      expect(s.channel).assertEqual(WindowChannel.TRIP);
      expect(s.subtitle).assertEqual('旅行窗口');

      const regularWithTripTag = win(DAY + 2, 480, DAY + 4, 1080, WindowChannel.REGULAR,
        [WindowTag.TRIP, WindowTag.WEEKEND]);
      const r = CommonTimeQueryService.summaryOf(regularWithTripTag);
      expect(r.channel).assertEqual(WindowChannel.REGULAR);
      // 常规通道即使带 TRIP 标签也不自称旅行窗口，副标题最多三条
      expect(r.subtitle.indexOf('旅行窗口') >= 0).assertFalse();
      expect(r.subtitle.indexOf('可出行') >= 0).assertTrue();
      expect(r.title.indexOf('起') >= 0).assertTrue();
    });

    it('freshness_is_judged_by_local_calendar_day', 0, () => {
      expect(CommonTimeQueryService.isStale(FRESH, NOW)).assertFalse();
      expect(CommonTimeQueryService.isStale(YESTERDAY, NOW)).assertTrue();
      expect(CommonTimeQueryService.isStale(0, NOW)).assertTrue();
      // 跨日即过期：引擎视界从重算当天起算，隔天缓存里的"今天"已不是今天
      expect(CommonTimeQueryService.isStale(FRESH, NOW + MIN_PER_DAY)).assertTrue();
      expect(CommonTimeQueryService.daysSpan(DAY_START + 1080, DAY_END + 600)).assertEqual(2);
      expect(CommonTimeQueryService.daysSpan(DAY_START + 420, DAY_START + 1350)).assertEqual(1);
      expect(CommonTimeQueryService.daysSpan(DAY_START, DAY_END)).assertEqual(1);
    });
  });
}
