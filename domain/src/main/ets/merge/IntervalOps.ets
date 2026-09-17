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
    const s = Math.max(iv.start, from);
    const e = Math.min(iv.end, to);
    if (s > cursor) {
      free.push(mkIv(cursor, s, 'FREE'));
    }
    cursor = Math.max(cursor, e);
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
    const s = Math.max(merged[i].start, from);
    const e = Math.min(merged[i].end, to);
    if (e > s) {
      sum += e - s;
    }
  }
  return sum;
}

/** 两个区间的交叠分钟数。 */
export function overlapMin(aStart: number, aEnd: number, bStart: number, bEnd: number): number {
  const s = Math.max(aStart, bStart);
  const e = Math.min(aEnd, bEnd);
  return e > s ? e - s : 0;
}
