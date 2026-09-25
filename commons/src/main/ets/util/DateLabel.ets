/** 年月日。 */
export interface Ymd {
  y: number;
  m: number;
  d: number;
}

/** UI 层日期/时间格式化（epochDay 基于"本地日历日"语义）。 */
const WD = ['周一', '周二', '周三', '周四', '周五', '周六', '周日'];

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
    const m = ((min % 1440) + 1440) % 1440;
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
    const sd = Math.floor(startMin / 1440);
    let ed = Math.floor(endMin / 1440);
    let et = DateLabel.hm(endMin);
    if (endMin % 1440 === 0) {
      ed = endMin / 1440 - 1;
      et = '24:00';
    }
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
   * isEnd 且落在整零点时记前一天 24:00，与 DateLabel.endLabel 同一口径。
   */
  static stamp(epochMin: number, isEnd: boolean, todayEpoch: number): string {
    let day = Math.floor(epochMin / 1440);
    let time = DateLabel.hm(epochMin);
    if (isEnd && epochMin % 1440 === 0) {
      day = epochMin / 1440 - 1;
      time = '24:00';
    }
    const offset = day - todayEpoch;
    if (offset === 0) {
      return '今天 ' + time;
    }
    if (offset === 1) {
      return '明天 ' + time;
    }
    return DateLabel.md(day) + ' ' + time;
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
