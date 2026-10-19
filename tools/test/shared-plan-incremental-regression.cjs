/** Production ArkTS gateway/use case, deterministic in-memory ports; no app/device/cloud access. */
const assert = require('node:assert/strict');
const fs = require('node:fs'); const path = require('node:path'); const vm = require('node:vm');
const ts = require('D:/local/DevEcoStudio/tools/hvigor/hvigor/node_modules/typescript');
const root = path.resolve(__dirname, '../..'); const modules = new Map();
function load(file) {
  if (modules.has(file)) return modules.get(file).exports;
  const module = { exports: {} }; modules.set(file, module);
  const js = ts.transpileModule(fs.readFileSync(path.join(root, file), 'utf8'), {
    compilerOptions: { module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2021 }
  }).outputText;
  vm.runInNewContext(js, { module, exports: module.exports, Promise, require: name => {
    assert.ok(name.startsWith('.')); return load(path.relative(root, path.resolve(root, path.dirname(file), name + '.ets')));
  } }); return module.exports;
}
const { SecureSharedPlanGateway } = load('feature/src/main/ets/usecase/SecureSharedPlanGateway.ets');
const { SharedPlanUseCase } = load('feature/src/main/ets/usecase/SharedPlanUseCase.ets');
const actor = 'm-' + 'a'.repeat(64), peer = 'm-' + 'b'.repeat(64);
const ctx = { pairId: 'pair-a', actorId: actor, peerId: peer, generation: 'flow-a', protocolVersion: 1, projectionVersion: 1 };
const content = { title: '吃饭', kind: 'meal', start: 600, end: 660 };
const row = (version = 2) => ({ pairId: ctx.pairId, planId: 'plan-a', proposerUid: actor, recipientUid: peer,
  state: 'ACCEPTED', stateVersion: version, contentRevision: 1, acceptedRevision: 1,
  acceptedContent: content, pendingContent: null, pendingAuthorUid: '' });
