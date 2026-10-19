import { describe, it, expect } from '@ohos/hypium';
import { SharedPlanUseCase, SharedPlanContext, SharedPlanDraftCommand, SharedPlanReply, SharedPlanGatewayPort,
  SharedPlanStoragePort, SharedPlanLocalPort, SharedPlanRecord, SharedPlanContent, SharedPlanAction,
  initialSharedPlan, evaluateSharedPlanAction, sharedPlanActivity } from 'feature';

function draft(): SharedPlanContent { return { title: '午餐', kind: 'meal', start: 600, end: 660 }; }
function invited(): SharedPlanRecord { return initialSharedPlan('pair-a', 'plan-a', 'member-a', 'member-b', draft()); }
function agreed(): SharedPlanRecord {
  return evaluateSharedPlanAction(invited(), { action: SharedPlanAction.ACCEPT, actorUid: 'member-b',
    expectedVersion: 1, nextContent: null, nowMin: 500 }).record;
}

class Fixture implements SharedPlanGatewayPort, SharedPlanStoragePort, SharedPlanLocalPort {
  ctx: SharedPlanContext | null = { pairId: 'pair-a', actorId: 'member-a', peerId: 'member-b',
    generation: 'generation-a', protocolVersion: 1, projectionVersion: 1 };
  rows: SharedPlanRecord[] = [];
  commands: SharedPlanDraftCommand[] = [];
  sent: string[] = [];
  log: string[] = [];
  reply: SharedPlanReply = { code: 'OK', records: [] };
  failNetwork: boolean = false;
  switchSession: boolean = false;
  conflict: boolean = false;
  failRecompute: boolean = false;
  tick: number = 0;
  excluded: string = '';
  resolved: SharedPlanReply = { code: 'REQUEST_NOT_COMMITTED', records: [] };
  async resolve(ctx: SharedPlanContext, command: SharedPlanDraftCommand): Promise<SharedPlanReply> {
    this.log.push('resolve'); return this.resolved;
  }
  async context(): Promise<SharedPlanContext | null> { return this.ctx; }
  async current(ctx: SharedPlanContext): Promise<boolean> { return this.ctx !== null && this.ctx.generation === ctx.generation; }
  async list(ctx: SharedPlanContext): Promise<SharedPlanRecord[]> { return this.rows; }
  async apply(ctx: SharedPlanContext, rows: SharedPlanRecord[]): Promise<boolean> {
    if (!await this.current(ctx)) return false;
    this.log.push('apply');
    for (const row of rows) {
      this.rows = this.rows.filter((old: SharedPlanRecord) => old.planId !== row.planId);
      this.rows.push(row);
    }
    return true;
  }
  async enqueue(ctx: SharedPlanContext, command: SharedPlanDraftCommand): Promise<void> {
    this.log.push('enqueue');
    if (!this.commands.some((old: SharedPlanDraftCommand) => old.requestId === command.requestId)) this.commands.push(command);
  }
  async pending(ctx: SharedPlanContext): Promise<SharedPlanDraftCommand[]> { return this.commands; }
  async finish(ctx: SharedPlanContext, requestId: string): Promise<void> {
    this.log.push('finish'); this.commands = this.commands.filter((command: SharedPlanDraftCommand) => command.requestId !== requestId);
  }
  async read(ctx: SharedPlanContext): Promise<SharedPlanReply> { if (this.failNetwork) throw new Error('offline'); return this.reply; }
  async send(ctx: SharedPlanContext, command: SharedPlanDraftCommand): Promise<SharedPlanReply> {
    this.log.push('send'); this.sent.push(JSON.stringify(command));
    if (this.switchSession && this.ctx !== null) this.ctx = { pairId: 'pair-b', actorId: 'member-a', peerId: 'member-c',
      generation: 'generation-b', protocolVersion: 1, projectionVersion: 1 };
    if (this.failNetwork) throw new Error('offline');
    if (command.action === 'PROPOSE' && this.reply.code === 'OK') return { code: 'OK',
      records: [initialSharedPlan(ctx.pairId, command.planId, ctx.actorId, ctx.peerId, draft())] };
    return this.reply;
  }
  nowMin(): number { return 500; }
  newId(): string { this.tick++; return 'id-' + this.tick; }
  async canArrange(content: SharedPlanContent, excluding: string): Promise<boolean> { this.excluded = excluding; return !this.conflict; }
  async recompute(): Promise<void> { this.log.push('recompute'); if (this.failRecompute) throw new Error('recompute'); }
  usecase(): SharedPlanUseCase { return new SharedPlanUseCase(this, this, this); }
}

