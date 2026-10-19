/** Production presentation policies plus source wiring; not a rendered/device UI test. */
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const ts = require('D:/local/DevEcoStudio/tools/hvigor/hvigor/node_modules/typescript');
const root = path.resolve(__dirname, '../..');
const cache = new Map();
function source(name) { return fs.readFileSync(path.join(root, name), 'utf8'); }
function load(name) {
  if (cache.has(name)) return cache.get(name);
  const module = { exports: {} }; cache.set(name, module.exports);
  const js = ts.transpileModule(source(name + '.ets'), { compilerOptions: { module: ts.ModuleKind.CommonJS,
    target: ts.ScriptTarget.ES2020 } }).outputText;
  vm.runInNewContext(js, { module, exports: module.exports, require: p => load(path.posix.normalize(
    path.posix.join(path.posix.dirname(name), p))) });
  return module.exports;
}
const policy = load('feature/src/main/ets/model/SharedPlanPresentation');
const flow = load('feature/src/main/ets/model/SharedPlanFlow');
let count = 0;
function test(name, work) { work(); count++; console.log('PASS ' + name); }
const early = flow.initialSharedPlan('pair', 'early', 'a', 'b', { title: '早餐', kind: 'meal', start: 600, end: 660 });
const late = flow.initialSharedPlan('pair', 'late', 'a', 'b', { title: '晚餐', kind: 'meal', start: 1200, end: 1260 });
const cancelled = { ...late, planId: 'cancelled', state: 'CANCELLED', pendingContent: null, pendingAuthorUid: '' };
test('visible shared plans hide cancelled tombstones, sort by displayed start, and preserve source', () => {
  const rows = [late, cancelled, early];
  assert.deepEqual(Array.from(policy.visibleSharedPlans(rows, 0), p => p.planId), ['early', 'late']);
  assert.equal(rows.length, 3); assert.equal(rows[1].state, 'CANCELLED');
});
test('accepted plan and unconfirmed amendment sort by the time shown first on their cards', () => {
  const accepted = { ...late, planId: 'accepted', state: 'ACCEPTED', acceptedRevision: 1,
    pendingContent: null, pendingAuthorUid: '', acceptedContent: late.pendingContent };
  const amended = { ...accepted, planId: 'amended', contentRevision: 2, pendingAuthorUid: 'a',
    pendingContent: { ...early.pendingContent, start: 500 } };
  assert.deepEqual(Array.from(policy.visibleSharedPlans([accepted, amended, early], 0), p => p.planId),
    ['amended', 'early', 'accepted']);
});
test('empty-state policy requires both reads to succeed and no visible plan', () => {
  assert.equal(policy.showPlanEmpty(true, 0, 0), true);
  assert.equal(policy.showPlanEmpty(false, 0, 0), false);
  assert.equal(policy.showPlanEmpty(true, 0, 1), false);
  assert.equal(policy.showPlanEmpty(true, 1, 0), false);
});
test('local and cloud cards form one chronology without cancelled or duplicate projections', () => {
  const local = [{ id: 'personal', start: 900, end: 960, status: 'CONFIRMED' },
    { id: 'shared:pair:early', start: 600, end: 660, status: 'CONFIRMED' },
    { id: 'cancelled', start: 300, end: 360, status: 'CANCELLED' }];
  const entries = policy.planListEntries(local, [late, early, cancelled], 0);
  assert.deepEqual(Array.from(entries, p => p.id), ['shared:pair:early', 'local:personal', 'shared:pair:late']);
});
function transition(row, action, actorUid, nowMin, nextContent = null) {
  const result = flow.evaluateSharedPlanAction(row, { actorUid, action, nowMin, nextContent,
    expectedVersion: row.stateVersion });
  assert.equal(result.code, 'OK');
  return result.record;
}
test('withdrawn, declined, expired and cancelled plans leave the list without deleting records', () => {
  const withdrawn = transition(early, 'WITHDRAW', 'a', 500);
  const declined = transition(late, 'DECLINE', 'b', 500);
  const expired = { ...withdrawn, planId: 'expired', state: 'EXPIRED' };
  const confirmed = transition(late, 'ACCEPT', 'b', 500);
  const ended = transition(confirmed, 'CANCEL', 'a', 500);
  const rows = [withdrawn, declined, expired, ended];
  const snapshot = JSON.stringify(rows);
  assert.equal(policy.visibleSharedPlans(rows, 500).length, 0);
  assert.equal(JSON.stringify(rows), snapshot, 'tombstones and historical content remain persisted');
});
test('end boundary hides past local/cloud plans but keeps ongoing and cross-day plans', () => {
  const accepted = transition(early, 'ACCEPT', 'b', 500);
  assert.equal(policy.visibleSharedPlans([early, accepted], 659).length, 2);
  assert.equal(policy.visibleSharedPlans([early, accepted], 660).length, 0);
  const local = [{ id: 'past', start: 500, end: 600, status: 'CONFIRMED' },
    { id: 'boundary', start: 600, end: 660, status: 'CONFLICT' },
    { id: 'ongoing', start: 650, end: 700, status: 'CONFIRMED' },
    { id: 'cross-day', start: 600, end: 1500, status: 'CONFIRMED' }];
  assert.deepEqual(Array.from(policy.visibleLocalPlans(local, 660), p => p.id), ['cross-day', 'ongoing']);
  assert.equal(policy.planListEntries(local, [early, late], 1500).length, 0);
  assert.equal(policy.showPlanEmpty(true, policy.visibleLocalPlans(local, 1500).length,
    policy.visibleSharedPlans([early, late], 1500).length), true);
  assert.equal(local.length, 4, 'visibility never mutates the source');
});
test('withdrawing an amendment preserves the original accepted plan and its occupancy', () => {
  const confirmed = transition(early, 'ACCEPT', 'b', 500);
  const amended = transition(confirmed, 'AMEND', 'a', 500, late.pendingContent);
  const withdrawn = transition(amended, 'WITHDRAW', 'a', 500);
  assert.equal(withdrawn.state, 'ACCEPTED');
  assert.equal(policy.visibleSharedPlans([withdrawn], 500).length, 1);
  assert.equal(flow.sharedPlanActivity(withdrawn).content.start, 600);
  assert.equal(flow.sharedPlanPendingCount([withdrawn], 'pair'), 0);
  assert.equal(policy.visibleSharedPlans([withdrawn], 660).length, 0);
});
test('future amendment of an ended accepted plan remains actionable until its own end', () => {
  const confirmed = transition(early, 'ACCEPT', 'b', 500);
  const amended = transition(confirmed, 'AMEND', 'a', 500, late.pendingContent);
  assert.equal(policy.visibleSharedPlans([amended], 700).length, 1);
  assert.equal(policy.visibleSharedPlans([amended], 1260).length, 0);
  assert.equal(flow.sharedPlanActivity(amended).content.start, 600, 'no premature projection of the amendment');
});
test('notification toggle replaces refresh button; ambiguous-request retry remains explicit', () => {
  const panel = source('entry/src/main/ets/component/SharedPlansPanel.ets');
  assert.equal(panel.includes("this.run('REFRESH')"), false);
  assert.ok(panel.includes("this.run('RETRY')"));
  assert.ok(panel.indexOf("'关闭计划通知'") < panel.indexOf('if (!this.data.linked)'));
});
test('pull refresh reads shared plans, updates panel even without projection changes, and never retries writes', () => {
  const view = source('entry/src/main/ets/view/PlansView.ets');
  const refresh = view.slice(view.indexOf('private async onRefresh()'), view.indexOf('private async onRefresh()') + 1300);
  assert.ok(refresh.includes('secureSharedPlans().refresh()'));
  assert.ok(refresh.includes('this.sharedRefreshTick++'));
  assert.ok(refresh.includes('finally'));
  assert.equal(refresh.includes('.retry()'), false);
  assert.ok(view.includes('showPlanEmpty('));
});
test('clock-only visibility refresh is foreground aware, tears down its timer and updates the pending badge', () => {
  const view = source('entry/src/main/ets/view/PlansView.ets');
  const rebuild = view.slice(view.indexOf('private rebuildEntries()'), view.indexOf('private clearFeedbackTimers()'));
  assert.ok(rebuild.includes('nowEpochMin()'), 'must use project local-epoch-minute clock');
  assert.ok(rebuild.includes('visibleLocalPlans(this.localSource, nowMin)'));
  assert.ok(rebuild.includes('visibleSharedPlans(this.sharedRows, nowMin)'));
  assert.ok(rebuild.includes('onVisiblePendingChange'));
  assert.equal(rebuild.includes('secureSharedPlans()'), false);
  assert.equal(rebuild.includes('recompute'), false);
  assert.ok(view.includes('clearInterval(this.visibilityTimer)'));
  assert.ok(view.includes('this.mounted && this.active && this.rootVisible'));
  assert.ok(view.includes("@Watch('onRootVisibilityChanged')"));
  assert.ok(source('entry/src/main/ets/view/CoTimeView.ets').includes('onVisiblePendingChange:'));
});
test('common week receives confirmed local plan projection and paints separate plan blocks', () => {
  const query = source('feature/src/main/ets/usecase/ScheduleOverviewQueryService.ets');
  const method = query.slice(query.indexOf('static async getWeekLanes('));
  assert.ok(method.includes('ScheduleRepo.listActivePlans()'));
  assert.ok(method.includes('plans: plans'));
  const view = source('entry/src/main/ets/component/WeekScheduleView.ets');
  assert.ok(view.includes('this.dayPlanBlocks(ed)'));
  assert.ok(view.includes("'已安排计划'"));
  assert.ok(view.includes('clipInto(it.start, it.end, s, e)'));
});

