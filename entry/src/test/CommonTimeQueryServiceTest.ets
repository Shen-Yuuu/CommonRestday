import { describe, it, expect } from '@ohos/hypium';
import {
  CONFLICT_REASON_MIXED, CONFLICT_REASON_MY_COURSE, CONFLICT_REASON_PARTNER_CHANGED,
  CONFLICT_SOURCE_BOTH, CONFLICT_SOURCE_MINE, CONFLICT_SOURCE_PARTNER, ConflictHint, Interval,
  encodeConflictHint, MIN_PER_DAY, Window, WindowChannel, WindowTag
} from 'domain';
import { PlanRow } from 'data';
import {
  AnswerAction, AnswerKind, AnswerState, CommonTimePageData, DayBusy, DetailInput, ExperienceMode,
  HomeInput, HomeSummary, PageInput, PlanConflictView, WindowDetailData, WindowFilter,
  WindowFilterKey, WindowSummary, CommonTimeQueryService
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

/** 重算写进 plan.conflict_hint 的持久结构（分钟都是当天时刻）。 */
function hintOf(reasonCode: string, sourceLevel: string, overlapStart: number, overlapEnd: number,
  altStart: number, altEnd: number, kept: boolean): string {
  const h: ConflictHint = {
    reasonCode: reasonCode, sourceLevel: sourceLevel,
    overlapStartMin: DAY_START + overlapStart, overlapEndMin: DAY_START + overlapEnd,
    altStartMin: DAY_START + altStart, altEndMin: DAY_START + altEnd, kept: kept
  };
  return encodeConflictHint(h);
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
    windows: all, plans: [], filter: f,
    mode: ExperienceMode.LOCAL_PARTNER, partnerName: '小陈', partnerSource: 'LOCAL',
    horizonDays: 120, computedAt: FRESH, nowEpochMin: NOW
  };
  return CommonTimeQueryService.assemblePage(input);
}

/** 列表/周历共用的稳定 key：起点+终点+通道（与 UI 的 ForEach key 一致）；归并断言要同时读原始窗口与摘要行。 */
function keyOf(w: WindowSummary | Window): string {
  return w.start + '-' + w.end + '-' + w.channel;
}

function sortedKeys(list: WindowSummary[]): string {
  const out: string[] = [];
  for (let i = 0; i < list.length; i++) {
    out.push(keyOf(list[i]));
  }
  out.sort();
  return out.join('|');
}

/** 一组窗口触及的自然日集合（升序逗号串）：归并前后必须相等，否则列表丢了天。 */
function daysKey(list: WindowSummary[]): string {
  const days: number[] = [];
  for (let i = 0; i < list.length; i++) {
    const firstDay = Math.floor(list[i].start / MIN_PER_DAY);
    const lastDay = Math.floor((list[i].end - 1) / MIN_PER_DAY);
    for (let d = firstDay; d <= lastDay; d++) {
      if (days.indexOf(d) < 0) {
        days.push(d);
      }
    }
  }
  days.sort((a: number, b: number): number => a - b);
  return days.join(',');
}

