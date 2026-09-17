import { Course } from '../model/Types';

/**
 * 课程表文本解析器：支持从教务系统复制的文本行或 OCR 行文本解析课程。
 *
 * 每行一门课，支持格式（字段顺序不敏感，"节次/周次"可省略）：
 *   高等数学 周一 第1-2节 1-16周 单周
 *   大学英语 周三 3,4节 2-16周
 *   体育 星期五 5节 1-16周 双周
 * 星期支持：周一..周日/天、周1..周7、星期一..星期日。
 * 解析失败的行保留 error 信息，由确认页逐条修正/丢弃。
 */

/** 单行解析结果（ok=false 时 error 有值）。 */
export interface ParsedCourseLine {
  ok: boolean;
  error: string;
  name: string;
  weekday: number;      // 1..7
  sectionStart: number;
  sectionEnd: number;
  weekFrom: number;
  weekTo: number;
  parity: number;       // 0=每周 1=单周 2=双周
  rawLine: string;
}

const WD_MAP: string[][] = [
  ['一', '1'], ['二', '2'], ['三', '3'], ['四', '4'], ['五', '5'], ['六', '6'], ['日', '7'], ['天', '7']
];

/** 解析多行文本。 */
export function parseCourseText(text: string): ParsedCourseLine[] {
  const lines = text.split(/\r?\n/);
  const out: ParsedCourseLine[] = [];
  for (let i = 0; i < lines.length; i++) {
    const line = lines[i].trim();
    if (line === '') {
      continue;
    }
    out.push(parseCourseLine(line));
  }
  return out;
}

/** 把解析成功的行转为 Course 实体（id 由调用方生成）。 */
export function toCourse(p: ParsedCourseLine, id: string): Course {
  const c: Course = {
    id: id,
    name: p.name,
    weekday: p.weekday,
    sectionStart: p.sectionStart,
    sectionEnd: p.sectionEnd,
    weekFrom: p.weekFrom,
    weekTo: p.weekTo,
    parity: p.parity,
    place: ''
  };
  return c;
}

export function parseCourseLine(raw: string): ParsedCourseLine {
  const r: ParsedCourseLine = {
    ok: false, error: '', name: '', weekday: 0,
    sectionStart: 1, sectionEnd: 2, weekFrom: 1, weekTo: 16, parity: 0, rawLine: raw
  };
  let rest = raw.replace(/，/g, ',').replace(/\s+/g, ' ').trim();

  // 单双周
  if (/单周/.test(rest)) {
    r.parity = 1;
    rest = rest.replace(/单周/g, ' ');
  } else if (/双周/.test(rest)) {
    r.parity = 2;
    rest = rest.replace(/双周/g, ' ');
  }

  // 周次：1-16周 / 第1-16周 / 1~16周
  const weekM = rest.match(/(\d+)\s*[-–~]\s*(\d+)\s*周/);
  if (weekM != null) {
    r.weekFrom = Number.parseInt(weekM[1], 10);
    r.weekTo = Number.parseInt(weekM[2], 10);
    rest = rest.replace(weekM[0], ' ');
  }

  // 节次：第1-2节 / 1,2节 / 第3节
  const secRange = rest.match(/第?\s*(\d+)\s*[-~,]\s*(\d+)\s*节/);
  if (secRange != null) {
    r.sectionStart = Number.parseInt(secRange[1], 10);
    r.sectionEnd = Number.parseInt(secRange[2], 10);
    rest = rest.replace(secRange[0], ' ');
  } else {
    const secOne = rest.match(/第\s*(\d+)\s*节/);
    if (secOne != null) {
      r.sectionStart = Number.parseInt(secOne[1], 10);
      r.sectionEnd = r.sectionStart;
      rest = rest.replace(secOne[0], ' ');
    }
  }

  // 星期：星期一/周二/周3
  const wdM = rest.match(/(?:周|星期)([一二三四五六日天1-7])/);
  if (wdM != null) {
    r.weekday = weekdayOfToken(wdM[1]);
    rest = rest.replace(wdM[0], ' ');
  }

  // 剩余文本即课程名
  r.name = rest.replace(/第?\s*节/g, ' ').replace(/\s+/g, ' ').trim();
  r.name = r.name.replace(/^[-,，\s]+|[-,，\s]+$/g, '');

  // 校验
  if (r.weekday < 1 || r.weekday > 7) {
    r.error = '未识别星期（如：周一）';
    return r;
  }
  if (r.name === '') {
    r.error = '未识别课程名';
    return r;
  }
  if (r.sectionStart < 1 || r.sectionEnd < r.sectionStart || r.sectionEnd > 16) {
    r.error = '节次不合法';
    return r;
  }
  if (r.weekFrom < 1 || r.weekTo < r.weekFrom || r.weekTo > 30) {
    r.error = '周次不合法';
    return r;
  }
  r.ok = true;
  return r;
}

function weekdayOfToken(t: string): number {
  // 数字形式：周1..周7
  if (t >= '1' && t <= '7') {
    return Number.parseInt(t, 10);
  }
  for (let i = 0; i < WD_MAP.length; i++) {
    if (WD_MAP[i][0] === t) {
      return Number.parseInt(WD_MAP[i][1], 10);
    }
  }
  return -1;
}
