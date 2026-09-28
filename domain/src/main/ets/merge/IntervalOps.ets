import { Interval } from '../model/Types';

/** 快速构造区间。 */
export function mkIv(start: number, end: number, tag: string): Interval {
  const iv: Interval = { start: start, end: end, tag: tag };
  return iv;
}

/**
 * 区间合并：排序后合并相交或相接（end == next.start）的区间。
 * 合并后保留起始更早区间的 tag。
 */
export function mergeIntervals(list: Interval[]): Interval[] {
  const sorted = list.filter((iv: Interval) => iv.end > iv.start).sort((a: Interval, b: Interval) => a.start - b.start);
  const out: Interval[] = [];
  for (let i = 0; i < sorted.length; i++) {
    const cur = sorted[i];
    if (out.length === 0) {
      out.push(mkIv(cur.start, cur.end, cur.tag));
      continue;
    }
    const last = out[out.length - 1];
    if (cur.start <= last.end) {
      if (cur.end > last.end) {
        last.end = cur.end;
      }
    } else {
      out.push(mkIv(cur.start, cur.end, cur.tag));
    }
  }
  return out;
}

/** 双方区间求并。 */
export function unionIntervals(a: Interval[], b: Interval[]): Interval[] {
  const all: Interval[] = [];
  for (let i = 0; i < a.length; i++) {
    all.push(a[i]);
  }
  for (let i = 0; i < b.length; i++) {
    all.push(b[i]);
  }
  return mergeIntervals(all);
}

/** 一段区间被裁进窗口后剩下的那一段（`clipInto` 的返回形状）。 */
export interface Clip {
  start: number;
  end: number;
}

/**
 * 把半开区间 [start,end) 裁进 [from,to)，得到"只属于窗口内的那一段"。
 * 判据是相接不算：end == from 或 start == to 都裁成空，返回 null，而不是给一条零长度区间。
 * 按日展开、按视界展开、算某天共多少分钟，全仓都读这一条——别再各处手写 max/min 一对。
 */
export function clipInto(start: number, end: number, from: number, to: number): Clip | null {
  const s = Math.max(start, from);
  const e = Math.min(end, to);
  if (e <= s) {
    return null;
  }
  const out: Clip = { start: s, end: e };
  return out;
}

/** 在 [from, to) 内取补集，得到空闲区间（tag=FREE）。 */
export function complement(busyMerged: Interval[], from: number, to: number): Interval[] {
  const free: Interval[] = [];
  let cursor = from;
  for (let i = 0; i < busyMerged.length; i++) {
    const iv = busyMerged[i];
    if (iv.end <= cursor) {
      continue;
    }
    if (iv.start >= to) {
      break;
    }
    const c = clipInto(iv.start, iv.end, from, to);
    if (c == null) {
      continue;
    }
    if (c.start > cursor) {
      free.push(mkIv(cursor, c.start, 'FREE'));
    }
    cursor = Math.max(cursor, c.end);
  }
  if (cursor < to) {
    free.push(mkIv(cursor, to, 'FREE'));
  }
  return free;
}

/** 区间列表在 [from, to) 内的覆盖总时长（分钟）。 */
export function totalOverlap(list: Interval[], from: number, to: number): number {
  const merged = mergeIntervals(list);
  let sum = 0;
  for (let i = 0; i < merged.length; i++) {
    const c = clipInto(merged[i].start, merged[i].end, from, to);
    if (c != null) {
      sum += c.end - c.start;
    }
  }
  return sum;
}

/** 两个区间的交叠分钟数。 */
export function overlapMin(aStart: number, aEnd: number, bStart: number, bEnd: number): number {
  const c = clipInto(aStart, aEnd, bStart, bEnd);
  return c == null ? 0 : c.end - c.start;
}

/**
 * 半开区间 [start,end) 与 [from,to) 算不算"有交叠"——就是 `clipInto` 那条判据的谓词形状，
 * 相接（`end == from`／`start == to`）不算。只想筛掉不相交区间的调用点读它，
 * 别在页面上再写一遍 `a.start < to && a.end > from`（那种写法一旦写成 `<=`／`>=` 就多出一天）。
 */
export function intersects(start: number, end: number, from: number, to: number): boolean {
  return clipInto(start, end, from, to) != null;
}
