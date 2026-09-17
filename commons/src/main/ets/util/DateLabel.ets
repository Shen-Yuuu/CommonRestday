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