function methodAdapter(file, signature, dependencies) {
  const source = fs.readFileSync(path.join(root, file), 'utf8'); const start = source.indexOf(signature);
  assert.ok(start >= 0); const brace = source.indexOf('{', start); let depth = 1, end = brace + 1;
  while (depth && end < source.length) { if (source[end] === '{') depth++; else if (source[end] === '}') depth--; end++; }
  const module = { exports: {} };
  const js = ts.transpileModule('class Adapter { ' + source.slice(start, end) + ' } module.exports = Adapter;', {
    compilerOptions: { target: ts.ScriptTarget.ES2021, module: ts.ModuleKind.CommonJS }
  }).outputText;
  vm.runInNewContext(js, { module, Promise, ...dependencies }); return new module.exports();
}
function fixture() {
  const f = { session: { ...ctx }, calls: [], opens: 0, proofs: 0, cursor: 0, writes: [], cache: [],
    failApply: false, failCursor: false, malformed: false, uid: 'auth-a', response: null, recomputes: 0, changed: 0, votes: [],
    binding: { code: 'OK', pairId: ctx.pairId, status: 'ACTIVE', myUid: actor, peerUid: peer,
      peerPublicKey: 'pinned-public', peerLink: 'pinned-link', protocolVersion: 1, projectionVersion: 1, sharedPlanReady: true, syncVersion: 2 } };
  const identity = { async credential(create) { assert.equal(create, false); return { uid: f.uid, accessToken: 'memory-only' }; },
    async currentUid() { return f.uid; } };
  const cloud = { async invoke(method, token, args) {
    f.calls.push(method); assert.equal(token, 'memory-only');
    if (method === 'capabilities') return JSON.stringify(f.binding);
    if (f.response) return JSON.stringify(await f.response(method, args));
    if (method === 'acknowledge') return JSON.stringify({ code: 'OK' });
    return JSON.stringify({ ...f.binding, cursor: f.malformed ? -1 : 1, more: false,
      plans: args[1] === 1 ? [] : [{ pairId: ctx.pairId, planId: 'plan-a', proposerUid: actor, recipientUid: peer,
        state: 'ACCEPTED', stateVersion: 2, contentRevision: 1, acceptedRevision: 1, protocolVersion: 1,
        acceptedEnvelope: 'encrypted', pendingEnvelope: '', pendingAuthorUid: '' }] });
  } };
  const cipher = { async available() { return true; }, async verifyPartner(key, link) {
    f.proofs++; return key === 'pinned-public' && link === 'pinned-link'; },
    async open() { f.opens++; return JSON.stringify(content); } };
  const transport = { async session() { return f.session; }, async current(value) {
    return f.session !== null && value.pairId === f.session.pairId && value.actorId === f.session.actorId && value.generation === f.session.generation;
  } };
  const storage = { current: transport.current, async list() { return f.cache; }, async apply(context, rows) {
    f.writes.push('apply'); if (f.failApply) return false; f.cache = f.cache.concat(rows); return true;
  }, async cursor() { return f.cursor; }, async saveCursor(context, cursor) {
    f.writes.push('cursor'); if (f.failCursor) throw Error('disk failure'); f.cursor = cursor; return true;
  }, async voted() { return f.votes; }, async markVotes(context, candidates) {
    f.votes.push(...candidates.map(c => c.planId + ':' + c.stateVersion));
  }, async pending() { return []; }, async enqueue() {}, async finish() {} };
  const local = { nowMin: () => 500, newId: () => 'request-a', async canArrange() { return true; },
    async recompute() { f.recomputes++; }, changed() { f.changed++; } };
  f.gateway = new SecureSharedPlanGateway(identity, cloud, cipher, transport, () => true);
  f.use = new SharedPlanUseCase(f.gateway, storage, local); f.storage = storage; f.local = local;
  return f;
}
let passed = 0;
async function test(name, work) { await work(); passed++; console.log('PASS ' + name); }
async function main() {
  await test('verified changes persist before cursor; unchanged sync uses one RPC and no repeated decryption', async () => {
    const f = fixture(); assert.equal(await f.use.refresh(), 'OK'); assert.deepEqual(f.writes, ['apply', 'cursor']);
    assert.deepEqual(f.calls, ['capabilities', 'readChanges']); assert.equal(f.opens, 1); assert.equal(f.recomputes, 1);
    assert.equal(await f.use.refresh(), 'OK'); assert.deepEqual(f.calls.slice(2), ['readChanges']);
    assert.equal(f.opens, 1); assert.equal(f.recomputes, 1); assert.equal(f.proofs, 3);
    assert.deepEqual(f.writes, ['apply', 'cursor'], 'unchanged delta performs no empty apply/cursor writes');
  });
  await test('failed apply and malformed reply never advance cursor or erase previous state', async () => {
    const f = fixture(); f.failApply = true; assert.equal(await f.use.refresh(), 'SESSION_CHANGED'); assert.equal(f.cursor, 0);
    assert.deepEqual(f.writes, ['apply']); f.failApply = false; f.malformed = true;
    assert.equal(await f.use.refresh(), 'BAD_RECORD'); assert.equal(f.cursor, 0); assert.equal(f.opens, 1);
  });
  await test('cursor write failure permits safe page replay rather than skipping it', async () => {
    const f = fixture(); f.failCursor = true; await assert.rejects(() => f.use.refresh()); assert.equal(f.cursor, 0);
    f.failCursor = false; assert.equal(await f.use.refresh(), 'OK'); assert.equal(f.cursor, 1);
    assert.equal(f.cache[0].stateVersion, 2);
  });
  await test('changed generation during read rejects late response before decrypt or cursor save', async () => {
    const f = fixture(); f.response = async () => { f.session = { ...ctx, generation: 'different' };
      return { ...f.binding, cursor: 1, more: false, plans: [] }; };
    assert.notEqual(await f.use.refresh(), 'OK'); assert.equal(f.opens, 0); assert.equal(f.cursor, 0); assert.equal(f.writes.length, 0);
  });
  await test('failed peer proof, forged binding and regressing cursor fail closed without legacy fallback', async () => {
    for (const patch of [{ peerPublicKey: 'changed' }, { myUid: peer }, { status: 'REVOKED' }]) {
      const f = fixture(); await f.use.refresh(); f.binding = { ...f.binding, ...patch };
      assert.notEqual(await f.use.refresh(), 'OK'); assert.equal(f.cursor, 1); assert.ok(!f.calls.includes('read'));
    }
  });
  await test('old server keeps legacy read; explicit disabled v2 never implies cached authorization for writes', async () => {
    const f = fixture(); f.binding.syncVersion = 1;
    assert.equal(await f.use.refresh(), 'OK'); assert.deepEqual(f.calls, ['capabilities', 'read']); assert.equal(f.cursor, 0);
    const g = fixture(); await g.use.refresh(); g.binding.syncVersion = 1;
    g.response = async method => method === 'readChanges' ? { code: 'FEATURE_DISABLED' } : { code: 'OK', plans: [] };
    assert.equal(await g.use.refresh(), 'OK'); assert.ok(g.calls.includes('read'));
  });
  await test('archive eligibility requires ended or terminal version, never a pending amendment; votes do not repeat', async () => {
    const f = fixture(); f.local.nowMin = () => 700;
    assert.equal(await f.use.refresh(), 'OK'); assert.equal(f.votes.length, 1);
    assert.equal(await f.use.refresh(), 'OK'); assert.equal(f.calls.filter(c => c === 'acknowledge').length, 1);
    const g = fixture(); g.local.nowMin = () => 700;
    g.storage.list = async () => [{ ...row(), contentRevision: 2, pendingAuthorUid: actor,
      pendingContent: { ...content, start: 800, end: 900 } }];
    await g.use.refresh(); assert.equal(g.calls.filter(c => c === 'acknowledge').length, 0);
  });
  await test('tab visibility gates reads, preserves state and cancels queued landings without changing layout', () => {
    for (const name of ['HomeView', 'CoTimeView', 'MeView', 'PlansView']) {
      const text = fs.readFileSync(path.join(root, 'entry/src/main/ets/view/' + name + '.ets'), 'utf8');
      assert.ok(text.includes("@Prop @Watch('onActiveChanged') active")); assert.ok(text.includes('this.landing.invalidate()'));
    }
    const nav = fs.readFileSync(path.join(root, 'entry/src/main/ets/navigation/AppNavigator.ets'), 'utf8');
    assert.equal((nav.match(/active: this.activeTab === NavRoutes/g) || []).length, 3);
    assert.equal((nav.match(/&& this.dockVisible && this.rootVisible/g) || []).length, 3);
  });
  await test('actual plan reload failure preserves previously rendered cards and reports failure instead of empty', async () => {
    const { LatestLanding } = load('entry/src/main/ets/util/LatestLanding.ets');
    const f = methodAdapter('entry/src/main/ets/view/PlansView.ets', 'reload(): void', {
      CommonTimeQueryService: { async getPlanCards() { throw Error('temporary database failure'); } }
    });
    let work; const cached = [{ id: 'cached-plan' }]; Object.assign(f, {
      mounted: true, active: true, landing: new LatestLanding(), localSource: cached, entries: cached,
      reads: { run(action) { work = action(); return work; } }, loading: false, failed: false
    });
    f.reload(); await work; assert.equal(f.localSource, cached); assert.equal(f.entries, cached);
    assert.equal(f.failed, true); assert.equal(f.loading, false);
  });
  await test('actual same-week refresh retains grid while reading and retains old blocks on failure', async () => {
    const { LatestLanding } = load('entry/src/main/ets/util/LatestLanding.ets'); let reject;
    const held = new Promise((resolve, fail) => { reject = fail; });
    const f = methodAdapter('entry/src/main/ets/component/WeekScheduleView.ets', 'async loadScheduleWeek(): Promise<void>', {
      ScheduleOverviewQueryService: { getWeekSchedule: () => held }, SettingsStore: { getPartnerDisplayName: () => 'TA' }
    });
    const cached = [{ name: '白班' }]; Object.assign(f, { mode: 'schedule', owner: 'ME', weekStart: 20000,
      displayedKey: 'schedule:ME:20000', landing: new LatestLanding(), weekItems: cached, loading: false,
      fitAxis() {}, finishWeekMotion() {} });
    const work = f.loadScheduleWeek(); assert.equal(f.loading, false); assert.equal(f.reading, true);
    reject(Error('temporary database failure')); await work;
    assert.equal(f.weekItems, cached); assert.equal(f.failed, true); assert.equal(f.reading, false);
  });
  console.log(`shared-plan-incremental: ${passed} passed, 0 failed (NOT device/cloud latency evidence)`);
}
main().catch(error => { console.error(error); process.exitCode = 1; });
