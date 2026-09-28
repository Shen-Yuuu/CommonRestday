import { DateLabel } from 'commons';
import { AnswerState, ExperienceMode, HomeSummary, QuickAnswer } from '../model/PresentationModels';

/**
 * 桌面 2×2 卡片的读模型（阶段 4 Task 4.2）。
 *
 * 卡片不是第二套算法：结论一律取自首页读模型 `HomeSummary`，这里只做**投影**——
 * 把三答案压成"一大一次"两行，并把卡片必须自己说的两个缺口（没录日程、配对待同步）
 * 补成独立状态。六态必须互相区分得开，因为卡片没有下拉刷新与提示条可以兜。
 *
 * 纯函数、不碰 RDB/Preferences/云：卡片进程与 EntryAbility 进程各自初始化，
 * 谁调谁负责取数（见 entry/.../FormAbility.ets），所以这一层可以离线跑单测。
 */

/** 卡面六态：两态给答案，四态是"要用户先处理什么"。 */
export enum CardState {
  /** 今晚可见：今天剩下的时间里还有共同时段。 */
  TONIGHT = 'TONIGHT',
  /** 下个完整同休日：今晚没了，给最近的一段完整同休。 */
  NEXT_FULL_REST = 'NEXT_FULL_REST',
  /** 暂无结果：有日程也算完了，视界内确实没有共同空闲。 */
  NO_RESULT = 'NO_RESULT',
  /** 未录日程：本机一条班次/课程都没有，"没有空闲"会被误读成"你们没时间"。 */
  NO_SCHEDULE = 'NO_SCHEDULE',
  /** 数据过期：重算没跟上，卡上是上一轮的结果。 */
  STALE = 'STALE',
  /** 配对待同步：标了已配对，但对方的日程还没同步到本机。 */
  PAIR_PENDING = 'PAIR_PENDING'
}

/** 卡面模型：只放扁平字符串/数字，卡片侧用 @LocalStorageProp 逐键读。 */
export interface CardModel {
  /** CardState 的值，卡片按它分支渲染。 */
  state: string;
  /** 顶部问句。 */
  question: string;
  /** 大字结论。 */
  hero: string;
  /** 结论下的依据行。 */
  heroNote: string;
  /** 次答案行（今晚 ↔ 下个完整同休日互次）。 */
  second: string;
  /** 底部说明：结果时间或缺口提示。 */
  footer: string;
  /** 点击落地的路由名。 */
  route: string;
}

/** 卡片输入：首页读模型 + 首页给不出的那个缺口信号。 */
export interface CardInput {
  home: HomeSummary;
  /**
   * 本机是否真的录过日程（有循环模板/课程/临时调整任一）。
   * 不能拿"窗口缓存为空"代替：录了班表但视界内凑不出共同空闲时缓存同样是空的，
   * 把它说成"还没录入日程"是假话，用户会以为白录了。
   */
  hasSchedule: boolean;
}

/**
 * 点击落地路由名。取值必须落在 entry/navigation/NavRoutes 的白名单里：
 * 名单外的名字会被壳层丢弃并停在首页，所以这里写错不会跳转、也不会崩。
 */
export class CardRoutes {
  static readonly HOME: string = 'home';
  static readonly COMMON_TIME: string = 'common-time';
  static readonly ME: string = 'me';
  static readonly SCHEDULE_HUB: string = 'schedule-hub';
}

/** 卡片只有约 150×150vp，问句要一行读得完；答案文字仍原样取自首页读模型。 */
const QUESTION_TONIGHT = '今晚能一起吗';
const QUESTION_FULL_REST = '下个完整同休';
/** 单人形态只退主语：没有"一起"可言。但"整天不用上班"这件事全产品只有一个名字。 */
const QUESTION_TONIGHT_SOLO = '今晚有空吗';