// Execute the real page read with isolated persistence and local clock adapters.
async function viewServiceRegression() {
  const session = { pairId: 'pair', actorId: 'a', generation: 'generation' };
  const accepted = transition(early, 'ACCEPT', 'b', 500);
  const withdrawn = transition(early, 'WITHDRAW', 'a', 500);
  const amended = transition(accepted, 'AMEND', 'a', 500, late.pendingContent);
  // Old pending revision on a still-future confirmed plan must not keep a red badge.
  const pastAmendment = { ...amended, planId: 'past-amendment', acceptedContent: late.pendingContent,
    pendingContent: early.pendingContent };
  let rows = [early, accepted, withdrawn, late, amended, pastAmendment];
  let now = 700;
  let current = true;
  const snapshot = JSON.stringify(rows);
  const repo = { async session() { return session; }, async records() { return rows.map(row => JSON.stringify(row)); },
    async isCurrent() { return current; }, async pending() { return [{ requestId: 'unresolved-write', commandJson: JSON.stringify({
      requestId: 'unresolved-write', planId: 'original-plan', action: 'PROPOSE', expectedVersion: 0,
      nextContent: early.pendingContent }) }]; } };
  const module = { exports: {} };
  const js = ts.transpileModule(source('feature/src/main/ets/usecase/SharedPlanViewService.ets'), {
    compilerOptions: { module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2020 } }).outputText;
  vm.runInNewContext(js, { module, exports: module.exports, require: name => {
    if (name === 'domain') return { nowEpochMin: () => now };
    if (name === 'data') return { SharedPlanRepo: repo,
      SecurePairingRepo: { async load() { return JSON.stringify({ phase: 'ACTIVE', flowId: 'generation',
        linkEnvelope: 'envelope', anchor: 'PAIRED|pair' }); } },
      SettingsStore: { getPairState: () => 'PAIRED', getPairId: () => 'pair' } };
    if (name === '../model/SharedPlanFlow') return flow;
    if (name === '../model/SharedPlanPresentation') return policy;
    return {};
  } });
  const service = module.exports.SharedPlanViewService;
  const result = await service.read();
  assert.deepEqual(Array.from(result.rows, row => row.planId), ['past-amendment', 'early', 'late']);
  assert.equal(result.pendingCount, 2, 'ended invitations and old amendments must not count');
  assert.equal(result.unresolved, true, 'hidden cards must not remove recovery for ambiguous writes');
  assert.equal(result.unresolvedRequests[0].nextContent.title, early.pendingContent.title);
  assert.equal(result.unresolvedRequests[0].nextContent.start, early.pendingContent.start,
    'display the original stored request even when no server plan card exists');
  assert.equal(result.linked, true);
  assert.equal(JSON.stringify(rows), snapshot, 'read does not delete or rewrite the cache');
  now = 1260;
  const empty = await service.read();
  assert.equal(empty.rows.length, 0);
  assert.equal(empty.pendingCount, 0);
  assert.equal(empty.unresolved, true);
  assert.equal(empty.unresolvedRequests.length, 1, 'past requests remain visible for explicit recovery/close');
  assert.match(source('entry/src/main/ets/view/PlansView.ets'), /!this\.sharedUnresolved && showPlanEmpty/,
    'unresolved request must not be followed by an empty-state prompt to create another invitation');
  // Hiding ended cards is not permission to silently discard corrupt historical cache.
  rows = [{ ...withdrawn, stateVersion: 0 }];
  await assert.rejects(service.read(), /Invalid plan cache/);
  rows = [late]; current = false;
  const fenced = await service.read();
  assert.equal(fenced.rows.length, 0);
  assert.equal(fenced.pairId, '', 'a changed pairing must not leak cards from the old session');
  console.log('PASS actual shared page read: visibility, badge, recovery, validation and session fence');
  count++;
}

