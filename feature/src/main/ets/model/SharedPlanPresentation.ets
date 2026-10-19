import { SharedPlanAction, SharedPlanRecord, SharedPlanState, validSharedPlanRecord } from './SharedPlanFlow';
import { PlanSummary } from './PresentationModels';

export interface PlanListEntry {
  id: string;
  start: number;
  local: PlanSummary | null;
  shared: SharedPlanRecord | null;
}

/** A single chronology, not separate local/cloud sections. Local shared projections are never duplicated. */
export function planListEntries(local: PlanSummary[], shared: SharedPlanRecord[], nowMin: number): PlanListEntry[] {
  const entries: PlanListEntry[] = [];
  for (const p of visibleLocalPlans(local, nowMin)) {
    entries.push({ id: 'local:' + p.id, start: p.start, local: p, shared: null });
  }
  for (const p of visibleSharedPlans(shared, nowMin)) {
    const content = p.pendingContent ?? p.acceptedContent;
    entries.push({ id: 'shared:' + p.pairId + ':' + p.planId, start: content?.start ?? Number.MAX_SAFE_INTEGER,
      local: null, shared: p });
  }
  entries.sort((a: PlanListEntry, b: PlanListEntry): number => a.start - b.start || a.id.localeCompare(b.id));
  return entries;
}

/** Current list only. Keep ended records available to historical calendars and occupancy queries. */
export function visibleLocalPlans(source: PlanSummary[], nowMin: number): PlanSummary[] {
  const rows = source.filter((p: PlanSummary): boolean =>
    p.status !== 'CANCELLED' && !p.id.startsWith('shared:') && p.end > nowMin);
  rows.sort((a: PlanSummary, b: PlanSummary): number => a.start - b.start || a.id.localeCompare(b.id));
  return rows;
}

/** Display-only: terminal tombstones still reject stale replies in persistence.
 * An unconfirmed future amendment remains actionable even after the accepted interval ends.
 * Withdrawing only an amendment leaves the original accepted plan visible until its end. */
export function visibleSharedPlans(source: SharedPlanRecord[], nowMin: number): SharedPlanRecord[] {
  const rows = source.filter((p: SharedPlanRecord): boolean =>
    (p.state === SharedPlanState.PENDING || p.state === SharedPlanState.ACCEPTED)
      && ((p.pendingContent !== null && p.pendingContent.end > nowMin)
        || (p.state === SharedPlanState.ACCEPTED && p.acceptedContent !== null && p.acceptedContent.end > nowMin)));
  rows.sort((a: SharedPlanRecord, b: SharedPlanRecord): number => {
    const left = a.pendingContent ?? a.acceptedContent;
    const right = b.pendingContent ?? b.acceptedContent;
    const delta = (left?.start ?? Number.MAX_SAFE_INTEGER) - (right?.start ?? Number.MAX_SAFE_INTEGER);
    return delta !== 0 ? delta : a.planId.localeCompare(b.planId);
  });
  return rows;
}

export function showPlanEmpty(readsReady: boolean, localCount: number, sharedCount: number): boolean {
  return readsReady && localCount === 0 && sharedCount === 0;
}

export function sharedActions(row: SharedPlanRecord, actor: string): SharedPlanAction[] {
  if (!validSharedPlanRecord(row) || (actor !== row.proposerUid && actor !== row.recipientUid)) return [];
  const actions: SharedPlanAction[] = [];
  if (row.pendingContent !== null) {
    if (row.pendingAuthorUid === actor) actions.push(SharedPlanAction.WITHDRAW);
    else { actions.push(SharedPlanAction.ACCEPT); actions.push(SharedPlanAction.DECLINE); }
  }
  if (row.state === SharedPlanState.ACCEPTED) {
    if (row.pendingContent === null) actions.push(SharedPlanAction.AMEND);
    actions.push(SharedPlanAction.CANCEL);
  }
  return actions;
}

export enum SharedPlanDrawerAction { EXPORT = 'EXPORT', AMEND = 'AMEND', CANCEL = 'CANCEL' }
export interface SharedPlanDrawerItem { action: SharedPlanDrawerAction; enabled: boolean; }

/** Invitations remain explicit; confirmed management belongs to the native swipe drawer. */
export function sharedInlineActions(row: SharedPlanRecord, actor: string): SharedPlanAction[] {
  return sharedActions(row, actor).filter((action: SharedPlanAction): boolean =>
    action !== SharedPlanAction.AMEND && action !== SharedPlanAction.CANCEL);
}

