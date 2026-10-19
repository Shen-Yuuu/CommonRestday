// Isolated production control-flow adapters, not device/AGC timing evidence.
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const ts = require('D:/local/DevEcoStudio/tools/hvigor/hvigor/node_modules/typescript');
const root = path.resolve(__dirname, '../..');
const source = file => fs.readFileSync(path.join(root, file), 'utf8');
const modules = new Map();
function load(file) {
  if (modules.has(file)) return modules.get(file).exports;
  const module = { exports: {} }; modules.set(file, module);
  const js = ts.transpileModule(source(file), { compilerOptions: {
    module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2021
  } }).outputText;
  vm.runInNewContext(js, { module, exports: module.exports, Promise, require: name => {
    if (!name.startsWith('.')) throw new Error('Unexpected import: ' + name);
    return load(path.relative(root, path.resolve(root, path.dirname(file), name + '.ets')));
  } });
  return module.exports;
}
function deferred() { let resolve; const promise = new Promise(r => { resolve = r; }); return { promise, resolve }; }
function scheduleAdapter(cloud = {}) {
  const state = { pairId: 'legacy-pair-a', pairState: 'PAIRED', writes: 0, version: 0 };
  const settings = { getPairId: () => state.pairId, getPairState: () => state.pairState,
    getCloudSyncState: () => 'SYNCED|0|', getPartnerSnapVer: () => state.version,
    async getOrCreateUid() { return 'legacy-a'; }, getPartnerSnapCache: () => '',
    async setPartnerSnapCache() { state.writes++; }, async setPartnerSnapVer(v) { state.version = v; state.writes++; } };
  const module = { exports: {} };
  const dependencies = { data: { SettingsStore: settings, PAIRED: 'PAIRED' }, cloud,
    domain: { todayEpochDay: () => 20000 }, commons: { Logger: { info() {}, warn() {} } },
    '../model/SingleFlight': load('feature/src/main/ets/model/SingleFlight.ets'),
    '../model/SerialQueue': load('feature/src/main/ets/model/SerialQueue.ets'),
    '../model/CloudSyncRules': load('feature/src/main/ets/model/CloudSyncRules.ets'),
    '../config/FeatureFlags': { FeatureFlags: { cloudPairing: true } } };
  const js = ts.transpileModule(source('feature/src/main/ets/usecase/ScheduleUseCase.ets'), {
    compilerOptions: { module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2021 }
  }).outputText;
  vm.runInNewContext(js, { module, exports: module.exports, require: name => dependencies[name] || {} });
  return { state, ScheduleUseCase: module.exports.ScheduleUseCase };
}
let passed = 0;
async function check(name, work) { await work(); passed++; console.log('PASS ' + name); }
async function main() {
  await check('all six route backgrounds and navigation destinations extend system rendering, not content layout', () => {
    for (const page of ['Index', 'CycleEditor', 'PaintMonth', 'CourseImport', 'ScheduleEditor', 'OcrCourse']) {
      const text = source(`entry/src/main/ets/pages/${page}.ets`);
      assert.match(text, /expandSafeArea\(\[SafeAreaType.SYSTEM\],\s*\[SafeAreaEdge.TOP, SafeAreaEdge.BOTTOM\]\)/, page);
      assert.doesNotMatch(text, /ignoreLayoutSafeArea/, page);
    }
    const nav = source('entry/src/main/ets/navigation/AppNavigator.ets');
    assert.equal((nav.match(/expandSafeArea\(/g) || []).length, 2);
    assert.equal((nav.match(/linearGradient\(DesignTokens.pageGradient\(\)\)/g) || []).length, 2);
    const header = source('entry/src/main/ets/component/FadingHeader.ets');
    assert.match(header, /backgroundColor\(DesignTokens.pageGradTop\)\s*\.expandSafeArea\(\[SafeAreaType.SYSTEM\], \[SafeAreaEdge.TOP\]\)/);
  });
  await check('presentation queries and local saves never pull partner data', () => {
    const use = source('feature/src/main/ets/usecase/ScheduleUseCase.ets');
    assert.match(use.slice(use.indexOf('static async getDayView('), use.indexOf('static async unavailableForDraftOver(')),
      /partnerBusyWithoutNetwork\(epochDay, dayParams\)/);
    const week = source('feature/src/main/ets/usecase/ScheduleOverviewQueryService.ets').split('static async getWeekLanes(')[1];
    assert.match(week, /partnerBusyWithoutNetwork\(weekStart, params\)/);
    for (const file of ['ScheduleCommandService', 'PlanUseCase']) {
      assert.doesNotMatch(source(`feature/src/main/ets/usecase/${file}.ets`), /onScheduleChanged\(\)/);
    }
    const settings = source('feature/src/main/ets/usecase/ProfileSettingsService.ets');
    assert.match(settings.split('// ---------- 伴侣档案')[0], /onScheduleChanged\(true\)/);
    assert.match(use, /static async pullToRefreshLocked[\s\S]*?recompute\(todayEpochDay\(\)\)/);
  });
  const { SingleFlight } = load('feature/src/main/ets/model/SingleFlight.ets');
  await check('overlapping reads share work; settled success is never a cached answer', async () => {
    const gate = new SingleFlight(), held = deferred(); let count = 0;
    const first = gate.run(() => { count++; return held.promise; });
    const second = gate.run(() => { count++; return Promise.resolve('wrong'); });
    assert.equal(first, second); assert.equal(count, 1);
    held.resolve('one'); assert.equal(await second, 'one');
    assert.equal(await gate.run(() => { count++; return Promise.resolve('two'); }), 'two');
    assert.equal(count, 2);
  });
  await check('invalidation separates reads across a write; older completion cannot clear a newer flight', async () => {
    const gate = new SingleFlight(), old = deferred(), next = deferred();
    const a = gate.run(() => old.promise); gate.invalidate();
    const b = gate.run(() => next.promise); assert.notEqual(a, b);
    old.resolve('old'); await a;
    assert.equal(gate.run(() => Promise.resolve('wrong')), b);
    next.resolve('new'); assert.equal(await b, 'new');
  });
  await check('rejected reads release the gate for explicit retry', async () => {
    const gate = new SingleFlight(); await assert.rejects(gate.run(() => Promise.reject(new Error('offline'))));
    assert.equal(await gate.run(() => Promise.resolve('retry')), 'retry');
  });
  await check('slow cloud refresh never owns the recomputation lock; later calculation reads latest local facts', async () => {
    const { ScheduleUseCase: use } = scheduleAdapter(), network = deferred(); let version = 1; const seen = [];
    use.pullPartnerSnapshot = () => network.promise;
    use.recomputeLocked = async (day, cached) => {
      if (cached === false) await network.promise;
      seen.push(version); return version;
    };
    const remote = use.recompute(20000);
    const local = use.recompute(20000, true);
    for (let i = 0; i < 20; i++) await Promise.resolve();
    assert.deepEqual(seen, [1], 'local work queued behind a cloud wait'); await local;
    version = 2; network.resolve(null); await remote;
    assert.deepEqual(seen, [1, 2], 'cloud completion must re-read after the newer write, not restore captured input');
  });
  await check('a delayed snapshot response after unpair/re-pair cannot write into the new cache or cursor', async () => {
    const held = deferred(); let started = false;
    const { state, ScheduleUseCase: use } = scheduleAdapter({
      PairKeyStore: { async hasPairKey() { return true; } },
      AgcSnapshotSync: class { async getSnapshot() { started = true; return held.promise; } },
      async partnerIntervalsFromSnapshot() { return []; }
    });
    const read = use.pullPartnerSnapshot(); while (!started) await Promise.resolve();
    state.pairId = 'legacy-pair-b'; held.resolve({ version: 9, shareLevel: 3 });
    assert.equal(await read, null); assert.equal(state.writes, 0); assert.equal(state.version, 0);
  });
  const { LatestReadQueue } = load('entry/src/main/ets/util/LatestReadQueue.ets');
  await check('page invalidations collapse in one turn and retain the latest follow-up during a read', async () => {
    const reads = new LatestReadQueue(), held = deferred(); const seen = [];
    for (let i = 0; i < 5; i++) reads.run(async () => { seen.push(i); await held.promise; });
    await Promise.resolve(); assert.deepEqual(seen, [4]);
    let result;
    for (let i = 5; i < 10; i++) result = reads.run(async () => { seen.push(i); });
    held.resolve(); await result; assert.deepEqual(seen, [4, 9]);
    await reads.run(async () => { seen.push(10); }); assert.deepEqual(seen, [4, 9, 10]);
  });
  await check('unmount cancels queued page reads, without cancelling the active storage operation', async () => {
    const reads = new LatestReadQueue(), held = deferred(); let count = 0;
    const active = reads.run(async () => { count++; await held.promise; });
    await Promise.resolve(); reads.run(async () => { count++; }); reads.cancel();
    held.resolve(); await active; assert.equal(count, 1);
  });
  const { SharedPlanUseCase } = load('feature/src/main/ets/usecase/SharedPlanUseCase.ets');
  const { initialSharedPlan, evaluateSharedPlanAction, SharedPlanAction } = load('feature/src/main/ets/model/SharedPlanFlow.ets');
  const ctx = { pairId: 'pair-a', actorId: 'member-a', peerId: 'member-b', generation: 'gen-a', protocolVersion: 1, projectionVersion: 1 };
  const content = { title: '午餐', kind: 'meal', start: 600, end: 660 };
  const pending = initialSharedPlan(ctx.pairId, 'plan-a', ctx.actorId, ctx.peerId, content);
  const accepted = evaluateSharedPlanAction(pending, { action: SharedPlanAction.ACCEPT,
    actorUid: ctx.peerId, expectedVersion: 1, nextContent: null, nowMin: 500 }).record;
  function fixture() {
    const state = { rows: [], readRows: [pending], recomputes: 0, changes: 0, reads: 0, barrier: null, failRecompute: false };
    const gateway = { async context() { return ctx; }, async current() { return true; },
      async read() { state.reads++; const rows = state.readRows; if (state.barrier) await state.barrier; return { code: 'OK', records: rows }; },
      async send(c, cmd) { return { code: 'OK', records: [cmd.action === 'CANCEL' ? cancelled : pending] }; } };
    const storage = { async current() { return true; }, async list() { return state.rows; },
      async apply(c, rows) { for (const row of rows) state.rows = state.rows.filter(old => old.planId !== row.planId).concat(row); return true; },
      async pending() { return []; }, async enqueue() {}, async finish() {} };
    const local = { nowMin: () => 500, newId: () => 'request-a', async canArrange() { return true; },
      async recompute() { state.recomputes++; if (state.failRecompute) throw new Error('engine'); }, changed() { state.changes++; } };
    return { state, use: new SharedPlanUseCase(gateway, storage, local) };
  }
  const cancelled = evaluateSharedPlanAction(accepted, { action: SharedPlanAction.CANCEL,
    actorUid: ctx.actorId, expectedVersion: 2, nextContent: null, nowMin: 500 }).record;
  await check('pending records refresh UI without an availability recomputation', async () => {
    const { state, use } = fixture(); assert.equal(await use.refresh(), 'OK');
    assert.equal(state.recomputes, 0); assert.equal(state.changes, 1);
    await use.refresh(); assert.equal(state.changes, 1); assert.equal(state.recomputes, 0);
  });
  await check('acceptance and cancellation recompute occupied intervals exactly once each', async () => {
    const { state, use } = fixture(); state.rows = [pending]; state.readRows = [accepted];
    await use.refresh(); assert.equal(state.recomputes, 1);
    state.readRows = [cancelled]; await use.refresh(); assert.equal(state.recomputes, 2);
    await use.refresh(); assert.equal(state.recomputes, 2);
  });
  await check('pending reschedule keeps the original confirmed time without unnecessary recomputation', async () => {
    const { state, use } = fixture(); state.rows = [accepted];
    state.readRows = [evaluateSharedPlanAction(accepted, { action: SharedPlanAction.AMEND,
      actorUid: ctx.actorId, expectedVersion: 2, nextContent: { ...content, start: 900, end: 960 }, nowMin: 500 }).record];
    await use.refresh(); assert.equal(state.recomputes, 0); assert.equal(state.changes, 1);
  });
  await check('saved occupancy with failed recomputation heals on explicit refresh even at an equal version', async () => {
    const { state, use } = fixture(); state.rows = [pending]; state.readRows = [accepted]; state.failRecompute = true;
    assert.equal(await use.refresh(), 'SAVED_RECOMPUTE_PENDING'); assert.equal(state.rows[0].stateVersion, 2);
    state.failRecompute = false; assert.equal(await use.refresh(), 'OK'); assert.equal(state.recomputes, 2);
  });
  await check('foreground and pull refresh share a read; a read following a queued mutation is separate', async () => {
    const { state, use } = fixture(), held = deferred(); state.barrier = held.promise;
    const first = use.refresh(), joined = use.refresh(); assert.equal(first, joined);
    const mutation = use.respond('missing', SharedPlanAction.CANCEL);
    const after = use.refresh(); assert.notEqual(after, first);
    held.resolve(); await first; await mutation; await after; assert.equal(state.reads, 2);
  });
  console.log(`refresh-performance: ${passed} passed, 0 failed (isolated adapters; NOT device/AGC latency)`);
}
main().catch(error => { console.error(error.stack); process.exitCode = 1; });