// Execute the real week query with pure engine and isolated storage/settings adapters.
async function weekQueryRegression() {
  const domain = require('./out/domainIndex');
  const base = 20000 * domain.MIN_PER_DAY;
  const rows = [{ id: 'shared:pair:cross', title: '跨天吃饭', status: 'CONFIRMED',
    start: base - 30, end: base + 60 },
    { id: 'shared:pair:later', title: '晚餐', status: 'CONFLICT', start: base + 1200, end: base + 1260 },
    { id: 'outside', title: '下周', status: 'CONFIRMED', start: base + 7 * 1440, end: base + 7 * 1440 + 60 },
    { id: 'touching', title: '上周', status: 'CONFIRMED', start: base - 90, end: base }];
  const params = domain.defaultParams();
  const my = { shiftTypes: [], template: null, overrides: [], courses: [], sectionTimes: [],
    termStartEpochDay: -1, plans: rows.map(p => ({ start: p.start, end: p.end })),
    wakeMin: 420, bedMin: 1350, windDownMin: 20 };
  const module = { exports: {} };
  const query = 'feature/src/main/ets/usecase/ScheduleOverviewQueryService.ets';
  const js = ts.transpileModule(source(query), { compilerOptions: { module: ts.ModuleKind.CommonJS,
    target: ts.ScriptTarget.ES2020 } }).outputText;
  vm.runInNewContext(js, { module, exports: module.exports, require: name => {
    if (name === 'domain') return domain;
    if (name === 'data') return { ScheduleRepo: { async listActivePlans() { return rows; } } };
    if (name === 'commons') return { Logger: { warn() {} } };
    if (name === './ScheduleUseCase') return { SettingsStoreParams: () => params,
      ScheduleUseCase: { dayParamsOf: p => p, async loadMySchedule() { return my; },
        async partnerBusyWithoutNetwork() { return null; },
        async buildPartnerBusy() { throw new Error('presentation must not call the cloud'); } } };
    return {};
  } });
  const lanes = await module.exports.ScheduleOverviewQueryService.getWeekLanes(20000);
  assert.deepEqual(Array.from(lanes.plans, p => p.id), ['shared:pair:cross', 'shared:pair:later']);
  assert.equal(lanes.plans[0].start, base - 30, 'cross-day plan retains original interval for day clipping');
  assert.equal(lanes.plans[1].color, '#D9534F', 'conflict remains distinguishable');
  assert.equal(lanes.partner, null, 'no peer snapshot is not invented');
  assert.ok(lanes.mine.some(p => domain.intersects(p.start, p.end, base + 1200, base + 1260)),
    'display separation does not remove confirmed plans from occupancy calculation');
  console.log('PASS actual week query: confirmed projection, half-open boundaries, cross-day preservation and occupancy');
  count++;
  console.log(`shared-plan-experience: ${count} passed, 0 failed (production policies/query + wiring; NOT device evidence)`);
}
async function regression() { await viewServiceRegression(); await weekQueryRegression(); }
regression().catch(error => { console.error(error.stack); process.exitCode = 1; });
