import { Interval, MIN_PER_DAY } from '../model/Types';
import { mkIv } from '../merge/IntervalOps';

/**
 * 快照编解码（明文层；加密在 cloud 层）。
 *
 * 快照是"对方可见内容的唯一来源"，按隐私等级降维：
 * - L1 忙闲：仅 30 分钟位图（含对方睡眠/缓冲，全部记为忙）
 * - L2 班次类型：位图 + 30 分钟量化的分段标签
 * - L3 完整时间：分钟级精确分段 + 标签
 *
 * 文本格式（行分隔）：
 *   CRD1|<version>|<level>|<startEpochDay>|<days>
 *   B:<hex 位图，L1/L2>
 *   S:<startMin>,<endMin>,<tag>;...（L2/L3，epochMin）
 */

/** 快照明文数据。 */
export interface SnapshotData {
  version: number;
  shareLevel: number;
  startEpochDay: number;
  days: number;
  /** L1/L2：30 分钟粒度忙闲位图，长度 days*48，true=不可用。 */
  busy30: boolean[];
  /** L2/L3：不可用分段（L2 为 30 分钟量化，L3 为精确值），epochMin。 */
  segments: Interval[];
}

const MAGIC = 'CRD1';
const SLOT = 30;

export class SnapshotCodec {
  /** 编码为传输文本。 */
  static encode(data: SnapshotData): string {
    const head = MAGIC + '|' + data.version + '|' + data.shareLevel + '|'
      + data.startEpochDay + '|' + data.days;
    const lines: string[] = [];
    lines.push(head);
    if (data.shareLevel === 1 || data.shareLevel === 2) {
      lines.push('B:' + SnapshotCodec.bitsToHex(data.busy30));
    }
    if (data.shareLevel === 2 || data.shareLevel === 3) {
      const parts: string[] = [];
      for (let i = 0; i < data.segments.length; i++) {
        const s = data.segments[i];
        parts.push(s.start + ',' + s.end + ',' + s.tag);
      }
      lines.push('S:' + parts.join(';'));
    }
    return lines.join('\n');
  }

  /** 解码传输文本；格式非法返回 null。 */
  static decode(text: string): SnapshotData | null {
    const lines = text.split('\n');
    if (lines.length === 0) {
      return null;
    }
    const head = lines[0].split('|');
    if (head.length !== 5 || head[0] !== MAGIC) {
      return null;
    }
    const version = Number.parseInt(head[1], 10);
    const level = Number.parseInt(head[2], 10);
    const startDay = Number.parseInt(head[3], 10);
    const days = Number.parseInt(head[4], 10);
    if (Number.isNaN(version) || Number.isNaN(level) || Number.isNaN(startDay) || Number.isNaN(days)
      || level < 1 || level > 3 || days <= 0) {
      return null;
    }
    const bitsLen = days * (MIN_PER_DAY / SLOT);
    const busy30: boolean[] = new Array<boolean>(bitsLen);
    for (let i = 0; i < bitsLen; i++) {
      busy30[i] = false;
    }
    const segments: Interval[] = [];
    for (let i = 1; i < lines.length; i++) {
      const line = lines[i];
      if (line.startsWith('B:')) {
        const hex = line.substring(2);
        // 完整性校验：位图 hex 长度必须为 days*48/4，且不含非法字符，防止损坏数据被静默当成"空闲"
        if (hex.length !== bitsLen / 4 || !SnapshotCodec.hexValid(hex)) {
          return null;
        }
        SnapshotCodec.hexToBits(hex, busy30);
      } else if (line.startsWith('S:')) {
        const parts = line.substring(2).split(';');
        for (let j = 0; j < parts.length; j++) {
          if (parts[j] === '') {
            continue;
          }
          const f = parts[j].split(',');
          if (f.length !== 3) {
            return null;
          }
          const s = Number.parseInt(f[0], 10);
          const e = Number.parseInt(f[1], 10);
          if (Number.isNaN(s) || Number.isNaN(e) || e <= s) {
            return null;
          }
          segments.push(mkIv(s, e, f[2]));
        }
      }
    }
    const data: SnapshotData = {
      version: version,
      shareLevel: level,
      startEpochDay: startDay,
      days: days,
      busy30: busy30,
      segments: segments
    };
    return data;
  }

  /** 快照 → 对方忙碌区间（引擎输入）。 */
  static toIntervals(data: SnapshotData): Interval[] {
    const out: Interval[] = [];
    if (data.shareLevel === 1) {
      const base = data.startEpochDay * MIN_PER_DAY;
      let runStart = -1;
      for (let i = 0; i < data.busy30.length; i++) {
        if (data.busy30[i] && runStart < 0) {
          runStart = base + i * SLOT;
        }
        if ((!data.busy30[i] || i === data.busy30.length - 1) && runStart >= 0) {
          const runEnd = data.busy30[i] ? base + (i + 1) * SLOT : base + i * SLOT;
          out.push(mkIv(runStart, runEnd, 'BUSY'));
          runStart = -1;
        }
      }
    } else {
      for (let i = 0; i < data.segments.length; i++) {
        out.push(mkIv(data.segments[i].start, data.segments[i].end, data.segments[i].tag));
      }
    }
    return out;
  }

  private static bitsToHex(bits: boolean[]): string {
    let out = '';
    let acc = 0;
    let n = 0;
    for (let i = 0; i < bits.length; i++) {
      if (bits[i]) {
        acc |= (1 << n);
      }
      n++;
      if (n === 4) {
        out += SnapshotCodec.hexChar(acc);
        acc = 0;
        n = 0;
      }
    }
    if (n > 0) {
      out += SnapshotCodec.hexChar(acc);
    }
    return out;
  }

  private static hexChar(v: number): string {
    if (v < 10) {
      return String.fromCharCode(48 + v);
    }
    return String.fromCharCode(87 + v);
  }

  private static hexVal(c: string): number {
    const code = c.charCodeAt(0);
    if (code >= 48 && code <= 57) {
      return code - 48;
    }
    if (code >= 97 && code <= 102) {
      return code - 87;
    }
    return -1;
  }

  private static hexValid(hex: string): boolean {
    for (let i = 0; i < hex.length; i++) {
      if (SnapshotCodec.hexVal(hex.charAt(i)) < 0) {
        return false;
      }
    }
    return true;
  }

  private static hexToBits(hex: string, bits: boolean[]): void {
    let bi = 0;
    for (let i = 0; i < hex.length && bi < bits.length; i++) {
      const v = SnapshotCodec.hexVal(hex.charAt(i));
      if (v < 0) {
        continue;
      }
      for (let b = 0; b < 4 && bi < bits.length; b++) {
        bits[bi] = (v & (1 << b)) !== 0;
        bi++;
      }
    }
  }
}
