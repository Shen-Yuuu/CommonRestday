import { describe, it, expect } from '@ohos/hypium';
import { Interval, MIN_PER_DAY, Window, WindowChannel, WindowTag } from 'domain';
import {
  CardInput, CardModel, CardState, CardSummaryService, CommonTimeQueryService, DayBusy,
  ExperienceMode, HomeInput, HomeSummary
} from 'feature';

/**
 * 卡片投影契约测试（阶段 4 Task 4.2）。
 *
 * 断言刻意写成"卡面文字 == 首页读模型文字"，不在测试里复述首页文案：
 * 卡片不许有第二套算法，手抄句子会在改文案时假报错，也会遮住"卡片自己另写一句"这个
 * 真正要防的漂移。只有六态自己的措辞（缺口/过期/暂无）直接断言，那些句子只在卡面出现。
 */

/** 2026-09-22（周二）为"今天"；19:00 提问，正好落在"今晚"口径里。 */
const DAY = 20718;
const NOW = DAY * MIN_PER_DAY + 1140;

/** 本地日历日构造时间戳：避免断言随运行机器时区漂移。 */
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

/** 今天 19:30–22:30 的一段共同空闲（3 小时）。 */
const TONIGHT_W = win(DAY, 1170, DAY, 1350, WindowChannel.REGULAR, [WindowTag.MEAL]);
/** 下个周六的完整同休日。 */
const FULL_W = win(DAY + 4, 420, DAY + 4, 1350, WindowChannel.REGULAR,
  [WindowTag.FULL_DAY, WindowTag.HALF_DAY]);

/** source='NONE' 即拿不到对方数据：已配对这个形态下就是"待同步"。 */
function dayOf(source: string, level: number): DayBusy {
  const sleep: Interval = {
    start: DAY * MIN_PER_DAY + 1380, end: (DAY + 1) * MIN_PER_DAY + 420, tag: 'SLEEP'
  };
  const d: DayBusy = {
    epochDay: DAY, myBusy: [sleep], partnerBusy: source === 'NONE' ? null : [sleep],
    partnerSource: source, partnerShareLevel: level
  };
  return d;
}

/** 走真实装配函数拿首页读模型：投影测试不吃手搓的 HomeSummary。 */
function homeOf(mode: ExperienceMode, windows: Window[], d: DayBusy, computedAt: number,
  partnerName: string): HomeSummary {
  const input: HomeInput = {
    mode: mode, partnerName: partnerName, windows: windows, plans: [],
    day: d, computedAt: computedAt, nowEpochMin: NOW
  };
  return CommonTimeQueryService.assembleHome(input);
}

function cardOf(h: HomeSummary, hasSchedule: boolean): CardModel {
  const input: CardInput = { home: h, hasSchedule: hasSchedule };
  return CardSummaryService.of(input);
}

const COUPLE = ExperienceMode.LOCAL_PARTNER;
const PARTNER_DAY = dayOf('LOCAL', 3);

