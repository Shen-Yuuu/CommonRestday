import { MIN_PER_DAY, dayOfStart, dayOfEnd, intersects } from 'domain';
import { DateLabel } from 'commons';

export interface AgendaSource {
  id: string;
  start: number;
  end: number;
  name: string;
  kind: string;
}

export interface TodayAgendaItem {
  id: string;
  timeText: string;
  name: string;
  kind: string;
}

function agendaEdge(min: number, isEnd: boolean, epochDay: number): string {
  const day = isEnd ? dayOfEnd(min) : dayOfStart(min);
  const time = DateLabel.edgeTime(min, isEnd);
  if (day === epochDay) {
    return time;
  }
  if (day === epochDay - 1) {
    return '昨晚 ' + time;
  }
  if (day === epochDay + 1) {
    return '明天 ' + time;
  }
  return DateLabel.md(day) + ' ' + time;
}

/** 本地安排的展示投影，不计算忙闲、不读云端，不把恢复缓冲当成一条安排。 */
export function buildTodayAgenda(sources: AgendaSource[], epochDay: number): TodayAgendaItem[] {
  const start = epochDay * MIN_PER_DAY;
  const end = start + MIN_PER_DAY;
  const selected = sources.filter((s: AgendaSource): boolean => {
    return Number.isFinite(s.start) && Number.isFinite(s.end) && s.end > s.start
      && intersects(s.start, s.end, start, end)
      && (s.kind === 'SHIFT' || s.kind === 'SHIFT_COMMUTE' || s.kind === 'COURSE' || s.kind === 'PLAN' || s.kind === 'PERSONAL');
  });
  selected.sort((a: AgendaSource, b: AgendaSource): number => {
    if (a.start !== b.start) {
      return a.start - b.start;
    }
    if (a.end !== b.end) {
      return a.end - b.end;
    }
    return a.id === b.id ? 0 : (a.id < b.id ? -1 : 1);
  });
  return selected.map((s: AgendaSource): TodayAgendaItem => {
    return {
      id: s.id, name: s.name, kind: s.kind,
      timeText: agendaEdge(s.start, false, epochDay) + '–' + agendaEdge(s.end, true, epochDay)
    };
  });
}
