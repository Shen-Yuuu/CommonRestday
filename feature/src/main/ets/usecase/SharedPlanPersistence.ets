import { SharedPlanRepo, SharedPlanSession, SharedStoredActivity, SharedStoredRow } from 'data';
import { SharedPlanRecord, SharedPlanState, sharedPlanActivity, validSharedPlanRecord } from '../model/SharedPlanFlow';
import { SharedPlanContext, SharedPlanDraftCommand, SharedPlanStoragePort, SharedPlanArchiveCandidate } from './SharedPlanUseCase';

function sessionOf(ctx: SharedPlanContext): SharedPlanSession {
  return { pairId: ctx.pairId, actorId: ctx.actorId, generation: ctx.generation };
}

/** Installed only by the future authenticated/encrypted gateway; not attached to legacy pairing. */
export class SharedPlanPersistence implements SharedPlanStoragePort {
  cursor(ctx: SharedPlanContext): Promise<number> { return SharedPlanRepo.cursor(sessionOf(ctx)); }
  saveCursor(ctx: SharedPlanContext, cursor: number): Promise<boolean> { return SharedPlanRepo.saveCursor(sessionOf(ctx), cursor); }
  voted(ctx: SharedPlanContext): Promise<string[]> { return SharedPlanRepo.voted(sessionOf(ctx)); }
  async markVotes(ctx: SharedPlanContext, candidates: SharedPlanArchiveCandidate[]): Promise<void> {
    for (const candidate of candidates) await SharedPlanRepo.markVote(sessionOf(ctx), candidate.planId, candidate.stateVersion);
  }
  current(ctx: SharedPlanContext): Promise<boolean> { return SharedPlanRepo.isCurrent(sessionOf(ctx)); }
  async list(ctx: SharedPlanContext): Promise<SharedPlanRecord[]> {
    const result: SharedPlanRecord[] = [];
    for (const raw of await SharedPlanRepo.records(sessionOf(ctx))) {
      const row = JSON.parse(raw) as SharedPlanRecord;
      if (!validSharedPlanRecord(row)) throw new Error('Invalid shared plan cache');
      result.push(row);
    }
    return result;
  }
  apply(ctx: SharedPlanContext, records: SharedPlanRecord[]): Promise<boolean> {
    const rows: SharedStoredRow[] = [];
    for (const row of records) {
      if (!validSharedPlanRecord(row)) throw new Error('Invalid shared plan projection');
      const activity = sharedPlanActivity(row);
      let stored: SharedStoredActivity | null = null;
      if (activity !== null) stored = { id: activity.id, title: activity.content.title, kind: activity.content.kind,
        start: activity.content.start, end: activity.content.end, contentRevision: activity.contentRevision };
      rows.push({ pairId: row.pairId, planId: row.planId, stateVersion: row.stateVersion,
        recordJson: JSON.stringify(row), terminal: row.state !== SharedPlanState.PENDING && row.state !== SharedPlanState.ACCEPTED,
        activity: stored });
    }
    return SharedPlanRepo.apply(sessionOf(ctx), rows);
  }
  enqueue(ctx: SharedPlanContext, command: SharedPlanDraftCommand): Promise<void> {
    return SharedPlanRepo.enqueue(sessionOf(ctx), command.requestId, JSON.stringify(command));
  }
  async pending(ctx: SharedPlanContext): Promise<SharedPlanDraftCommand[]> {
    const result: SharedPlanDraftCommand[] = [];
    for (const request of await SharedPlanRepo.pending(sessionOf(ctx))) {
      const command = JSON.parse(request.commandJson) as SharedPlanDraftCommand;
      if (command.requestId !== request.requestId) throw new Error('Invalid shared request cache');
      result.push(command);
    }
    return result;
  }
  finish(ctx: SharedPlanContext, requestId: string): Promise<void> {
    return SharedPlanRepo.finishRequest(sessionOf(ctx), requestId);
  }
}