export class CardSummaryService {
  /** 投影：状态优先级 缺口(未录日程) → 缺口(待同步) → 过期 → 今晚 → 下个完整同休 → 暂无结果。 */
  static of(input: CardInput): CardModel {
    const home = input.home;
    const tonight: QuickAnswer = home.tonight;
    const full: QuickAnswer = home.fullRestDay;
    // 单人形态没有"共同"可言：卡面说"我的空闲"，别拿二人措辞骗一个人用的人
    const solo = home.mode === ExperienceMode.SOLO;
    const question = solo ? '我的时间' : '共同时间';
    if (!input.hasSchedule) {
      return prompt(CardState.NO_SCHEDULE, '我的日程', '还没录入日程',
        '记上班次或课程就会开始算', '去记一笔', CardRoutes.SCHEDULE_HUB, home.computedAt);
    }
    // UNKNOWN 只在"已标配对却拿不到对方任何数据"时出现（单人形态本来就算得出自己的空闲），
    // 卡面必须和"暂无空闲"分开：前者是等同步，后者是真没有。
    if (tonight.state === AnswerState.UNKNOWN) {
      return prompt(CardState.PAIR_PENDING, question, '还没收到 TA 的日程',
        '两台手机的数据还没同步过来', '去「我的」检查同步', CardRoutes.ME, home.computedAt);
    }
    // 过期优先于答案：卡上写着具体日期却属于昨天，比没有答案更容易误导
    if (home.stale) {
      return prompt(CardState.STALE, question, '结果是上一轮的',
        '班表可能已经变了，重新算过再确认', '点开重新计算', CardRoutes.HOME, home.computedAt);
    }
    if (tonight.state === AnswerState.AVAILABLE) {
      return answers(CardState.TONIGHT, tonight, full, home.computedAt, solo);
    }
    if (full.state === AnswerState.AVAILABLE) {
      return answers(CardState.NEXT_FULL_REST, full, tonight, home.computedAt, solo);
    }
    // 有数据也算完了，但两个答案都给不出：说"暂无"而不是猜一个时间
    return prompt(CardState.NO_RESULT, question, '暂无' + (solo ? '空闲' : '共同空闲'),
      '放宽作息，或往后多看几天', '点开挑日子', CardRoutes.COMMON_TIME, home.computedAt);
  }
}

/**
 * 有答案的两态：主答案原样搬首页结论，次答案只留一行结论文字。
 *
 * 今晚态的依据行不用首页那句'还剩 X'：卡片每 6 小时才刷新一次，倒计时会在当天下午
 * 就变成假话。窗口起止是绝对时刻（结论行里已经写了），依据行只补一个不随时间失效的总时长。
 */
function answers(state: CardState, main: QuickAnswer, other: QuickAnswer, computedAt: number,
  solo: boolean): CardModel {
  const tonight = state === CardState.TONIGHT;
  let question = tonight ? QUESTION_TONIGHT : QUESTION_FULL_REST;
  if (solo && tonight) {
    question = QUESTION_TONIGHT_SOLO;
  }
  const note = tonight
    ? '共 ' + DateLabel.duration(main.windowEnd - main.windowStart) + ' 可安排'
    : main.supportingText;
  const m = model(state, question, main.headline, note, secondaryOf(other), CardRoutes.COMMON_TIME, computedAt);
  return m;
}

function secondaryOf(a: QuickAnswer): string {
  if (a.state !== AnswerState.AVAILABLE) {
    return '';
  }
  return a.headline;
}

function prompt(state: CardState, question: string, hero: string, heroNote: string,
  second: string, route: string, computedAt: number): CardModel {
  return model(state, question, hero, heroNote, second, route, computedAt);
}

function model(state: CardState, question: string, hero: string, heroNote: string,
  second: string, route: string, computedAt: number): CardModel {
  const m: CardModel = {
    state: state, question: question, hero: hero, heroNote: heroNote,
    second: second, footer: footerOf(computedAt), route: route
  };
  return m;
}

/**
 * 与首页同一句口径：卡片要说清结果是什么时候算的，过期才有据可循。
 * computedAt 是 Date.now()，按本地时钟取时分（不能对 UTC 毫秒取模，那会差一个时区）。
 */
function footerOf(computedAt: number): string {
  if (computedAt <= 0) {
    return '结果尚未计算';
  }
  const d = new Date(computedAt);
  return '结果基于 ' + DateLabel.hm(d.getHours() * 60 + d.getMinutes()) + ' 的计算';
}
