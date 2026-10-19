import { SharedPlanRepo, SecurePairingRepo, SettingsStore } from 'data';
import { nowEpochMin } from 'domain';
import { SharedPlanContent, SharedPlanRecord, validSharedPlanRecord, sharedPlanPendingCount } from '../model/SharedPlanFlow';
import { SecurePairingIntent } from './SecurePairingUseCase';
import { visibleSharedPlans } from '../model/SharedPlanPresentation';
import { SharedPlanDraftCommand } from './SharedPlanUseCase';

export interface SharedPlanViewData {
  pairId: string; actorId: string; rows: SharedPlanRecord[]; pendingCount: number; unresolved: boolean; linked: boolean;
  unresolvedRequests?: SharedPlanDraftCommand[];
}
function validRequestContent(content: SharedPlanContent | null): boolean {
  return content !== null && content !== undefined && typeof content.title === 'string'
    && content.title.trim().length > 0 && content.title.length <= 120 && typeof content.kind === 'string'
    && /^[a-z][a-z0-9_]{0,63}$/.test(content.kind) && Number.isSafeInteger(content.start)
    && Number.isSafeInteger(content.end) && content.start >= 0 && content.end - content.start >= 15;
}
/** Reading a page never initializes Auth, gets a Push token, or makes a cloud request. */
export class SharedPlanViewService {
  static async read(): Promise<SharedPlanViewData> {
    const session = await SharedPlanRepo.session();
    const out: SharedPlanViewData = { pairId: '', actorId: '', rows: [], pendingCount: 0, unresolved: false, linked: false };
    if (session === null) return out;
    out.pairId = session.pairId; out.actorId = session.actorId;
    for (const raw of await SharedPlanRepo.records(session)) {
      const row = JSON.parse(raw) as SharedPlanRecord;
      if (!validSharedPlanRecord(row) || row.pairId !== session.pairId
        || (row.proposerUid !== session.actorId && row.recipientUid !== session.actorId)) throw new Error('Invalid plan cache');
      out.rows.push(row);
    }
    if (!await SharedPlanRepo.isCurrent(session)) return { pairId: '', actorId: '', rows: [], pendingCount: 0,
      unresolved: false, linked: false };
    const nowMin = nowEpochMin();
    out.rows = visibleSharedPlans(out.rows, nowMin);
    out.pendingCount = sharedPlanPendingCount(out.rows.filter((row: SharedPlanRecord): boolean =>
      row.pendingContent !== null && row.pendingContent.end > nowMin), out.pairId);
    const pending = await SharedPlanRepo.pending(session);
    out.unresolved = pending.length > 0;
    out.unresolvedRequests = [];
    for (const request of pending) {
      const command = JSON.parse(request.commandJson) as SharedPlanDraftCommand;
      if (command === null || command.requestId !== request.requestId || typeof command.planId !== 'string'
        || !/^[A-Za-z0-9_-]{1,128}$/.test(command.planId)
        || !Number.isSafeInteger(command.expectedVersion) || command.expectedVersion < 0
        || ['PROPOSE', 'ACCEPT', 'AMEND', 'WITHDRAW', 'DECLINE', 'CANCEL'].indexOf(command.action) < 0
        || ((command.action === 'PROPOSE' || command.action === 'AMEND') ? !validRequestContent(command.nextContent) : command.nextContent !== null)
        || (command.checkedContent !== undefined && command.checkedContent !== null && !validRequestContent(command.checkedContent)))
        throw new Error('Invalid pending plan request');
      out.unresolvedRequests.push(command);
    }
    try {
      const intent = JSON.parse(await SecurePairingRepo.load()) as SecurePairingIntent;
      out.linked = intent !== null && intent.phase === 'ACTIVE' && intent.flowId === session.generation
        && typeof intent.linkEnvelope === 'string' && intent.linkEnvelope.length > 0
        && intent.anchor === SettingsStore.getPairState() + '|' + SettingsStore.getPairId();
    } catch { out.linked = false; }
    return await SharedPlanRepo.isCurrent(session) ? out : { pairId: '', actorId: '', rows: [], pendingCount: 0,
      unresolved: false, linked: false };
  }
}
