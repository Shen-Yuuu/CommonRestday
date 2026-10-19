import { SharedPlanAction, SharedPlanContent, SharedPlanRecord,
  evaluateSharedPlanAction, initialSharedPlan, shouldApplySharedPlan, sharedPlanActivity, validSharedPlanRecord } from '../model/SharedPlanFlow';
import { SerialQueue } from '../model/SerialQueue';
import { SingleFlight } from '../model/SingleFlight';
import { SharedPlanDiagnostic } from '../model/SharedPlanDiagnostic';

export interface SharedPlanSessionIdentity {
  pairId: string;
  actorId: string;
  generation: string;
}
export interface SharedPlanContext extends SharedPlanSessionIdentity {
  peerId: string;
  protocolVersion: number;
  projectionVersion: number;
}

/** Local plaintext draft ONLY. A real gateway must encrypt it before any network request. */
export interface SharedPlanDraftCommand {
  requestId: string;
  planId: string;
  action: string;
  expectedVersion: number;
  nextContent: SharedPlanContent | null;
  /** Local-only original candidate, so an ambiguous ACCEPT retry never consults a different revision. */
  checkedContent?: SharedPlanContent | null;
}

export interface SharedPlanReply {
  code: string;
  records: SharedPlanRecord[];
}
export interface SharedPlanPage extends SharedPlanReply {
  context: SharedPlanContext | null;
  cursor: number;
  more: boolean;
  incremental: boolean;
}
export interface SharedPlanArchiveCandidate { planId: string; stateVersion: number; }

export interface SharedPlanGatewayPort {
  diagnostic?(): SharedPlanDiagnostic | null;
  /** Must come from server-verified secure membership + peer capability, not legacy Preferences. */
  context(): Promise<SharedPlanContext | null>;
  /** Local identity/session fence after context verification, never a substitute for server auth. */
  current?(context: SharedPlanContext): Promise<boolean>;
  read(context: SharedPlanContext): Promise<SharedPlanReply>;
  send(context: SharedPlanContext, command: SharedPlanDraftCommand): Promise<SharedPlanReply>;
  resolve?(context: SharedPlanContext, command: SharedPlanDraftCommand): Promise<SharedPlanReply>;
  /** Atomically fences an uncommitted request, or returns its existing immutable receipt. */
  close?(context: SharedPlanContext, command: SharedPlanDraftCommand): Promise<SharedPlanReply>;
  /** Each response verifies live membership; capability memory is NOT cached authorization. */
  sync?(cursor: (context: SharedPlanContext) => Promise<number>): Promise<SharedPlanPage>;
  acknowledge?(context: SharedPlanContext, cursor: number, candidates: SharedPlanArchiveCandidate[]): Promise<string>;
}

export interface SharedPlanStoragePort {
  current(context: SharedPlanContext): Promise<boolean>;
  list(context: SharedPlanContext): Promise<SharedPlanRecord[]>;
  apply(context: SharedPlanContext, records: SharedPlanRecord[]): Promise<boolean>;
  enqueue(context: SharedPlanContext, command: SharedPlanDraftCommand): Promise<void>;
  pending(context: SharedPlanContext): Promise<SharedPlanDraftCommand[]>;
  finish(context: SharedPlanContext, requestId: string): Promise<void>;
  cursor?(context: SharedPlanContext): Promise<number>;
  saveCursor?(context: SharedPlanContext, cursor: number): Promise<boolean>;
  voted?(context: SharedPlanContext): Promise<string[]>;
  markVotes?(context: SharedPlanContext, candidates: SharedPlanArchiveCandidate[]): Promise<void>;
}

export interface SharedPlanLocalPort {
  nowMin(): number;
  newId(): string;
  /** Re-read the latest local schedule; no claim about an offline peer's real-time availability. */
  canArrange(content: SharedPlanContent, excludingPlanId: string): Promise<boolean>;
  recompute(): Promise<void>;
  /** Record-only changes update pending cards/badges without a full availability recompute. */
  changed?(): void;
}

function sameContext(a: SharedPlanContext, b: SharedPlanContext | null): boolean {
  return b !== null && a.pairId === b.pairId && a.actorId === b.actorId && a.peerId === b.peerId
    && a.generation === b.generation && b.protocolVersion === 1 && b.projectionVersion === 1;
}

