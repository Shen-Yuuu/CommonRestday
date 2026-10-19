/** Pure shared-plan rules. A candidate is NEVER a cloud commit or a local activity write. */
export enum SharedPlanState {
  PENDING = 'PENDING',
  ACCEPTED = 'ACCEPTED',
  DECLINED = 'DECLINED',
  WITHDRAWN = 'WITHDRAWN',
  EXPIRED = 'EXPIRED',
  CANCELLED = 'CANCELLED'
}

export enum SharedPlanAction {
  ACCEPT = 'ACCEPT',
  DECLINE = 'DECLINE',
  WITHDRAW = 'WITHDRAW',
  CANCEL = 'CANCEL',
  AMEND = 'AMEND'
}

export interface SharedPlanContent {
  title: string;
  kind: string;
  start: number;
  end: number;
}

export interface SharedPlanRecord {
  pairId: string;
  planId: string;
  proposerUid: string;
  recipientUid: string;
  state: SharedPlanState;
  stateVersion: number;
  contentRevision: number;
  acceptedRevision: number;
  acceptedContent: SharedPlanContent | null;
  pendingContent: SharedPlanContent | null;
  pendingAuthorUid: string;
}

export interface SharedPlanCommand {
  action: SharedPlanAction;
  actorUid: string;
  expectedVersion: number;
  nextContent: SharedPlanContent | null;
  nowMin: number;
}

export interface SharedPlanTransition {
  code: string;
  record: SharedPlanRecord;
}

export interface SharedPlanActivity {
  id: string;
  pairId: string;
  planId: string;
  contentRevision: number;
  content: SharedPlanContent;
}

function safeId(value: string): boolean {
  return typeof value === 'string' && value.length > 0 && value.length <= 128 && /^[A-Za-z0-9_-]+$/.test(value);
}

function validContent(value: SharedPlanContent | null): boolean {
  return value !== null && value !== undefined && typeof value.title === 'string'
    && value.title.trim().length > 0 && value.title.length <= 120
    && typeof value.kind === 'string' && /^[a-z][a-z0-9_]{0,63}$/.test(value.kind)
    && Number.isSafeInteger(value.start) && Number.isSafeInteger(value.end)
    && value.start >= 0 && value.end - value.start >= 15;
}

function copyContent(value: SharedPlanContent | null): SharedPlanContent | null {
  if (value === null) return null;
  return { title: value.title, kind: value.kind, start: value.start, end: value.end };
}

function copyRecord(row: SharedPlanRecord): SharedPlanRecord {
  return {
    pairId: row.pairId, planId: row.planId, proposerUid: row.proposerUid, recipientUid: row.recipientUid,
    state: row.state, stateVersion: row.stateVersion, contentRevision: row.contentRevision,
    acceptedRevision: row.acceptedRevision, acceptedContent: copyContent(row.acceptedContent),
    pendingContent: copyContent(row.pendingContent), pendingAuthorUid: row.pendingAuthorUid
  };
}

function memberOf(row: SharedPlanRecord, uid: string): boolean {
  return uid === row.proposerUid || uid === row.recipientUid;
}

export function validSharedPlanRecord(row: SharedPlanRecord): boolean {
  if (!safeId(row.pairId) || !safeId(row.planId) || !safeId(row.proposerUid) || !safeId(row.recipientUid)
    || row.proposerUid === row.recipientUid || !Number.isSafeInteger(row.stateVersion) || row.stateVersion < 1
    || !Number.isSafeInteger(row.contentRevision) || row.contentRevision < 1
    || !Number.isSafeInteger(row.acceptedRevision) || row.acceptedRevision < 0
    || row.acceptedRevision > row.contentRevision) return false;
  if (row.state === SharedPlanState.PENDING) {
    return row.acceptedRevision === 0 && row.acceptedContent === null && validContent(row.pendingContent)
      && row.pendingAuthorUid === row.proposerUid;
  }
  if (row.state === SharedPlanState.ACCEPTED) {
    return row.acceptedRevision > 0 && validContent(row.acceptedContent)
      && ((row.pendingContent === null && row.pendingAuthorUid === '')
        || (validContent(row.pendingContent) && memberOf(row, row.pendingAuthorUid)
          && row.contentRevision > row.acceptedRevision));
  }
  if (row.state === SharedPlanState.DECLINED || row.state === SharedPlanState.WITHDRAWN || row.state === SharedPlanState.EXPIRED) {
    return row.pendingContent === null && row.pendingAuthorUid === '' && row.acceptedRevision === 0 && row.acceptedContent === null;
  }
  if (row.state === SharedPlanState.CANCELLED) {
    return row.pendingContent === null && row.pendingAuthorUid === '' && row.acceptedRevision > 0 && validContent(row.acceptedContent);
  }
  return false;
}