export default function cardSummaryServiceTest() {
  describe('cardSummaryService', () => {

    it('tonight_answer_is_carried_verbatim_without_a_countdown', 0, () => {
      const h = homeOf(COUPLE, [TONIGHT_W, FULL_W], PARTNER_DAY, FRESH, '小陈');
      const m = cardOf(h, true);
      expect(m.state).assertEqual(CardState.TONIGHT);
      expect(m.hero).assertEqual(h.tonight.headline);
      // 卡片 6 小时才刷一次，"还剩 X"会在当天下午变成假话：只留不随时间失效的总时长
      expect(m.heroNote.indexOf('还剩') < 0).assertTrue();
      expect(m.heroNote).assertEqual('共 3小时 可安排');
      // 今晚之外的下个完整同休日降为次行，仍然原样取自读模型
      expect(m.second).assertEqual(h.fullRestDay.headline);
      expect(m.route).assertEqual('common-time');
    });

    it('next_full_rest_day_steps_in_when_tonight_is_empty', 0, () => {
      const h = homeOf(COUPLE, [FULL_W], PARTNER_DAY, FRESH, '小陈');
      const m = cardOf(h, true);
      expect(m.state).assertEqual(CardState.NEXT_FULL_REST);
      expect(m.hero).assertEqual(h.fullRestDay.headline);
      // 今晚给不出答案时不硬凑次行：次行只能是另一个真答案
      expect(m.second).assertEqual('');
      expect(m.question).assertEqual('下个完整同休');
    });

    it('paired_without_partner_data_reads_as_a_sync_gap', 0, () => {
      const h = homeOf(ExperienceMode.PAIRED, [TONIGHT_W], dayOf('NONE', 0), FRESH, '小陈');
      const m = cardOf(h, true);
      // 缓存里那段时间只是"我的空闲"，说成共同空闲是假话；也不同于"暂无"
      expect(m.state).assertEqual(CardState.PAIR_PENDING);
      expect(m.hero).assertEqual('还没收到 TA 的日程');
      expect(m.route).assertEqual('me');
    });

    it('no_common_time_says_so_instead_of_picking_a_window', 0, () => {
      const h = homeOf(COUPLE, [], PARTNER_DAY, FRESH, '小陈');
      const m = cardOf(h, true);
      expect(m.state).assertEqual(CardState.NO_RESULT);
      expect(m.hero).assertEqual('暂无共同空闲');
      expect(m.route).assertEqual('common-time');
    });

    it('solo_mode_never_claims_togetherness', 0, () => {
      const h = homeOf(ExperienceMode.SOLO, [TONIGHT_W], dayOf('NONE', 0), FRESH, '');
      const m = cardOf(h, true);
      expect(m.state).assertEqual(CardState.TONIGHT);
      expect(m.question).assertEqual('今晚有空吗');
      const empty = cardOf(homeOf(ExperienceMode.SOLO, [], dayOf('NONE', 0), FRESH, ''), true);
      expect(empty.question).assertEqual('我的时间');
      expect(empty.hero).assertEqual('暂无空闲');
      // 主语可以退，名词不能另起一个：单人态的完整休息日与已配对念同一个词
      const soloFull = cardOf(homeOf(ExperienceMode.SOLO, [FULL_W], dayOf('NONE', 0), FRESH, ''), true);
      expect(soloFull.state).assertEqual(CardState.NEXT_FULL_REST);
      expect(soloFull.question).assertEqual('下个完整同休');
      expect(soloFull.hero.indexOf('完整同休日') >= 0).assertTrue();
    });

    it('unrecorded_schedule_precedes_every_answer', 0, () => {
      // 缓存里留着上次代录时的窗口：日程删干净后卡片不能说"你们今晚有空"
      const h = homeOf(COUPLE, [TONIGHT_W, FULL_W], PARTNER_DAY, FRESH, '小陈');
      const m = cardOf(h, false);
      expect(m.state).assertEqual(CardState.NO_SCHEDULE);
      expect(m.hero).assertEqual('还没录入日程');
      expect(m.route).assertEqual('schedule-hub');
    });

    it('stale_cache_precedes_the_answer', 0, () => {
      const h = homeOf(COUPLE, [TONIGHT_W], PARTNER_DAY, YESTERDAY, '小陈');
      const m = cardOf(h, true);
      // 昨天的"今晚 19:30"挂在今天是最容易误导人的一种卡面
      expect(m.state).assertEqual(CardState.STALE);
      expect(m.hero).assertEqual('结果是上一轮的');
      expect(m.route).assertEqual('home');
    });

    it('footer_tells_when_the_result_was_computed', 0, () => {
      const h = homeOf(COUPLE, [TONIGHT_W], PARTNER_DAY, FRESH, '小陈');
      // FRESH 是本地 10:00 的时间戳，卡片要说的就是"这一版几点算的"
      expect(cardOf(h, true).footer).assertEqual('结果基于 10:00 的计算');
      const never = homeOf(COUPLE, [TONIGHT_W], PARTNER_DAY, 0, '小陈');
      expect(cardOf(never, true).footer).assertEqual('结果尚未计算');
    });
  });
}
