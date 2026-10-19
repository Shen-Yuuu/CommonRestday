/** Executes the production ability with isolated lifecycle/storage/cloud adapters; NOT device timing. */
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const ts = require('D:/local/DevEcoStudio/tools/hvigor/hvigor/node_modules/typescript');
const root = path.resolve(__dirname, '../..');
function deferred() {
  let resolve, reject;
  const promise = new Promise((done, fail) => { resolve = done; reject = fail; });
  return { promise, resolve, reject };
}
async function drain() { for (let i = 0; i < 100; i++) await Promise.resolve(); }
function fixture() {
  const db = deferred(), settings = deferred(), snapshot = deferred(), calculation = deferred();
  const events = [];
  const state = { lastDay: 20000, today: 20000, paired: true };
  const schedule = {
    async ensureSeeded() { events.push('seed'); },
    async onScheduleChanged(cached) {
      events.push(cached === true ? 'cached-start' : 'network-recompute');
      if (cached !== true) await snapshot.promise;
      else await calculation.promise;
      state.lastDay = state.today;
      events.push('calculated');
    },
    async pullToRefresh() { events.push('snapshot-start'); await snapshot.promise; events.push('snapshot-done'); },
    notifyClockTick() { events.push('clock'); }
  };
  const module = { exports: {} };
  const dependencies = {
    '@kit.AbilityKit': { UIAbility: class {}, ConfigurationConstant: { ColorMode: { COLOR_MODE_NOT_SET: 0 } } },
    '@kit.PerformanceAnalysisKit': { hilog: { info() {}, error() {} } }, '@kit.ArkUI': {},
    data: { Db: { init: () => db.promise }, SettingsStore: { init: () => settings.promise,
      getLastRecomputeDay: () => state.lastDay, getPairState: () => state.paired ? 'PAIRED' : 'SINGLE' },
      PAIRED: 'PAIRED' }, domain: { todayEpochDay: () => state.today },
    commons: { Logger: { error() { events.push('error'); }, warn() { events.push('warning'); } } },
    cloud: { AnonymousIdentity: { attach() {} } },
    feature: { CalendarGateway: { init() {} }, FeatureFlags: { cloudPairing: true }, ScheduleUseCase: schedule,
      PlanUseCase: { async sweepPendingProjections() { events.push('sweep'); } },
      ProfileSettingsService: { async beatIfDue() { events.push('heartbeat'); },
        async retryPendingCloudUnpair() { events.push('unpair-cleanup'); } },
      SecureLifecycle: { installCleanup() {}, installDisconnect() {} },
      secureCloudCleanup: () => ({ async clearLocalKeys() { events.push('keys'); },
        async retry() { events.push('cleanup'); } }), securePairingSetup: () => ({}) },
    '../util/PlanNotifications': { PLAN_PUSH_ACTION: 'PLAN', PlanNotifications: {
      async onForeground() { events.push('plans-start'); } } },
    '../util/NavUtil': { pushPendingRoute() {}, routeFromWantParams() { return ''; } },
    '../navigation/NavRoutes': {}, '../theme/ThemeModeSignal': { publishColorMode() {} },
    '../util/ForegroundSignal': { publishForeground() {} },
    '../util/BottomSafeArea': { BottomSafeArea: { attach() {}, refresh() {}, detach() {} } }
  };
  const source = fs.readFileSync(path.join(root, 'entry/src/main/ets/entryability/EntryAbility.ets'), 'utf8');
  const js = ts.transpileModule(source, { compilerOptions: { module: ts.ModuleKind.CommonJS,
    target: ts.ScriptTarget.ES2020 } }).outputText;
  vm.runInNewContext(js, { module, exports: module.exports, require: name => dependencies[name] || {} });
  const ability = new module.exports.default();
  ability.context = { config: { colorMode: 0 }, getApplicationContext() { return { setColorMode() {} }; } };
  ability.onCreate({ action: '' }, {});
  return { ability, events, state, db, settings, snapshot, calculation };
}
let passed = 0;
async function check(name, work) { await work(); passed++; console.log('PASS ' + name); }
async function main() {
  await check('cold startup reads wait for storage but plan refresh is not held by snapshot or calculation', async () => {
    const f = fixture();
    f.ability.onForeground(); await drain();
    assert.deepEqual(f.events, ['clock']);
    f.db.resolve(); await drain();
    assert.deepEqual(f.events, ['clock', 'seed'], 'settings must be ready too');
    f.settings.resolve(); await drain();
    assert.ok(f.events.includes('cached-start'), 'initial local calculation must be cache-only');
    assert.ok(f.events.includes('snapshot-start'), 'start the fresh snapshot without waiting for local calculation');
    assert.ok(f.events.includes('plans-start'), 'plan refresh cannot wait behind the slow snapshot');
    assert.ok(f.events.includes('sweep'), 'projection cleanup waits only for storage, not cloud');
    assert.equal(f.events.includes('network-recompute'), false, 'cold foreground must not duplicate initial recompute');
    assert.equal(f.events.includes('snapshot-done'), false);
    f.calculation.resolve(); f.snapshot.resolve(); await drain();
  });
  await check('warm same-day foreground does not re-run startup snapshot or initial calculation', async () => {
    const f = fixture(); f.ability.onForeground();
    f.db.resolve(); f.settings.resolve(); f.calculation.resolve(); f.snapshot.resolve(); await drain();
    const before = f.events.length;
    f.ability.onBackground(); f.ability.onForeground(); await drain();
    const warm = f.events.slice(before);
    assert.ok(warm.includes('plans-start'));
    assert.equal(warm.includes('snapshot-start'), false);
    assert.equal(warm.includes('cached-start'), false);
    assert.equal(warm.includes('network-recompute'), false);
  });
  await check('unpaired cold startup computes from local data without a second refresh', async () => {
    const f = fixture(); f.state.paired = false; f.ability.onForeground();
    f.db.resolve(); f.settings.resolve(); f.calculation.resolve(); await drain();
    assert.equal(f.events.filter(event => event === 'cached-start').length, 1);
    assert.equal(f.events.includes('snapshot-start'), false);
    assert.equal(f.events.includes('network-recompute'), false);
  });
  await check('warm day rollover retains the existing network recompute behavior', async () => {
    const f = fixture(); f.ability.onForeground();
    f.db.resolve(); f.settings.resolve(); f.calculation.resolve(); f.snapshot.resolve(); await drain();
    f.state.today++;
    const before = f.events.length; f.ability.onForeground(); await drain();
    assert.equal(f.events.slice(before).filter(event => event === 'network-recompute').length, 1);
  });
  await check('storage failure prevents cloud and cleanup while catching dependent rejections', async () => {
    const f = fixture(); f.ability.onForeground();
    f.settings.resolve(); f.db.reject(new Error('storage failed')); await drain();
    assert.equal(f.events.includes('plans-start'), false);
    assert.equal(f.events.includes('snapshot-start'), false);
    assert.equal(f.events.includes('sweep'), false);
    assert.equal(f.events.includes('heartbeat'), false);
    assert.equal(f.events.includes('cleanup'), false);
    assert.ok(f.events.includes('error'));
  });
  console.log(`startup-sync: ${passed} passed, 0 failed (production ability with isolated adapters; NOT device latency)`);
}
main().catch(error => { console.error(error.stack); process.exitCode = 1; });