/** No default transport: secure crypto/identity must be installed explicitly before UI activation. */
export class SharedPlanUseCase {
  private queue: SerialQueue = new SerialQueue();
  private submitting: boolean = false;
  private refreshFlight: SingleFlight<string> = new SingleFlight<string>();
  private availabilityDirty: boolean = false;
  private createdId: string = '';
  private archiveScanKey: string = '';
  lastCreatedId(): string { return this.createdId; }
  diagnostic(): SharedPlanDiagnostic | null { return this.gateway.diagnostic === undefined ? null : this.gateway.diagnostic(); }
  private gateway: SharedPlanGatewayPort;
  private storage: SharedPlanStoragePort;
  private local: SharedPlanLocalPort;
  constructor(gateway: SharedPlanGatewayPort, storage: SharedPlanStoragePort, local: SharedPlanLocalPort) {
    this.gateway = gateway; this.storage = storage; this.local = local;
  }

  private async context(): Promise<SharedPlanContext | null> {
    const ctx = await this.gateway.context();
    if (ctx === null || ctx.protocolVersion !== 1 || ctx.projectionVersion !== 1
      || ctx.actorId === ctx.peerId || !await this.storage.current(ctx)) return null;
    return ctx;
  }

  private async stillCurrent(ctx: SharedPlanContext): Promise<boolean> {
    if (this.gateway.current !== undefined)
      return await this.gateway.current(ctx) && await this.storage.current(ctx);
    return sameContext(ctx, await this.gateway.context()) && await this.storage.current(ctx);
  }

  private mutation(work: () => Promise<string>): Promise<string> {
    if (this.submitting) return Promise.resolve('BUSY');
    this.refreshFlight.invalidate();
    this.submitting = true;
    return this.queue.run(async (): Promise<string> => {
      try { return await work(); } finally { this.submitting = false; }
    });
  }

  private async apply(ctx: SharedPlanContext, rows: SharedPlanRecord[], deferRecompute: boolean = false): Promise<string> {
    if (!await this.stillCurrent(ctx)) return 'SESSION_CHANGED';
    if (rows.length > 50) return 'BAD_RECORD';
    if (rows.length === 0) {
      // Empty delta needs neither a full historical cache scan nor an empty SQLite write.
      if (this.availabilityDirty && !deferRecompute) {
        try { await this.local.recompute(); this.availabilityDirty = false; } catch { return 'SAVED_RECOMPUTE_PENDING'; }
      }
      return 'OK';
    }
    for (const row of rows) {
      if (!validSharedPlanRecord(row) || row.pairId !== ctx.pairId
        || !((row.proposerUid === ctx.actorId && row.recipientUid === ctx.peerId)
          || (row.proposerUid === ctx.peerId && row.recipientUid === ctx.actorId))) return 'BAD_RECORD';
    }
    const cached = await this.storage.list(ctx);
    const updates: SharedPlanRecord[] = [];
    let occupancyChanged: boolean = false;
    for (const row of rows) {
      const old = cached.find((item: SharedPlanRecord) => item.planId === row.planId);
      if (shouldApplySharedPlan(old === undefined ? null : old, row, ctx.pairId)) {
        updates.push(row);
        const before = old === undefined ? null : sharedPlanActivity(old);
        const after = sharedPlanActivity(row);
        if ((before === null) !== (after === null)
          || (before !== null && after !== null
            && (before.content.start !== after.content.start || before.content.end !== after.content.end))) occupancyChanged = true;
      }
    }
    if (!await this.storage.apply(ctx, updates)) return 'SESSION_CHANGED';
    if (updates.length > 0 && this.local.changed !== undefined) this.local.changed();
    this.availabilityDirty = this.availabilityDirty || occupancyChanged;
    if (this.availabilityDirty && !deferRecompute) {
      try { await this.local.recompute(); this.availabilityDirty = false; } catch { return 'SAVED_RECOMPUTE_PENDING'; }
    }
    return 'OK';
  }

