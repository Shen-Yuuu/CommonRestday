/** 年月日。 */
export interface Ymd {
  y: number;
  m: number;
  d: number;
}

/** UI 层日期/时间格式化（epochDay 基于"本地日历日"语义）。 */
const WD = ['周一', '周二', '周三', '周四', '周五', '周六', '周日'];

/**
 * 一天的分钟数。domain 里那份叫 `MIN_PER_DAY`，这里不能 import 它：
 * commons 是依赖图的底（`commons/oh-package.json5` 的 dependencies 是空的），
 * 给它加一条指向 domain 的边，等于让"日志＋工具"层去依赖业务领域层。
 * 这个 1440 是单位定义不是业务口径，两份都写不出第三个值，所以留着；
 * 由 `entry/src/test/DateLabelTest.ets` 断言它与 domain 那份同值。
 */
const DAY_MIN = 1440;

export class DateLabel {
  /** "9月14日" */
  static md(epochDay: number): string {
    const ymd = DateLabel.ymd(epochDay);
    return ymd.m + '月' + ymd.d + '日';
  }

  /** "周一" */
  static weekday(epochDay: number): string {
    // 1970-01-01 周四
    return WD[((epochDay % 7) + 7 + 3) % 7];
  }

  /** "9月14日 周一" */
  static mdw(epochDay: number): string {
    return DateLabel.md(epochDay) + ' ' + DateLabel.weekday(epochDay);
  }

  /** "15:00"（epochMin 当日分钟） */
  static hm(min: number): string {
    const m = ((min % DAY_MIN) + DAY_MIN) % DAY_MIN;
    const h = Math.floor(m / 60);
    const mm = m % 60;
    const hs = h < 10 ? '0' + h : '' + h;
    const mms = mm < 10 ? '0' + mm : '' + mm;
    return hs + ':' + mms;
  }

  /**
   * 起止时段显示（不含起始日期，起日由调用方上下文给出）：
   * 同日 "15:00–22:30"；跨日 "15:00 – 9月21日 22:30"；结束恰为午夜显示 "24:00"。
   * 跨日窗口（如旅行窗口、跨天计划）由此正确带出结束日期。
   */
  static endLabel(startMin: number, endMin: number): string {
    const sd = DateLabel.edgeDay(startMin, false);
    const ed = DateLabel.edgeDay(endMin, true);
    const et = DateLabel.edgeTime(endMin, true);
    if (ed <= sd) {
      return DateLabel.hm(startMin) + '–' + et;
    }
    return DateLabel.hm(startMin) + ' – ' + DateLabel.md(ed) + ' ' + et;
  }

  /**
   * 单个端点的「日期 + 时间」（D-44）：只印 HH:MM 时，明天 07:00 与今天 07:00 在屏幕上
   * 长得一模一样（起草器踩过两次），所以每个端点都要自证是哪一天。
   * 今天/明天用相对词，更远（含昨天及更早的异常值）一律写死月日——
   * 相对词按调用方给定的"查看时的今天"现算，页面停留跨天后跟着变，不会留一个会漂移的「明天」。
   */
  static stamp(epochMin: number, isEnd: boolean, todayEpoch: number): string {
    const day = DateLabel.edgeDay(epochMin, isEnd);
    const time = DateLabel.edgeTime(epochMin, isEnd);
    const offset = day - todayEpoch;
    if (offset === 0) {
      return '今天 ' + time;
    }
    if (offset === 1) {
      return '明天 ' + time;
    }
    return DateLabel.md(day) + ' ' + time;
  }

  /**
   * 端点落在哪个日历日。
   * 整零点既是"下一天的 00:00"也是"这一天的 24:00"，两个说法指同一个瞬间：
   * 作为**起点**读前者（次日开始），作为**终点**读后者（当天结束）。
   * 判错半边，区间在屏幕上就会短或长一整天，所以起点终点必须显式传 isEnd。
   *
   * 这不是仓内唯一的归日判定：算法侧的同一件事在 `domain` 的 `dayOfStart`／`dayOfEnd`
   * （批次 AJ·D-60）。两份并存是依赖图的后果，不是决定——`commons` 不 import `domain`，
   * 加那条边要用户裁定（差异文档 §7 待裁定第 2 条）。等不等价由
   * `entry/src/test/DateLabelTest.ets` 的 `edge_day_and_time_agree_with_the_domain_edge_rule`
   * 逐点核对（含整零点与负数），静态门禁 `span:` 只拦"再抄第三份"。
   */
  static edgeDay(min: number, isEnd: boolean): number {
    if (isEnd && min % DAY_MIN === 0) {
      return min / DAY_MIN - 1;
    }
    return Math.floor(min / DAY_MIN); // day-span-exempt commons 不能 import domain，见上面 KDoc 与 §7 第 2 条
  }

  /**
   * 端点时刻怎么念（D-58）：整零点的**终点**念 "24:00"，其余走 {@link hm}。
   * 「20:00–00:00」看着像零长度，「周五 20:00 到 00:00」读不出是哪一天的尾巴——D-13 当年
   * 就是为这个把跨日窗口的端点加上日期的。这条口径此前抄在 endLabel、stamp 与窗口详情
   * 三处，另有七个调用点压根没接它（批次 AH·D-58 并成这一处）。
   * 班次定义／课程节次那种"距 00:00 多少分钟"不在这儿：那是时刻不是区间的尾巴，
   * 夜班写「20:00–00:00」配合跨天标记本来就是那个意思。
   */
  static edgeTime(min: number, isEnd: boolean): string {
    if (isEnd && min % DAY_MIN === 0) {
      return '24:00';
    }
    return DateLabel.hm(min);
  }

  /** "7小时30分" */
  static duration(minutes: number): string {
    const h = Math.floor(minutes / 60);
    const m = minutes % 60;
    if (h === 0) {
      return m + '分钟';
    }
    if (m === 0) {
      return h + '小时';
    }
    return h + '小时' + m + '分';
  }

  static ymd(epochDay: number): Ymd {
    const d = new Date(epochDay * 86400000);
    const r: Ymd = { y: d.getUTCFullYear(), m: d.getUTCMonth() + 1, d: d.getUTCDate() };
    return r;
  }

  /** "2026-09-14" */
  static iso(epochDay: number): string {
    const p = DateLabel.ymd(epochDay);
    const m = p.m < 10 ? '0' + p.m : '' + p.m;
    const d = p.d < 10 ? '0' + p.d : '' + p.d;
    return p.y + '-' + m + '-' + d;
  }
}