/** 带某个展示标签的窗口 key 集合。 */
function keysWithDisplayTag(page: CommonTimePageData, tag: string): string {
  const out: WindowSummary[] = [];
  for (let i = 0; i < page.windows.length; i++) {
    if (page.windows[i].displayTags.indexOf(tag) >= 0) {
      out.push(page.windows[i]);
    }
  }
  return sortedKeys(out);
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

    it('tonight_support_counts_window_not_waiting', 0, () => {
      // 尚未开始：19:00 看 19:30–22:30，空闲只有 3 小时，等待的 30 分钟不能混进去
      const before = CommonTimeQueryService.tonightAnswer(TONIGHT_W, NOW, ExperienceMode.PAIRED, false);
      expect(before.state).assertEqual(AnswerState.AVAILABLE);
      expect(before.headline.indexOf('19:30–22:30') >= 0).assertTrue();
      expect(before.supportingText.indexOf('30分钟后开始') >= 0).assertTrue();
      expect(before.supportingText.indexOf('共 3小时') >= 0).assertTrue();
      expect(before.supportingText.indexOf('4小时30') >= 0).assertFalse();

      // 进行中：20:00 看同一窗口，剩 2 小时 30 分，全程仍是 3 小时
      const during = CommonTimeQueryService.tonightAnswer(TONIGHT_W, DAY_START + 1200,
        ExperienceMode.PAIRED, false);
      expect(during.supportingText.indexOf('还剩 2小时30分') >= 0).assertTrue();
      expect(during.supportingText.indexOf('共 3小时') >= 0).assertTrue();
      expect(during.supportingText.indexOf('后开始') >= 0).assertFalse();

      // 恰好结束：不再宣称有空，答案转成"看看明天"
      const ended = CommonTimeQueryService.tonightAnswer(TONIGHT_W, TONIGHT_W.end,
        ExperienceMode.PAIRED, false);
      expect(ended.state).assertEqual(AnswerState.UNAVAILABLE);
      expect(ended.windowStart).assertEqual(0);
      expect(ended.headline.indexOf('已结束') >= 0).assertTrue();

      // 边界只影响文案，选取环节本来就不会交出已结束的窗口
      expect(CommonTimeQueryService.pickTonight([TONIGHT_W], TONIGHT_W.end) == null).assertTrue();
    });

    it('tonight_absent_headline_reads_right_in_each_mode', 0, () => {
      // D-36：单人态把「我们」换成「我」之后，「今晚没有我共同的空档」里"共同"是悬空的
      expect(CommonTimeQueryService.tonightAnswer(null, NOW, ExperienceMode.SOLO, false).headline)
        .assertEqual('今晚我没有空档');
      expect(CommonTimeQueryService.tonightAnswer(TONIGHT_W, TONIGHT_W.end, ExperienceMode.SOLO, false).headline)
        .assertEqual('今晚的空档已结束');
      // 代录态那两支逐字不动：它们是 D-14 定下来的口径，留在这里当回归保护
      expect(CommonTimeQueryService.tonightAnswer(null, NOW, ExperienceMode.PAIRED, false).headline)
        .assertEqual('今晚没有我们共同的空档');
      expect(CommonTimeQueryService.tonightAnswer(TONIGHT_W, TONIGHT_W.end, ExperienceMode.PAIRED, false).headline)
        .assertEqual('今晚的共同空档已结束');
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

    it('midnight_endpoint_is_read_as_24_00_not_00_00', 0, () => {
      // D-58：区间终点落在整零点时念 24:00（记前一天），是 D-13／D-44 已经裁过的口径，
      // 窗口卡与窗口详情都照它；忙碌文案当时走的是裸时刻格式化，同一段夜班念成 20:00–00:00，
      // 两张纸说的不是同一件事，而 00:00 在"今天"后面根本读不出是头还是尾。
      const d = day('LOCAL', 3, [iv(DAY, 1200, 1440, 'WORK')], [iv(DAY, 1200, 1440, 'BUSY')]);
      expect(CommonTimeQueryService.myLabel(d, DAY_START, DAY_END)).assertEqual('今天 20:00–24:00 忙碌');
      expect(CommonTimeQueryService.partnerLabel(d, DAY_START, DAY_END, '')).assertEqual('TA 20:00–24:00 忙碌');
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

    it('list_rows_merge_by_day_without_losing_days', 0, () => {
      // 跨三天的旅行窗口与当天的一段常规窗口时间重叠：列表只留最长的一段
      const trip = win(DAY + 1, 360, DAY + 3, 720, WindowChannel.TRIP,
        [WindowTag.TRIP, WindowTag.OVERNIGHT_TRIP]);
      const sameDayRegular = win(DAY + 1, 360, DAY + 1, 720, WindowChannel.REGULAR, []);
      const later = win(DAY + 5, 480, DAY + 5, 900, WindowChannel.REGULAR, [WindowTag.HALF_DAY]);
      const page = pageOf([trip, sameDayRegular, later], WindowFilterKey.ALL);

      expect(page.windows.length).assertEqual(3);
      expect(page.rows.length).assertEqual(2);
      expect(page.rows[0].start).assertEqual(trip.start);
      expect(page.rows[0].channel).assertEqual(WindowChannel.TRIP);
      expect(page.rows[1].start).assertEqual(later.start);
      // 归并只挑不造：每一行都来自筛选结果
      expect(sortedKeys(page.windows).indexOf(keyOf(page.rows[0])) >= 0).assertTrue();
      expect(sortedKeys(page.windows).indexOf(keyOf(page.rows[1])) >= 0).assertTrue();
      expect(sortedKeys(page.rows).indexOf(keyOf(sameDayRegular)) >= 0).assertFalse();
      // 归并不丢天：窗口触及的自然日一个不少（列表与周历同一批窗口）
      expect(daysKey(page.rows)).assertEqual(daysKey(page.windows));
      // 同一天出现两段常规窗口时，也只留最长的一段
      const morning = win(DAY + 2, 480, DAY + 2, 720, WindowChannel.REGULAR, []);
      const afternoon = win(DAY + 2, 780, DAY + 2, 1200, WindowChannel.REGULAR, []);
      const split = pageOf([morning, afternoon], WindowFilterKey.ALL);
      expect(split.windows.length).assertEqual(2);
      expect(split.rows.length).assertEqual(1);
      expect(split.rows[0].start).assertEqual(afternoon.start);
    });

    it('display_tags_and_filter_keys_follow_one_rule', 0, () => {
      const all = [TONIGHT_W, FULL_W, OVERNIGHT_W, TRIP_W,
        win(DAY + 4, 480, DAY + 4, 900, WindowChannel.REGULAR, [WindowTag.WEEKEND, WindowTag.FULL_DAY])];
      const page = pageOf(all, WindowFilterKey.ALL);

      // 卡片标签最多三档，且只取这三个 key
      const cardTagKeys: string[] = [WindowTag.FULL_DAY, WindowTag.WEEKEND, WindowTag.TRIP];
      for (let i = 0; i < page.windows.length; i++) {
        const tags: string[] = page.windows[i].displayTags;
        expect(tags.length <= 3).assertTrue();
        for (let j = 0; j < tags.length; j++) {
          expect(cardTagKeys.indexOf(tags[j]) >= 0).assertTrue();
        }
      }
      // 餐叙/自习/半天不进卡片：带 MEAL 的今晚窗口没有展示标签
      expect(page.windows[0].start).assertEqual(TONIGHT_W.start);
      expect(page.windows[0].displayTags.length).assertEqual(0);
      // 每档筛选的结果，恰好是卡片上带对应标签的那些窗口
      expect(sortedKeys(pageOf(all, WindowFilterKey.FULL_DAY).windows))
        .assertEqual(keysWithDisplayTag(page, WindowTag.FULL_DAY));
      expect(sortedKeys(pageOf(all, WindowFilterKey.WEEKEND).windows))
        .assertEqual(keysWithDisplayTag(page, WindowTag.WEEKEND));
      expect(sortedKeys(pageOf(all, WindowFilterKey.TRIP).windows))
        .assertEqual(keysWithDisplayTag(page, WindowTag.TRIP));
      expect(keysWithDisplayTag(page, WindowTag.TRIP).length > 0).assertTrue();
    });

    it('page_states_whether_windows_are_common', 0, () => {
      const all = [TONIGHT_W];
      // 本机代录且今天有对方数据：可以说是共同时间
      expect(pageOf(all, WindowFilterKey.ALL).partnerKnown).assertTrue();
      expect(pageOf(all, WindowFilterKey.ALL).mode).assertEqual(ExperienceMode.LOCAL_PARTNER);
      expect(pageOf(all, WindowFilterKey.ALL).partnerName).assertEqual('小陈');

      // 已配对但今天拿不到对方数据：窗口只是"我的空闲"，页面必须降级说明
      const f: WindowFilter = { key: WindowFilterKey.ALL, fromEpochMin: NOW };
      const blind: PageInput = {
        windows: all, plans: [], filter: f,
        mode: ExperienceMode.PAIRED, partnerName: '小陈', partnerSource: 'NONE',
        horizonDays: 120, computedAt: FRESH, nowEpochMin: NOW
      };
      const blindPage = CommonTimeQueryService.assemblePage(blind);
      expect(blindPage.partnerKnown).assertFalse();
      expect(blindPage.mode).assertEqual(ExperienceMode.PAIRED);
      expect(blindPage.windows.length).assertEqual(1);

      // 单人形态不是"缺数据"：只有我，本来就能作答
      const solo: PageInput = {
        windows: all, plans: [], filter: f,
        mode: ExperienceMode.SOLO, partnerName: '', partnerSource: 'NONE',
        horizonDays: 45, computedAt: FRESH, nowEpochMin: NOW
      };
      expect(CommonTimeQueryService.assemblePage(solo).partnerKnown).assertTrue();
      // 视界是读模型字段，不是页面自己去读参数：副标题那句"未来 N 个月"只有这一个来源
      expect(CommonTimeQueryService.assemblePage(solo).horizonDays).assertEqual(45);
      expect(CommonTimeQueryService.assemblePage(blind).horizonDays).assertEqual(120);
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

    it('conflict_copy_explains_reason_without_leaking_partner_plans', 0, () => {
      // 我的课程在本地就写着，可以说"课程"
      const mine = plan('p1', 'CONFLICT',
        hintOf(CONFLICT_REASON_MY_COURSE, CONFLICT_SOURCE_MINE, 1140, 1290, 1380, 1500, false),
        1200, 1290);
      // 对方只给了粗粒度忙闲（位图标签一律是 BUSY）：只能承认"时间变了"，不能替 TA 说出班次
      const coarse = plan('p2', 'CONFLICT',
        hintOf(CONFLICT_REASON_PARTNER_CHANGED, CONFLICT_SOURCE_PARTNER, 1140, 1200, 0, 0, false),
        1200, 1290);
      const sums = CommonTimeQueryService.planSummaries([mine, coarse], NOW);

      const m = sums[0].conflict;
      expect(m != null).assertTrue();
      const mv = m as PlanConflictView;
      expect(mv.reasonCode).assertEqual(CONFLICT_REASON_MY_COURSE);
      expect(mv.reasonText).assertEqual('与你的课程冲突');
      // 受影响区间与替代窗口分开给：区间说"哪一段被占了"，可改到说"下一步做什么"
      expect(mv.affectedText.indexOf('冲突时段') >= 0).assertTrue();
      expect(mv.altText.indexOf('可改到') >= 0).assertTrue();
      expect(mv.altStart).assertEqual(DAY_START + 1380);
      // 「可改到」念的是空档，改期落地只占空档开头那一段（D-32）：两个数必须分开给
      expect(mv.landedStart).assertEqual(mv.altStart);
      expect(mv.landedEnd).assertEqual(DAY_START + 1470);
      expect(mv.landedEnd < mv.altEnd).assertTrue();
      // 空档比计划还短：兜底截到空档末尾，计划被缩短而不是越界占用
      const tightWindow = plan('p1b', 'CONFLICT',
        hintOf(CONFLICT_REASON_MY_COURSE, CONFLICT_SOURCE_MINE, 1140, 1200, 1380, 1440, false),
        1200, 1290);
      const tight = CommonTimeQueryService.planSummaries([tightWindow], NOW)[0].conflict as PlanConflictView;
      expect(tight.landedEnd).assertEqual(tight.altEnd);
      expect(sums[0].conflictText.indexOf(mv.reasonText) >= 0).assertTrue();
      expect(mv.kept).assertFalse();

      expect(sums[1].conflictText.indexOf('班') >= 0).assertFalse();
      expect(sums[1].conflictText.indexOf('课') >= 0).assertFalse();
      expect(sums[1].conflictText.indexOf('TA 的时间有变') >= 0).assertTrue();
      // 没有替代窗口时如实说没有：不能对着一个不存在的时段叫用户"改到"
      expect(sums[1].conflictText.indexOf('暂无替代时段') >= 0).assertTrue();
      expect((sums[1].conflict as PlanConflictView).altStart).assertEqual(0);

      // "保留原计划"的标记要能被列表读到，UI 据此收起催改期
      const kept = plan('p3', 'CONFLICT',
        hintOf(CONFLICT_REASON_MIXED, CONFLICT_SOURCE_BOTH, 1140, 1200, 1380, 1500, true), 1200, 1290);
      const keptSums = CommonTimeQueryService.planSummaries([kept], NOW);
      expect((keptSums[0].conflict as PlanConflictView).kept).assertTrue();
      expect(keptSums[0].conflictText.indexOf('与你的安排冲突，TA 的时间也有变') >= 0).assertTrue();

      // 首页一句话摘要按来源级别合并：涉及 TA 就不细分是谁的哪件事
      expect(home(ExperienceMode.LOCAL_PARTNER, [], [mine, kept], soloDay(), FRESH, '小陈')
        .conflictReason).assertEqual('你们的日程有变');
      expect(home(ExperienceMode.LOCAL_PARTNER, [], [mine], soloDay(), FRESH, '小陈')
        .conflictReason).assertEqual('你的日程有变');
      expect(home(ExperienceMode.LOCAL_PARTNER, [], [coarse], soloDay(), FRESH, '小陈')
        .conflictReason).assertEqual('TA 的时间有变');
      // 旧格式 hint 归不出因：说不清是谁的时间就不下结论
      const legacy = plan('p4', 'CONFLICT', '{"altStart":' + (DAY_START + 1380) + ',"altEnd":'
        + (DAY_START + 1500) + '}', 1200, 1290);
      expect(home(ExperienceMode.LOCAL_PARTNER, [], [legacy], soloDay(), FRESH, '小陈')
        .conflictReason).assertEqual('计划时间需要确认');
      expect(home(ExperienceMode.LOCAL_PARTNER, [], [mine, legacy], soloDay(), FRESH, '小陈')
        .conflictReason).assertEqual('你的日程有变');
      expect(home(ExperienceMode.SOLO, [], [], soloDay(), FRESH, '').conflictReason).assertEqual('');
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