  refresh(): Promise<string> {
    return this.refreshFlight.run(async (): Promise<string> => {
      let maintenance: SharedPlanPage | null = null;
      const code = await this.queue.run(async (): Promise<string> => {
      if (this.gateway.sync !== undefined && this.storage.cursor !== undefined && this.storage.saveCursor !== undefined) {
        let last: SharedPlanPage | null = null;
        for (let page = 0; page < 10; page++) {
          let result: SharedPlanPage;
          let requestedCursor: number = 0;
          try { result = await this.gateway.sync(async (ctx: SharedPlanContext): Promise<number> => {
            requestedCursor = await this.storage.cursor!(ctx); return requestedCursor;
          }); }
          catch { return 'READ_FAILED'; }
          if (result.code !== 'OK') return result.code;
          const ctx = result.context;
          if (ctx === null || !Number.isSafeInteger(result.cursor) || result.cursor < 0) return 'BAD_RECORD';
          const applied = await this.apply(ctx, result.records, true);
          if (applied !== 'OK') return applied;
          // Crash between apply and cursor save causes a harmless replay, never a skipped change.
          if (result.incremental && result.cursor !== requestedCursor
            && !await this.storage.saveCursor(ctx, result.cursor)) return 'SESSION_CHANGED';
          last = result;
          if (!result.more) break;
        }
        if (this.availabilityDirty) {
          try { await this.local.recompute(); this.availabilityDirty = false; } catch { return 'SAVED_RECOMPUTE_PENDING'; }
        }
        if (last?.incremental && !last.more && last.context !== null) maintenance = last;
        return last?.more ? 'SYNC_MORE' : 'OK';
      }
      const ctx = await this.context(); if (ctx === null) return 'SECURE_SESSION_REQUIRED';
      let result: SharedPlanReply;
      try { result = await this.gateway.read(ctx); } catch { return 'READ_FAILED'; }
      if (result.code !== 'OK') return result.code;
      return this.apply(ctx, result.records);
      });
      // Release the mutation queue first: slow archive acknowledgement cannot hold a user decision hostage.
      const page = maintenance as SharedPlanPage | null;
      if (code === 'OK' && page !== null && page.context !== null) await this.archiveEnded(page.context, page.cursor);
      return code;
    });
  }

  private async archiveEnded(ctx: SharedPlanContext, cursor: number): Promise<void> {
    if (this.gateway.acknowledge === undefined || this.storage.voted === undefined || this.storage.markVotes === undefined) return;
    const key = ctx.pairId + ':' + ctx.actorId + ':' + ctx.generation + ':' + cursor + ':' + this.local.nowMin();
    if (key === this.archiveScanKey) return;
    try {
      const voted = await this.storage.voted(ctx);
      const candidates: SharedPlanArchiveCandidate[] = [];
      for (const row of await this.storage.list(ctx)) {
        const terminal = row.state !== 'PENDING' && row.state !== 'ACCEPTED';
        const ended = row.pendingContent === null && row.acceptedContent !== null && row.acceptedContent.end <= this.local.nowMin();
        if ((terminal || ended) && row.pendingContent === null && voted.indexOf(row.planId + ':' + row.stateVersion) < 0) {
          candidates.push({ planId: row.planId, stateVersion: row.stateVersion });
          if (candidates.length === 10) break;
        }
      }
      if (candidates.length > 0 && await this.stillCurrent(ctx)
        && await this.gateway.acknowledge(ctx, cursor, candidates) === 'OK' && await this.stillCurrent(ctx)) {
        await this.storage.markVotes(ctx, candidates);
        if (candidates.length < 10) this.archiveScanKey = key;
      }
      if (candidates.length === 0) this.archiveScanKey = key;
    } catch { /* Maintenance failure never invalidates a successfully persisted sync or retransmits a decision. */ }
  }

