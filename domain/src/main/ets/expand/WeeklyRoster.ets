import { MySchedule, RosterDay, ShiftType, ShiftSegment, Interval, MIN_PER_DAY, WeeklyScheduleState } from '../model/Types';
import { cycleShiftAt } from './CycleExpander';

// 最多24小时核心、24小时通勤、24小时恢复；次日班次的上班通勤可能提前到今日。
export const ROSTER_LOOKBACK_DAYS: number = 3;
export const ROSTER_LOOKAHEAD_DAYS: number = 1;

export function shiftSegments(st: ShiftType): ShiftSegment[] {
  return st.segments != null && st.segments.length > 0 ? st.segments
    : [{ startMin: st.startMin, endMin: st.endMin, crossDay: st.crossDay }];
}
export function shiftSnapshot(st: ShiftType): ShiftType { return JSON.parse(JSON.stringify(st)) as ShiftType; }
export function rosterSnapshot(day: RosterDay): RosterDay { return JSON.parse(JSON.stringify(day)) as RosterDay; }
export function emptyWeeklyState(): WeeklyScheduleState { return { version: 1, enabled: false, days: [], personal: [] }; }
export function weekMonday(day: number): number { return day - (((day + 3) % 7 + 7) % 7); }

/** 指定日期快照优先；没有新记录才兼容已有循环与覆盖。 */
export function rosterDayOf(schedule: MySchedule, day: number): RosterDay {
  const explicit = (schedule.datedDays ?? []).find((d: RosterDay): boolean => d.epochDay === day);
  if (explicit != null) return rosterSnapshot(explicit);
  const ov = schedule.overrides.find(o => o.epochDay === day);
  const id = ov != null ? ov.shiftTypeId : schedule.template != null ? cycleShiftAt(schedule.template, day) : null;
  const type = id != null ? schedule.shiftTypes.find((s: ShiftType): boolean => s.id === id) : undefined;
  if (type != null) return { epochDay: day, status: 'WORK', entries: [shiftSnapshot(type)] };
  const knownRest = (ov != null && ov.shiftTypeId == null) || (schedule.template != null && id == null);
  return { epochDay: day, status: knownRest ? 'REST' : 'UNKNOWN', entries: [] };
}
export function rosterCore(day: RosterDay): Interval[] {
  const out: Interval[] = [];
  for (const st of day.entries) for (const segment of shiftSegments(st)) {
    const end = segment.endMin + (segment.crossDay || segment.endMin <= segment.startMin ? MIN_PER_DAY : 0);
    out.push({ start: day.epochDay * MIN_PER_DAY + segment.startMin, end: day.epochDay * MIN_PER_DAY + end, tag: st.name });
  }
  return out;
}
export function shiftError(st: ShiftType): string {
  if (typeof st.id !== 'string' || st.id.length === 0 || typeof st.name !== 'string' || st.name.trim().length === 0
    || st.name.length > 60 || typeof st.color !== 'string' || !/^#([a-fA-F0-9]{6}|[a-fA-F0-9]{8})$/.test(st.color)) return '班次名称或颜色不正确';
  const segments = shiftSegments(st);
  if (segments.length > 8) return '一个班次最多设置8个时段';
  for (const s of segments) {
    if (!Number.isInteger(s.startMin) || !Number.isInteger(s.endMin) || s.startMin < 0 || s.startMin >= MIN_PER_DAY
      || s.endMin < 0 || s.endMin >= MIN_PER_DAY) return '请设置有效的开始和结束时间';
    const duration = s.endMin + (s.crossDay || s.endMin <= s.startMin ? MIN_PER_DAY : 0) - s.startMin;
    if (duration <= 0 || duration > MIN_PER_DAY) return '单段时间不能超过24小时';
  }
  for (const value of [st.commuteInMin, st.commuteOutMin, st.recoveryMin]) {
    if (!Number.isInteger(value) || value < 0 || value > MIN_PER_DAY) return '通勤或恢复时间不正确';
  }
  const parts = rosterCore({ epochDay: 0, status: 'WORK', entries: [st] }).sort((a: Interval,b: Interval): number => a.start-b.start);
  for (let i=1;i<parts.length;i++) if (parts[i].start < parts[i-1].end) return '班次中的时段不能重叠';
  return '';
}
export function rosterError(days: RosterDay[]): string {
  const seen = new Set<number>();
  const intervals: Interval[] = [];
  for (const day of days) {
    if (!Number.isInteger(day.epochDay) || day.epochDay < 0 || seen.has(day.epochDay)
      || ['WORK','REST','UNKNOWN'].indexOf(day.status) < 0 || !Array.isArray(day.entries)) return '日期或班表状态不正确';
    seen.add(day.epochDay);
    if ((day.status === 'WORK') !== (day.entries.length > 0) || day.entries.length > 16) return '工作日需要班次；休息和未安排不能带有班次';
    for (const st of day.entries) { const message = shiftError(st); if (message !== '') return message; }
    intervals.push(...rosterCore(day));
  }
  intervals.sort((a: Interval,b: Interval): number => a.start-b.start);
  for (let i=1;i<intervals.length;i++) if (intervals[i].start < intervals[i-1].end) return '「'+intervals[i-1].tag+'」和「'+intervals[i].tag+'」实际工作时间重叠（含跨夜），请调整后保存';
  return '';
}
export function replaceRosterDays(current: RosterDay[], changes: RosterDay[]): RosterDay[] {
  const changed = new Set<number>(); for (const day of changes) changed.add(day.epochDay);
  return current.filter((day: RosterDay): boolean => !changed.has(day.epochDay)).concat(changes.map(rosterSnapshot))
    .sort((a: RosterDay,b: RosterDay): number => a.epochDay-b.epochDay);
}
export function copyRosterWeek(source: RosterDay[], current: RosterDay[], targets: number[], strategy: string): RosterDay[] {
  if (source.length !== 7 || targets.length === 0 || targets.length > 52 || ['KEEP','REPLACE','MERGE'].indexOf(strategy)<0)
    throw new Error('请选择有效的目标周和处理方式');
  const base = weekMonday(source[0].epochDay);
  const changes: RosterDay[] = [];
  for (const target of Array.from(new Set<number>(targets))) {
    if (weekMonday(target)!==target || target===base) throw new Error('目标请选择其他周的周一');
    for (let i=0;i<7;i++) {
      const from = source.find((d: RosterDay): boolean => d.epochDay === base+i);
      if (from == null || from.status==='UNKNOWN') continue;
      const old = current.find((d: RosterDay): boolean => d.epochDay === target+i);
      if (old != null && old.status !== 'UNKNOWN' && strategy==='KEEP') continue;
      if (old?.status==='WORK' && from.status==='REST' && strategy==='MERGE') continue;
      const next = rosterSnapshot(from); next.epochDay=target+i;
      next.entries.forEach((st: ShiftType,index: number) => { st.id='dated-'+target+'-'+i+'-'+index+'-'+Date.now(); });
      if (strategy==='MERGE' && old?.status==='WORK' && next.status==='WORK') next.entries=old.entries.concat(next.entries);
      changes.push(next);
    }
  }
  return changes;
}