function validRecord(row: SharedPlanRecord): boolean { return validSharedPlanRecord(row); }

export function initialSharedPlan(pairId: string, planId: string, proposerUid: string, recipientUid: string,
  content: SharedPlanContent): SharedPlanRecord {
  if (!safeId(pairId) || !safeId(planId) || !safeId(proposerUid) || !safeId(recipientUid)
    || proposerUid === recipientUid || !validContent(content)) throw new Error('Invalid shared-plan draft');
  return { pairId: pairId, planId: planId, proposerUid: proposerUid, recipientUid: recipientUid,
    state: SharedPlanState.PENDING, stateVersion: 1, contentRevision: 1, acceptedRevision: 0,
    acceptedContent: null, pendingContent: copyContent(content), pendingAuthorUid: proposerUid };
}

/** Role UID must already come from verified member binding, not an untrusted request body.
 * Returns an isolated candidate; caller must wait for authoritative cloud commit before persisting it.
 * Time/content checks are client-side only because the server cannot decrypt the invitation. */
export function evaluateSharedPlanAction(row: SharedPlanRecord, command: SharedPlanCommand): SharedPlanTransition {
  const candidate = copyRecord(row);
  if (!validRecord(row) || !Number.isSafeInteger(command.expectedVersion)
    || !Number.isSafeInteger(command.nowMin) || command.nowMin < 0) return { code: 'BAD_RECORD', record: candidate };
  if (!memberOf(row, command.actorUid)) return { code: 'FORBIDDEN', record: candidate };
  if (command.expectedVersion !== row.stateVersion) return { code: 'VERSION_CONFLICT', record: candidate };
  if (row.stateVersion >= Number.MAX_SAFE_INTEGER) return { code: 'BAD_RECORD', record: candidate };

  if (command.action === SharedPlanAction.AMEND) {
    if (row.state !== SharedPlanState.ACCEPTED || row.pendingContent !== null) return { code: 'STATE_CONFLICT', record: candidate };
    if (!validContent(command.nextContent) || row.contentRevision >= Number.MAX_SAFE_INTEGER) return { code: 'BAD_CONTENT', record: candidate };
    const next = command.nextContent;
    if (next !== null && next.start < command.nowMin) return { code: 'TIME_PASSED', record: candidate };
    candidate.pendingContent = copyContent(next);
    candidate.pendingAuthorUid = command.actorUid;
    candidate.contentRevision++;
  } else if (command.action === SharedPlanAction.CANCEL) {
    if (row.state !== SharedPlanState.ACCEPTED) return { code: 'STATE_CONFLICT', record: candidate };
    candidate.state = SharedPlanState.CANCELLED;
    candidate.pendingContent = null;
    candidate.pendingAuthorUid = '';
  } else {
    if ((row.state !== SharedPlanState.PENDING && row.state !== SharedPlanState.ACCEPTED)
      || row.pendingContent === null) return { code: 'STATE_CONFLICT', record: candidate };
    const withdrawing = command.action === SharedPlanAction.WITHDRAW;
    if (command.action !== SharedPlanAction.ACCEPT && command.action !== SharedPlanAction.DECLINE && !withdrawing) {
      return { code: 'BAD_ACTION', record: candidate };
    }
    if ((withdrawing && command.actorUid !== row.pendingAuthorUid)
      || (!withdrawing && command.actorUid === row.pendingAuthorUid)) return { code: 'FORBIDDEN', record: candidate };
    if (command.action === SharedPlanAction.ACCEPT) {
      if (row.pendingContent.start < command.nowMin) return { code: 'TIME_PASSED', record: candidate };
      candidate.state = SharedPlanState.ACCEPTED;
      candidate.acceptedContent = copyContent(row.pendingContent);
      candidate.acceptedRevision = row.contentRevision;
    } else if (row.state === SharedPlanState.PENDING) {
      candidate.state = withdrawing ? SharedPlanState.WITHDRAWN : SharedPlanState.DECLINED;
    }
    candidate.pendingContent = null;
    candidate.pendingAuthorUid = '';
  }
  candidate.stateVersion++;
  return { code: 'OK', record: candidate };
}