  propose(content: SharedPlanContent): Promise<string> {
    const draft: SharedPlanContent = { title: content.title, kind: content.kind, start: content.start, end: content.end };
    return this.mutation(async (): Promise<string> => {
      const ctx = await this.context(); if (ctx === null) return 'SECURE_SESSION_REQUIRED';
      if ((await this.storage.pending(ctx)).length > 0) return 'REQUEST_PENDING';
      const planId = this.local.newId();
      try { initialSharedPlan(ctx.pairId, planId, ctx.actorId, ctx.peerId, draft); }
      catch { return 'BAD_CONTENT'; }
      if (draft.start < this.local.nowMin()) return 'TIME_PASSED';
      if (!await this.local.canArrange(draft, '')) return 'LOCAL_CONFLICT';
      const command: SharedPlanDraftCommand = { requestId: this.local.newId(), planId: planId,
        action: 'PROPOSE', expectedVersion: 0, nextContent: draft };
      const code = await this.submit(ctx, command);
      if (code === 'OK' || code === 'SAVED_RECOMPUTE_PENDING') this.createdId = 'shared:' + ctx.pairId + ':' + planId;
      return code;
    });
  }

  respond(planId: string, action: SharedPlanAction, next: SharedPlanContent | null = null): Promise<string> {
    const nextDraft: SharedPlanContent | null = next === null ? null
      : { title: next.title, kind: next.kind, start: next.start, end: next.end };
    return this.mutation(async (): Promise<string> => {
      const ctx = await this.context(); if (ctx === null) return 'SECURE_SESSION_REQUIRED';
      if ((await this.storage.pending(ctx)).length > 0) return 'REQUEST_PENDING';
      const row = (await this.storage.list(ctx)).find((item: SharedPlanRecord) => item.planId === planId);
      if (row === undefined) return 'NOT_FOUND';
      const candidate = evaluateSharedPlanAction(row, { action: action, actorUid: ctx.actorId,
        expectedVersion: row.stateVersion, nextContent: nextDraft, nowMin: this.local.nowMin() });
      if (candidate.code !== 'OK') return candidate.code;
      const content = action === SharedPlanAction.ACCEPT ? row.pendingContent
        : action === SharedPlanAction.AMEND ? nextDraft : null;
      if (content !== null && !await this.local.canArrange(content, planId)) return 'LOCAL_CONFLICT';
      const command: SharedPlanDraftCommand = { requestId: this.local.newId(), planId: planId,
        action: action, expectedVersion: row.stateVersion, nextContent: nextDraft, checkedContent: content };
      return this.submit(ctx, command);
    });
  }

  /** Manual only; persisted requestId and payload reused exactly, no next-day timer. */
  retry(): Promise<string> {
    return this.mutation(async (): Promise<string> => {
      // A pending ACCEPT/AMEND is not a newly-created invitation in a reopened create sheet.
      this.createdId = '';
      const ctx = await this.context(); if (ctx === null) return 'SECURE_SESSION_REQUIRED';
      const pending = await this.storage.pending(ctx);
      if (pending.length === 0) return 'NOTHING_TO_RETRY';
      const command = pending[0];
      if (this.gateway.resolve !== undefined) {
        let receipt: SharedPlanReply;
        try { receipt = await this.gateway.resolve(ctx, command); } catch { return 'RESULT_UNKNOWN'; }
        if (!await this.stillCurrent(ctx)) return 'SESSION_CHANGED';
        if (receipt.code === 'OK') {
          if (!receipt.records.some((row: SharedPlanRecord) => row.planId === command.planId)) return 'BAD_RECORD';
          const applied = await this.apply(ctx, receipt.records);
          if (applied === 'OK' || applied === 'SAVED_RECOMPUTE_PENDING') {
            await this.storage.finish(ctx, command.requestId);
            if (command.action === 'PROPOSE') this.createdId = 'shared:' + ctx.pairId + ':' + command.planId;
          }
          return applied;
        }
        if (receipt.code === 'REQUEST_CLOSED') {
          await this.storage.finish(ctx, command.requestId); return receipt.code;
        }
        if (receipt.code !== 'REQUEST_NOT_COMMITTED') return receipt.code;
      }
      let content: SharedPlanContent | null = command.action === 'PROPOSE' || command.action === 'AMEND'
        ? command.nextContent : null;
      if (command.action === 'ACCEPT') {
        content = command.checkedContent ?? null;
        if (content === null) {
          // Compatibility for existing queued requests. Do not replace the persisted draft/wire.
          const row = (await this.storage.list(ctx)).find((item: SharedPlanRecord) => item.planId === command.planId);
          if (row !== undefined && row.stateVersion === command.expectedVersion) content = row.pendingContent;
          if (content === null) return 'RETRY_REVIEW_REQUIRED';
        }
      }
      if (content !== null && content.start < this.local.nowMin()) return 'RETRY_TIME_PASSED';
      if (content !== null && !await this.local.canArrange(content, command.planId)) {
        // The first call might already have committed: retain the request, don't pretend it was cancelled.
        return 'LOCAL_CONFLICT_RESULT_UNRESOLVED';
      }
      const code = await this.submit(ctx, command);
      if ((code === 'OK' || code === 'SAVED_RECOMPUTE_PENDING') && command.action === 'PROPOSE') {
        this.createdId = 'shared:' + ctx.pairId + ':' + command.planId;
      }
      return code;
    });
  }