export default function sharedPlanUseCaseTest() {
  describe('sharedPlanUseCase', () => {
    it('receipt_resolves_committed_accept_even_when_schedule_now_conflicts', 0, async () => {
      const f = new Fixture(); f.rows = [invited()]; f.failNetwork = true;
      if (f.ctx !== null) { f.ctx.actorId = 'member-b'; f.ctx.peerId = 'member-a'; }
      const use = f.usecase();
      expect(await use.respond('plan-a', SharedPlanAction.ACCEPT)).assertEqual('RESULT_UNKNOWN');
      f.conflict = true; f.resolved = { code: 'OK', records: [agreed()] };
      expect(await use.retry()).assertEqual('OK');
      expect(f.sent.length).assertEqual(1); expect(f.commands.length).assertEqual(0);
      expect(f.rows[0].stateVersion).assertEqual(2);
    });
    it('receipt_failure_keeps_original_request_without_resending', 0, async () => {
      const f = new Fixture(); f.failNetwork = true; const use = f.usecase();
      expect(await use.propose(draft())).assertEqual('RESULT_UNKNOWN');
      f.resolved = { code: 'RESULT_UNKNOWN', records: [] };
      expect(await use.retry()).assertEqual('RESULT_UNKNOWN');
      expect(f.sent.length).assertEqual(1); expect(f.commands.length).assertEqual(1);
    });
    it('legacy_or_unknown_projection_never_sends', 0, async () => {
      const f = new Fixture(); if (f.ctx !== null) f.ctx.projectionVersion = 0;
      expect(await f.usecase().propose(draft())).assertEqual('SECURE_SESSION_REQUIRED');
      expect(f.sent.length).assertEqual(0); expect(f.commands.length).assertEqual(0);
    });
    it('propose_persists_before_network_and_pending_does_not_occupy', 0, async () => {
      const f = new Fixture(); expect(await f.usecase().propose(draft())).assertEqual('OK');
      expect(f.log.indexOf('enqueue') < f.log.indexOf('send')).assertTrue();
      expect(sharedPlanActivity(f.rows[0]) === null).assertTrue(); expect(f.commands.length).assertEqual(0);
    });
    it('offline_accept_is_not_optimistically_confirmed', 0, async () => {
      const f = new Fixture(); f.rows = [invited()]; f.failNetwork = true;
      if (f.ctx !== null) { f.ctx.actorId = 'member-b'; f.ctx.peerId = 'member-a'; }
      expect(await f.usecase().respond('plan-a', SharedPlanAction.ACCEPT)).assertEqual('RESULT_UNKNOWN');
      expect(sharedPlanActivity(f.rows[0]) === null).assertTrue(); expect(f.commands.length).assertEqual(1);
    });
    it('manual_retry_reuses_exact_command_and_request_id', 0, async () => {
      const f = new Fixture(); const use = f.usecase(); f.failNetwork = true;
      expect(await use.propose(draft())).assertEqual('RESULT_UNKNOWN');
      expect(await use.propose(draft())).assertEqual('REQUEST_PENDING');
      f.failNetwork = false; expect(await use.retry()).assertEqual('OK');
      expect(f.sent[0]).assertEqual(f.sent[1]); expect(f.commands.length).assertEqual(0);
    });
    it('changed_schedule_blocks_ambiguous_proposal_retry_without_discarding_original_request', 0, async () => {
      const f = new Fixture(); const use = f.usecase(); f.failNetwork = true;
      expect(await use.propose(draft())).assertEqual('RESULT_UNKNOWN');
      f.failNetwork = false; f.conflict = true;
      expect(await use.retry()).assertEqual('LOCAL_CONFLICT_RESULT_UNRESOLVED');
      expect(f.sent.length).assertEqual(1); expect(f.commands.length).assertEqual(1);
      f.conflict = false; expect(await use.retry()).assertEqual('OK');
      expect(f.sent[0]).assertEqual(f.sent[1]);
    });
    it('accept_retry_checks_original_content_even_if_cache_has_changed', 0, async () => {
      const f = new Fixture(); f.rows = [invited()]; f.failNetwork = true;
      if (f.ctx !== null) { f.ctx.actorId = 'member-b'; f.ctx.peerId = 'member-a'; }
      expect(await f.usecase().respond('plan-a', SharedPlanAction.ACCEPT)).assertEqual('RESULT_UNKNOWN');
      f.rows = []; f.conflict = true;
      expect(await f.usecase().retry()).assertEqual('LOCAL_CONFLICT_RESULT_UNRESOLVED');
      expect(f.sent.length).assertEqual(1); expect(f.commands.length).assertEqual(1);
      expect(f.excluded).assertEqual('plan-a');
    });
    it('cloud_unknown_keeps_durable_retry_after_usecase_recreation', 0, async () => {
      const f = new Fixture(); f.reply = { code: 'RESULT_UNKNOWN', records: [] };
      expect(await f.usecase().propose(draft())).assertEqual('RESULT_UNKNOWN');
      f.reply = { code: 'OK', records: [] };
      expect(await f.usecase().retry()).assertEqual('OK'); expect(f.sent[0]).assertEqual(f.sent[1]);
    });
    it('wrong_session_reply_never_populates_cache', 0, async () => {
      const f = new Fixture(); f.switchSession = true;
      expect(await f.usecase().propose(draft())).assertEqual('SESSION_CHANGED'); expect(f.rows.length).assertEqual(0);
    });
    it('double_click_is_busy_not_two_new_invitations', 0, async () => {
      const f = new Fixture(); const use = f.usecase();
      const first = use.propose(draft()); const second = use.propose(draft());
      expect(await second).assertEqual('BUSY'); expect(await first).assertEqual('OK'); expect(f.sent.length).assertEqual(1);
    });
    it('refresh_cannot_rollback_confirmed_version', 0, async () => {
      const f = new Fixture(); f.rows = [agreed()]; f.reply = { code: 'OK', records: [invited()] };
      expect(await f.usecase().refresh()).assertEqual('OK'); expect(f.rows[0].stateVersion).assertEqual(2);
    });
    it('local_conflict_and_past_time_do_not_enqueue', 0, async () => {
      const f = new Fixture(); f.conflict = true;
      expect(await f.usecase().propose(draft())).assertEqual('LOCAL_CONFLICT');
      const past = draft(); past.start = 300; past.end = 360;
      expect(await f.usecase().propose(past)).assertEqual('TIME_PASSED'); expect(f.sent.length).assertEqual(0);
    });
    it('malformed_success_keeps_request_and_never_projects', 0, async () => {
      const f = new Fixture(); f.rows = [invited()]; if (f.ctx !== null) { f.ctx.actorId = 'member-b'; f.ctx.peerId = 'member-a'; }
      f.reply = { code: 'OK', records: [] };
      expect(await f.usecase().respond('plan-a', SharedPlanAction.ACCEPT)).assertEqual('BAD_RECORD');
      expect(f.commands.length).assertEqual(1); expect(sharedPlanActivity(f.rows[0]) === null).assertTrue();
    });
    it('accepted_amendment_excludes_only_its_own_local_projection', 0, async () => {
      const f = new Fixture(); f.rows = [agreed()];
      const next = draft(); next.start = 900; next.end = 960;
      f.reply = { code: 'OK', records: [evaluateSharedPlanAction(agreed(), { action: SharedPlanAction.AMEND,
        actorUid: 'member-a', expectedVersion: 2, nextContent: next, nowMin: 500 }).record] };
      expect(await f.usecase().respond('plan-a', SharedPlanAction.AMEND, next)).assertEqual('OK');
      expect(f.excluded).assertEqual('plan-a'); const activity = sharedPlanActivity(f.rows[0]);
      if (activity !== null) expect(activity.content.start).assertEqual(600);
    });
    it('recompute_failure_is_saved_not_a_false_cloud_failure', 0, async () => {
      const f = new Fixture(); f.failRecompute = true; f.rows = [invited()];
      if (f.ctx !== null) { f.ctx.actorId = 'member-b'; f.ctx.peerId = 'member-a'; }
      f.reply = { code: 'OK', records: [agreed()] };
      expect(await f.usecase().respond('plan-a', SharedPlanAction.ACCEPT)).assertEqual('SAVED_RECOMPUTE_PENDING');
      expect(f.rows.length).assertEqual(1); expect(f.commands.length).assertEqual(0);
    });
    it('pending_proposal_does_not_recompute_even_if_engine_is_unavailable', 0, async () => {
      const f = new Fixture(); f.failRecompute = true;
      expect(await f.usecase().propose(draft())).assertEqual('OK');
      expect(f.log.indexOf('recompute')).assertEqual(-1);
    });
    it('version_conflict_keeps_cache_and_releases_old_retry_command', 0, async () => {
      const f = new Fixture(); f.rows = [agreed()]; f.reply = { code: 'VERSION_CONFLICT', records: [] };
      expect(await f.usecase().respond('plan-a', SharedPlanAction.CANCEL)).assertEqual('VERSION_CONFLICT');
      expect(f.rows[0].stateVersion).assertEqual(2); expect(f.commands.length).assertEqual(0);
    });
    it('actual_dateplan_terminal_codes_release_the_request_without_changing_the_cache', 0, async () => {
      for (const code of ['REQUEST_REUSED', 'BAD_ENVELOPE', 'VERSION_LIMIT', 'INVITE_EXPIRED']) {
        const f = new Fixture(); f.rows = [agreed()]; f.reply = { code: code, records: [] };
        expect(await f.usecase().respond('plan-a', SharedPlanAction.CANCEL)).assertEqual(code);
        expect(f.commands.length).assertEqual(0); expect(f.rows[0].stateVersion).assertEqual(2);
      }
    });
  });
}
