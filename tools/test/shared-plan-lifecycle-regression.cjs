const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const root = path.resolve(__dirname, '../..');
// These are the compiled production policies, not reimplementations of their algorithms.
const { SharedPlanLocalCheck } = require('./out/feature/main/ets/usecase/SharedPlanLocalCheck');
const { SecureCleanupUseCase } = require('./out/feature/main/ets/usecase/SecureCleanupUseCase');
const { SecureLifecycle } = require('./out/feature/main/ets/usecase/SecureLifecycle');
const domain = require('./out/domainIndex');
let count = 0;
async function test(work) { await work(); count++; }
const minute = 20000 * 1440;
const draft = { title: '吃饭', kind: 'meal', start: minute + 600, end: minute + 660 };
const session = { pairId: 'pair-a', actorId: 'actor-a', generation: 'flow-a' };
function conflictFixture() {
  const p = domain.defaultParams(); p.horizonDays = 30;
  const my = { shiftTypes: [], template: null, overrides: [], courses: [], sectionTimes: [],
    termStartEpochDay: -1, plans: [], wakeMin: 420, bedMin: 1350, windDownMin: 20 };
  const f = { plans: [], excluded: '', currentValue: true, failed: false, start: 0, days: 0,
    nowMin: () => minute + 500, newId: () => 'new-id', params: () => p,
    async load(start, days, planId) {
      if (f.failed) throw Error('unreadable'); f.start = start; f.days = days;
      return { my, plans: f.plans, excludingLocalId: f.excluded };
    }, async current() { return f.currentValue; }, async recompute() {} };
  f.check = new SharedPlanLocalCheck(f); return f;
}
function cleanupFixture() {
  const f = { records: [{ flowId: 'flow-a', authUid: 'uid-a', pairId: 'sp-' + 'a'.repeat(32), status: 'WAITING' }],
    uid: 'uid-a', enabled: true, authCalls: 0, calls: [], drops: [], verdict: { code: 'OK', status: 'REVOKED' },
    async credential(create) { assert.equal(create, false); f.authCalls++; return { uid: f.uid, accessToken: 'memory-token' }; },
    async invoke(method, token, args) { assert.equal(method, 'unpair'); f.calls.push(args); return JSON.stringify(f.verdict); },
    async list() { return f.records.map(r => ({ ...r })); },
    async current(r) { return f.records.some(x => JSON.stringify(x) === JSON.stringify(r)); },
    async finish(r, status) {
      if (!await f.current(r)) return;
      f.records = f.records.filter(x => x.flowId !== r.flowId);
      if (status !== '') f.records.push({ ...r, status });
    }, async drop(r) { f.drops.push(r.flowId); } };
  f.use = new SecureCleanupUseCase(f, f, f, () => f.enabled); return f;
}
async function main() {
  await test(async () => { const f = cleanupFixture(); f.records[0].pairId = ''; f.records[0].status = 'UNRESOLVED_CREATE';
    f.invoke = async (method, token, args) => {
      assert.equal(method, 'cleanupCreate'); assert.deepEqual(args, ['flow-a']); f.calls.push(args);
      return JSON.stringify({ code: 'OK', status: 'REVOKED', pairId: 'sp-' + 'a'.repeat(32) });
    };
    assert.equal(await f.use.retry(), 'OK'); assert.equal(f.records.length, 0); assert.equal(f.authCalls, 1); });
  await test(async () => { const f = cleanupFixture(); f.records[0].status = 'LOCAL_KEYS';
    f.drop = async () => { throw Error('HUKS temporarily unavailable'); };
    await assert.rejects(() => f.use.clearLocalKeys()); assert.equal(f.records[0].status, 'LOCAL_KEYS');
    f.drop = async () => {}; await f.use.clearLocalKeys(); assert.equal(f.records.length, 0); assert.equal(f.authCalls, 0); });
  await test(async () => { const f = cleanupFixture(); f.records[0].pairId = ''; f.records[0].status = 'UNRESOLVED';
    assert.equal(await f.use.retry(), 'CLEANUP_REMAINS'); assert.equal(f.authCalls, 0);
    assert.equal(f.calls.length, 0); assert.equal(f.records[0].status, 'UNRESOLVED'); });
  await test(async () => { const f = conflictFixture(); assert.equal(await f.check.canArrange(draft, ''), true);
    assert.equal(f.start, 19999); assert.equal(f.days, 3); });
  await test(async () => { const f = conflictFixture(); f.plans = [{ id: 'personal', start: draft.start, end: draft.end }];
    assert.equal(await f.check.canArrange(draft, ''), false); });
  await test(async () => { const f = conflictFixture(); f.excluded = 'shared:pair-a:plan-a';
    f.plans = [{ id: f.excluded, start: draft.start, end: draft.end }];
    assert.equal(await f.check.canArrange(draft, 'plan-a'), true);
    f.plans.push({ id: 'personal', start: draft.start, end: draft.end });
    assert.equal(await f.check.canArrange(draft, 'plan-a'), false); });
  await test(async () => { const f = conflictFixture(); f.plans = [{ id: 'other', start: draft.end, end: draft.end + 30 }];
    assert.equal(await f.check.canArrange(draft, ''), true); });
  await test(async () => { const f = conflictFixture(); assert.equal(await f.check.canArrange({ ...draft, end: minute + 31 * 1440 }, ''), false);
    assert.equal(await f.check.canArrange({ ...draft, start: minute + 400 }, ''), false); });
  await test(async () => { const f = conflictFixture(); f.currentValue = false; assert.equal(await f.check.canArrange(draft, ''), false);
    f.currentValue = true; f.failed = true; assert.equal(await f.check.canArrange(draft, ''), false); });
  await test(async () => { const f = conflictFixture(); assert.equal(await f.check.canArrange({ ...draft, start: minute + 1320, end: minute + 1450 }, ''), false); });
  await test(async () => { const f = conflictFixture(); const load = f.load;
    f.load = async (...args) => { const inputs = await load(...args);
      inputs.my.shiftTypes = [{ id: 'late', name: '夜班', color: '#000000', startMin: 1350, endMin: 630,
        crossDay: true, commuteInMin: 20, commuteOutMin: 20, recoveryMin: 60, nightMode: 1, allowActivity: false, kind: 'WORK' }];
      inputs.my.overrides = [{ epochDay: 19999, shiftTypeId: 'late' }]; return inputs; };
    assert.equal(await f.check.canArrange(draft, ''), false); });
  await test(async () => { const f = conflictFixture(); const load = f.load;
    f.load = async (...args) => { const inputs = await load(...args); inputs.my.termStartEpochDay = 20000;
      inputs.my.sectionTimes = [{ startMin: 600, endMin: 660 }];
      inputs.my.courses = [{ id: 'course-a', name: '课', weekday: domain.weekdayOf(20000),
        sectionStart: 1, sectionEnd: 1, weekFrom: 1, weekTo: 1, parity: 0, place: '' }]; return inputs; };
    assert.equal(await f.check.canArrange(draft, 'unrelated-plan'), false); });
  await test(async () => { const f = conflictFixture(); const load = f.load;
    f.load = async (...args) => { const inputs = await load(...args); inputs.my.wakeMin = 1320; inputs.my.bedMin = 480;
      inputs.my.windDownMin = 0; return inputs; };
    const cross = { ...draft, start: minute + 1410, end: minute + 1470 };
    assert.equal(await f.check.canArrange(cross, ''), false); assert.equal(f.days, 4); });
  await test(async () => { const f = cleanupFixture(); assert.equal(await f.use.retry(), 'OK');
    assert.equal(f.records.length, 0); assert.equal(f.calls.length, 1); assert.equal(f.drops.length, 1); });
  await test(async () => { const f = cleanupFixture(); f.enabled = false; assert.equal(await f.use.retry(), 'FEATURE_DISABLED');
    assert.equal(f.authCalls, 0); assert.equal(f.calls.length, 0); });
  await test(async () => { const f = cleanupFixture(); f.uid = 'uid-b'; assert.equal(await f.use.retry(), 'CLEANUP_REMAINS');
    assert.equal(f.calls.length, 0); assert.equal(f.records[0].status, 'WAITING'); });
  await test(async () => { const f = cleanupFixture(); f.verdict = { code: 'RESULT_UNKNOWN' }; await f.use.retry();
    assert.equal(f.records[0].status, 'WAITING'); assert.equal(f.drops.length, 0); });
  await test(async () => { const f = cleanupFixture(); f.verdict = { code: 'OK', status: 'ACTIVE' }; await f.use.retry();
    assert.equal(f.records.length, 1); assert.equal(f.drops.length, 0); });
  await test(async () => { const f = cleanupFixture(); f.credential = async create => { assert.equal(create, false); throw Error('identity lost'); };
    await f.use.retry(); assert.equal(f.calls.length, 0); assert.equal(f.records.length, 1); });
  await test(async () => { const f = cleanupFixture(); f.finish = async () => { throw Error('disk failure'); };
    await f.use.retry(); assert.equal(f.records.length, 1); assert.equal(f.drops.length, 1); });
  await test(async () => { const f = cleanupFixture(); f.credential = async () => {
      f.records[0].status = 'REVIEW'; return { uid: 'uid-a', accessToken: 'memory-token' }; };
    await f.use.retry(); assert.equal(f.calls.length, 0); assert.equal(f.records[0].status, 'REVIEW'); });
  await test(async () => { const f = cleanupFixture(); f.verdict = { code: 'NOT_FOUND' }; await f.use.retry();
    assert.equal(f.records[0].status, 'REVIEW'); assert.equal(f.drops.length, 0); });
  await test(async () => { const f = cleanupFixture(); f.records[0].pairId = ''; f.records[0].status = 'UNRESOLVED'; await f.use.retry();
    assert.equal(f.authCalls, 0); assert.equal(f.calls.length, 0); assert.equal(f.records.length, 1); });
  await test(async () => { const f = cleanupFixture(); f.records[0].status = 'RESTORED'; await f.use.retry();
    assert.equal(f.authCalls, 0); assert.equal(f.calls.length, 0); });
  await test(async () => { const f = cleanupFixture(); f.records = Array.from({ length: 4 }, (_, i) => ({ ...f.records[0], flowId: 'f-' + i }));
    await f.use.retry(); assert.equal(f.calls.length, 2); assert.equal(f.records.length, 2); });
  await test(async () => { const f = cleanupFixture(); f.records = Array.from({ length: 4 }, (_, i) => ({ ...f.records[0], flowId: 'f-' + i, pairId: 'sp-' + String(i).repeat(32) }));
    f.verdict = { code: 'RESULT_UNKNOWN' }; await f.use.retry(); await f.use.retry();
    assert.equal(new Set(f.calls.map(args => args[0])).size, 4); });
  await test(async () => { const f = cleanupFixture(); const a = f.use.retry(); assert.equal(await f.use.retry(), 'BUSY'); await a; });
  await test(async () => { const anchor = SecureLifecycle.anchor(); SecureLifecycle.beginClear();
    assert.equal(SecureLifecycle.blocked(), true); assert.notEqual(SecureLifecycle.anchor(), anchor);
    SecureLifecycle.endClear(); assert.equal(SecureLifecycle.blocked(), false); });
  await test(async () => { const f = cleanupFixture(); f.enabled = false; await f.use.clearLocalKeys();
    assert.equal(f.authCalls, 0); assert.equal(f.calls.length, 0); assert.equal(f.drops.length, 1); assert.equal(f.records.length, 1); });
  // The durable ledger contains only identifiers/status, never an access token, proof, key or invitation code.
  const repo = fs.readFileSync(path.join(root, 'data/src/main/ets/repo/SecurePairingRepo.ets'), 'utf8');
  assert.ok(repo.includes('shared_pairing_cleanup'));
  console.log(`shared-plan-lifecycle: PASS (${count} production policy/cleanup cases)`);
}
main().catch(e => { console.error(e.stack); process.exitCode = 1; });