  /** Explicit user action only. A missing receipt is not sufficient to delete a local request. */
  closePending(requestId: string): Promise<string> {
    return this.mutation(async (): Promise<string> => {
      this.createdId = '';
      const ctx = await this.context(); if (ctx === null) return 'SECURE_SESSION_REQUIRED';
      const pending = await this.storage.pending(ctx);
      if (pending.length === 0) return 'NOTHING_TO_RETRY';
      const command = pending[0];
      if (command.requestId !== requestId) return 'REQUEST_CHANGED';
      if (this.gateway.close === undefined) return 'RETRY_REVIEW_REQUIRED';
      let receipt: SharedPlanReply;
      try { receipt = await this.gateway.close(ctx, command); } catch { return 'RESULT_UNKNOWN'; }
      if (!await this.stillCurrent(ctx)) return 'SESSION_CHANGED';
      if (receipt.code === 'REQUEST_CLOSED') {
        await this.storage.finish(ctx, command.requestId); return 'REQUEST_CLOSED';
      }
      if (receipt.code !== 'OK') return receipt.code;
      if (!receipt.records.some((row: SharedPlanRecord) => row.planId === command.planId)) return 'BAD_RECORD';
      const applied = await this.apply(ctx, receipt.records);
      if (applied === 'OK' || applied === 'SAVED_RECOMPUTE_PENDING') await this.storage.finish(ctx, command.requestId);
      return applied === 'OK' ? 'REQUEST_ALREADY_COMMITTED' : applied;
    });
  }

  private async submit(ctx: SharedPlanContext, command: SharedPlanDraftCommand): Promise<string> {
    if (!await this.stillCurrent(ctx)) return 'SESSION_CHANGED';
    await this.storage.enqueue(ctx, command);
    if (!await this.stillCurrent(ctx)) return 'SESSION_CHANGED';
    let result: SharedPlanReply;
    try { result = await this.gateway.send(ctx, command); } catch { return 'RESULT_UNKNOWN'; }
    if (!await this.stillCurrent(ctx)) return 'SESSION_CHANGED';
    if (result.code === 'RESULT_UNKNOWN') return result.code;
    if (result.code === 'OK') {
      // A malformed/undecryptable success is still unresolved; keep the original request.
      if (!result.records.some((row: SharedPlanRecord) => row.planId === command.planId)) return 'BAD_RECORD';
      const applied = await this.apply(ctx, result.records);
      if (applied !== 'OK' && applied !== 'SAVED_RECOMPUTE_PENDING') return applied;
      await this.storage.finish(ctx, command.requestId);
      return applied;
    }
    // Only a known terminal business verdict permits discarding the retry command.
    if (this.terminal(result.code)) await this.storage.finish(ctx, command.requestId);
    return result.code;
  }

  private terminal(code: string): boolean {
    const terminal = ['FORBIDDEN', 'VERSION_CONFLICT', 'STATE_CONFLICT', 'NOT_FOUND', 'BAD_REQUEST',
      'IDEMPOTENCY_CONFLICT', 'SESSION_REVOKED', 'EXPIRED', 'BACKLOG_FULL',
      'REQUEST_REUSED', 'BAD_ENVELOPE', 'VERSION_LIMIT', 'INVITE_EXPIRED', 'REQUEST_CLOSED'];
    return terminal.indexOf(code) >= 0;
  }
}
