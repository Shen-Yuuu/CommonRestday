import { HomeSummary, TodayAgendaItem } from 'feature';

/** 视觉比例只读草稿，不反向改动真实时间。 */
export function rangeRatio(start: number, end: number, value: number): number {
  if (!Number.isFinite(start) || !Number.isFinite(end) || !Number.isFinite(value) || end <= start) {
    return 0;
  }
  return Math.max(0, Math.min(1, (value - start) / (end - start)));
}

export function lerpRatio(from: number, to: number, progress: number): number {
  return from + (to - from) * Math.max(0, Math.min(1, progress));
}

/** 忽略纯计算时间戳，比较用户实际看到的首页内容。 */
export function homeContentKey(home: HomeSummary | null, agenda: TodayAgendaItem[], agendaFailed: boolean): string {
  if (home === null) {
    return '';
  }
  return [home.mode, home.partnerName, JSON.stringify(home.tonight), JSON.stringify(home.fullRestDay),
    JSON.stringify(home.trip), JSON.stringify(home.nextWindow), home.conflictCount.toString(),
    home.conflictReason, JSON.stringify(home.today), home.stale.toString(),
    JSON.stringify(agenda), agendaFailed.toString()].join('\u001f');
}