/** Invoke only on validated, decrypted, authoritative cloud records. No optimistic activity. */
export function sharedPlanActivity(row: SharedPlanRecord): SharedPlanActivity | null {
  if (!validRecord(row) || row.state !== SharedPlanState.ACCEPTED || row.acceptedContent === null) return null;
  const content = row.acceptedContent;
  return { id: 'shared:' + row.pairId + ':' + row.planId, pairId: row.pairId, planId: row.planId,
    contentRevision: row.acceptedRevision,
    content: { title: content.title, kind: content.kind, start: content.start, end: content.end } };
}

export function sharedPlanPendingCount(rows: SharedPlanRecord[], pairId: string): number {
  const latest: Map<string, SharedPlanRecord> = new Map<string, SharedPlanRecord>();
  for (const row of rows) {
    if (row.pairId !== pairId || !validRecord(row)) continue;
    const previous = latest.get(row.planId);
    if (previous === undefined || row.stateVersion > previous.stateVersion) latest.set(row.planId, row);
  }
  let pending = 0;
  latest.forEach((row: SharedPlanRecord) => { if (row.pendingContent !== null) pending++; });
  return pending;
}

export function sharedPlanAad(pairId: string, planId: string, contentRevision: number): string {
  if (!safeId(pairId) || !safeId(planId) || !Number.isSafeInteger(contentRevision) || contentRevision < 1) {
    throw new Error('Invalid shared-plan envelope identity');
  }
  return 'FT_DATEPLAN|' + pairId + '|' + planId + '|' + contentRevision + '|1';
}

/** Equal versions are immutable; duplicates are no-ops. Old-session responses cannot populate a new pair. */
export function shouldApplySharedPlan(current: SharedPlanRecord | null, incoming: SharedPlanRecord, pairId: string): boolean {
  if (incoming.pairId !== pairId || !validRecord(incoming)) return false;
  if (current === null) return true;
  if (current.state === SharedPlanState.CANCELLED || current.state === SharedPlanState.DECLINED
    || current.state === SharedPlanState.WITHDRAWN || current.state === SharedPlanState.EXPIRED) return false;
  return current.pairId === incoming.pairId && current.planId === incoming.planId
    && current.proposerUid === incoming.proposerUid && current.recipientUid === incoming.recipientUid
    && incoming.stateVersion > current.stateVersion && incoming.contentRevision >= current.contentRevision
    && incoming.acceptedRevision >= current.acceptedRevision;
}

export function sharedPlanStateLabel(row: SharedPlanRecord, myUid: string): string {
  if (!validRecord(row) || !memberOf(row, myUid)) return '计划状态暂不可确认';
  if (row.pendingContent !== null) {
    return row.pendingAuthorUid === myUid ? '等待 TA 确认' : '待我确认';
  }
  if (row.state === SharedPlanState.ACCEPTED) return '已确认';
  if (row.state === SharedPlanState.DECLINED) return '暂不安排';
  if (row.state === SharedPlanState.WITHDRAWN) return '已撤回';
  if (row.state === SharedPlanState.EXPIRED) return '已过期';
  if (row.state === SharedPlanState.CANCELLED) return '已取消';
  return '计划状态暂不可确认';
}
