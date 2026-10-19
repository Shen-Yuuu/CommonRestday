// Execute production loaders and checks with isolated storage; this is not a device or cloud test.
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const ts = require('D:/local/DevEcoStudio/tools/hvigor/hvigor/node_modules/typescript');
const domain = require('./out/domainIndex');
const root = path.resolve(__dirname, '../..');
const cache = new Map();
const records = new Map();
const day = 20000, base = day * 1440;
const params = { ...domain.defaultParams(), wakeMin: 0, bedMin: 1440, windDownMin: 0, horizonDays: 7 };
let overrideRange;
const repo = {
  async getMeta(key) { return records.get(key) || ''; },
  async listShiftTypes() { return []; },
  async getTemplate() { return null; },
  async listOverrides(start, end, owner) { overrideRange = [start, end, owner]; return []; },
  async listCourses() { return []; },
  async getTermStart() { return -1; },
  async getSectionTimes() { return ''; },
  async listActivePlans() { return []; },
  async listSnapshotPlans() { return [{ start: base + 1200, end: base + 1260 }]; }
};
const realModules = new Set([
  'feature/src/main/ets/usecase/ScheduleUseCase',
  'feature/src/main/ets/usecase/WeeklyRosterService',
  'feature/src/main/ets/usecase/SharedPlanLocalCheck',
  'feature/src/main/ets/usecase/ScheduleOverviewQueryService',
  'feature/src/main/ets/model/SerialQueue',
  'feature/src/main/ets/model/SingleFlight',
  'feature/src/main/ets/model/RhythmRules',
  'feature/src/main/ets/model/TodayAgenda'
]);
function load(name) {
  if (cache.has(name)) return cache.get(name);
  const module = { exports: {} };
  cache.set(name, module.exports);
  const source = fs.readFileSync(path.join(root, name + '.ets'), 'utf8');
  const js = ts.transpileModule(source, { compilerOptions: {
    module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2020
  } }).outputText;
  vm.runInNewContext(js, { module, exports: module.exports, require: request => {
    if (request === 'domain') return domain;
    if (request === 'data') return { ScheduleRepo: repo, SettingsStore: { getParams: () => ({ ...params }) } };
    if (request === 'commons') return { ...load('commons/src/main/ets/util/DateLabel'), Logger: { warn() {}, info() {} } };
    if (!request.startsWith('.')) return {};
    const target = path.posix.normalize(path.posix.join(path.posix.dirname(name), request));
    return realModules.has(target) ? load(target) : {};
  } });
  return module.exports;
}
let passed = 0;
async function test(name, work) { await work(); passed++; console.log('PASS ' + name); }
async function run() {
  const { ScheduleUseCase } = load('feature/src/main/ets/usecase/ScheduleUseCase');
  const { SharedPlanLocalCheck } = load('feature/src/main/ets/usecase/SharedPlanLocalCheck');
  const { ScheduleOverviewQueryService } = load('feature/src/main/ets/usecase/ScheduleOverviewQueryService');
  const split = ScheduleUseCase.mkType('assigned-split', '两段工作', '#83A8D5', 540, 720, false, 0, 0, 0);
  split.segments = [{ startMin: 540, endMin: 720, crossDay: false },
    { startMin: 840, endMin: 960, crossDay: false }];
  const weekly = { version: 1, enabled: true, days: [
    { epochDay: day, status: 'WORK', entries: [split] },
    { epochDay: day + 1, status: 'REST', entries: [] },
    { epochDay: day + 2, status: 'REST', entries: [] }
  ], personal: [{ id: 'own-event', title: '私人安排', kind: 'other',
    start: base + 1440 + 1100, end: base + 1440 + 1160 }] };
  records.set('weekly_roster_v1:ME', JSON.stringify(weekly));
  records.set('weekly_roster_v1:PARTNER', JSON.stringify(domain.emptyWeeklyState()));
  let my;
  await test('production schedule loader attaches dated snapshots and personal entries, with adjacent legacy range', async () => {
    my = await ScheduleUseCase.loadMySchedule(day, params, 'ME');
    assert.equal(my.weeklyMode, true);
    assert.equal(my.datedDays[0].entries[0].segments.length, 2);
    assert.equal(my.personalEntries[0].id, 'own-event');
    assert.deepEqual(overrideRange, [day - domain.ROSTER_LOOKBACK_DAYS,
      day + 6 + domain.ROSTER_LOOKAHEAD_DAYS, 'ME']);
    const partner = await ScheduleUseCase.loadMySchedule(day, params, 'PARTNER');
    assert.equal(partner.weeklyMode, false);
    assert.equal(partner.datedDays.length, 0);
    assert.equal(partner.personalEntries.length, 0);
  });
  await test('production plan exclusion preserves the weekly and personal input of the engine', async () => {
    const copied = ScheduleUseCase.withPlans(my, []);
    assert.equal(copied.datedDays, my.datedDays);
    assert.equal(copied.personalEntries, my.personalEntries);
    assert.equal(copied.weeklyMode, true);
    const busy = domain.buildAvailability(copied, params, day, 7).trueBusy;
    assert.ok(busy.some(iv => iv.tag === 'WORK' && iv.start === base + 540));
    assert.ok(busy.some(iv => iv.tag === 'PERSONAL' && iv.start === base + 1440 + 1100));
  });
  await test('actual joint-plan check rejects work and personal events; accepts split gap, rest and unassigned dates', async () => {
    const checker = new SharedPlanLocalCheck({
      nowMin: () => base, newId: () => 'unused', params: () => params,
      async load(start, days) {
        return { my: await ScheduleUseCase.loadMySchedule(start, { ...params, horizonDays: days }, 'ME'),
          plans: [], excludingLocalId: '' };
      }, async current() { return true; }, async recompute() {}
    });
    async function available(offset, end) {
      return checker.canArrange({ title: '吃饭', kind: 'meal', start: base + offset, end: base + end }, '');
    }
    assert.equal(await available(550, 600), false);
    assert.equal(await available(740, 800), true);
    assert.equal(await available(1440 + 1100, 1440 + 1140), false);
    assert.equal(await available(2880 + 600, 2880 + 660), true);
    assert.equal(await available(4320 + 600, 4320 + 660), true);
  });
  await test('actual calendar and today agenda retain split gaps and label personal events separately', async () => {
    const calendar = await ScheduleOverviewQueryService.getWeekSchedule('ME', day);
    const parts = Array.from(calendar.blocks).filter(b => b.name === '两段工作');
    assert.deepEqual(parts.map(b => [b.start, b.end]), [[base + 540, base + 720], [base + 840, base + 960]]);
    assert.equal(calendar.blocks.find(b => b.id === 'own-event').kind, 'PERSONAL');
    const today = await ScheduleOverviewQueryService.getTodayAgenda(day + 1);
    assert.ok(today.some(item => item.kind === 'PERSONAL' && item.name === '私人安排'));
  });
  await test('snapshot input keeps personal occupancy but uses the established plan-export filter', async () => {
    const snapshot = await ScheduleUseCase.loadMySchedule(day, params, 'ME', true);
    assert.equal(snapshot.personalEntries.length, 1);
    assert.equal(snapshot.datedDays.length, 3);
    assert.equal(snapshot.plans.length, 1);
    assert.equal(snapshot.plans[0].start, base + 1200);
  });
  console.log(`weekly-roster-integration: ${passed} passed, 0 failed (production loaders/checks; NOT device/cloud evidence)`);
}
run().catch(error => { console.error(error.stack); process.exitCode = 1; });