export function sharedDrawerActions(row: SharedPlanRecord, actor: string): SharedPlanDrawerItem[] {
  if (!validSharedPlanRecord(row) || row.state !== SharedPlanState.ACCEPTED
    || (actor !== row.proposerUid && actor !== row.recipientUid)) return [];
  return [
    { action: SharedPlanDrawerAction.EXPORT, enabled: true },
    { action: SharedPlanDrawerAction.AMEND, enabled: row.pendingContent === null },
    { action: SharedPlanDrawerAction.CANCEL, enabled: true }
  ];
}
export function sharedActionLabel(action: SharedPlanAction): string {
  if (action === SharedPlanAction.ACCEPT) return '同意';
  if (action === SharedPlanAction.DECLINE) return '暂不安排';
  if (action === SharedPlanAction.WITHDRAW) return '撤回申请';
  if (action === SharedPlanAction.AMEND) return '申请改期';
  return '取消计划';
}
export function sharedResultMessage(code: string): string {
  if (code === 'OK') return '已同步';
  if (code === 'SAVED_RECOMPUTE_PENDING') return '已保存，页面计算待刷新';
  if (code === 'SYNC_MORE') return '已更新部分记录，下拉继续同步剩余历史';
  if (code === 'CLEANUP_PENDING') return '连接已停止，历史数据还在分批清理，请手动继续检查连接';
  if (code === 'LOCAL_CONFLICT') return '这个时间与你现在的日程冲突，请重新选时间';
  if (code === 'LOCAL_CONFLICT_RESULT_UNRESOLVED') return '尚未查到原请求的提交回执，且原时段与当前日程冲突，未重新发送。可核实或关闭未提交请求后重新安排';
  if (code === 'RETRY_TIME_PASSED') return '尚未查到原请求的提交回执，且开始时间已过，未重新发送。请关闭未提交请求后重新安排';
  if (code === 'REQUEST_CLOSED') return '未提交请求已安全关闭，可以重新安排';
  if (code === 'REQUEST_ALREADY_COMMITTED') return '原请求实际已提交，已恢复计划，没有取消';
  if (code === 'REQUEST_CHANGED') return '待核实请求已变化，请查看当前记录后再操作';
  if (code === 'VERSION_CONFLICT' || code === 'STATE_CONFLICT') return '对方已更新计划，请刷新后再操作';
  if (code === 'TIME_PASSED' || code === 'INVITE_EXPIRED') return '这个邀请的时间已过，请重新安排';
  if (code === 'REQUEST_PENDING' || code === 'RESULT_UNKNOWN' || code === 'BAD_RECORD') return '结果待核实，请点「核实 / 重试」，不要重复创建';
  if (code === 'SECURE_SESSION_REQUIRED') return '请先在「我的 · 伴侣与同步」完成配对；已配对可点「完成连接」';
  if (code === 'SESSION_CHANGED' || code === 'SESSION_REVOKED') return '配对信息已变化，未修改当前计划';
  if (code === 'BUSY') return '正在处理，请稍候';
  if (code === 'BACKLOG_FULL' || code === 'CLEANUP_REQUIRED') return '这次连接的记录已达到安全容量，请联系开发者处理，已有计划仍保留';
  if (code === 'FEATURE_DISABLED') return '共同计划同步暂未开放，已有记录仍可查看';
  if (code === 'NOTHING_TO_RETRY') return '没有待核实的请求';
  if (code === 'READ_FAILED') return '暂时无法读取计划，请手动核实，已有计划仍保留';
  if (code === 'BAD_COUNTER' || code === 'STORAGE_NOT_READY')
    return '云端计划存储暂时异常，请保留诊断信息；修复后点「核实 / 重试」，不要重复创建';
  if (code === 'BAD_ENVELOPE') return '计划加密数据未通过校验，未创建新计划';
  if (code === 'CAPABILITY_UNAVAILABLE' || code === 'CONFIG_MISSING') return '共同计划云服务配置尚未就绪，请保留诊断信息';
  if (code === 'FORBIDDEN' || code === 'AUTH_REJECTED') return '计划连接校验未通过，请检查「伴侣与同步」中的连接状态';
  if (code === 'BAD_CONTENT' || code === 'BAD_REQUEST') return '计划内容未通过校验，请检查标题和起止时间';
  if (code === 'RETRY_REVIEW_REQUIRED') return '原请求仍待核实，请保留记录并联系开发者，不要重复创建';
  return '这次操作未完成，原有计划已保留';
}

/** Only uncertain writes lock the editor; a definite local validation error remains editable. */
export function sharedPlanNeedsReview(code: string): boolean {
  return ['REQUEST_PENDING', 'RESULT_UNKNOWN', 'BAD_RECORD', 'READ_FAILED',
    'LOCAL_CONFLICT_RESULT_UNRESOLVED', 'RETRY_TIME_PASSED', 'RETRY_REVIEW_REQUIRED', 'BAD_COUNTER', 'STORAGE_NOT_READY'].includes(code);
}
