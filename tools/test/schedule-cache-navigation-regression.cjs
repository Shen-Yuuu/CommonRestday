// Production code with isolated SQLite/controllers; never opens a device database or runs a UI.
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const { DatabaseSync } = require('node:sqlite');
const ts = require('D:/local/DevEcoStudio/tools/hvigor/hvigor/node_modules/typescript');
const domain = require('./out/domainIndex');
const root = path.resolve(__dirname, '../..');
const source = p => fs.readFileSync(path.join(root, p), 'utf8');
const db = new DatabaseSync(':memory:');
db.exec(`CREATE TABLE sync_meta(k TEXT PRIMARY KEY,v TEXT);
 CREATE TABLE computed_window(start_min INTEGER,end_min INTEGER,duration_min INTEGER,
 tags TEXT,computed_at INTEGER,channel TEXT,PRIMARY KEY(start_min,end_min));`);
let failure = '', opened = 0, closed = 0;
const store = {
  beginTransaction() { db.exec('BEGIN'); }, commit() { db.exec('COMMIT'); }, rollBack() { db.exec('ROLLBACK'); },
  async executeSql(sql, args = []) {
    if (failure && (sql.includes(failure) || args[0] === failure)) throw new Error('injected cache write failure');
    db.prepare(sql).run(...args);
  },
  async querySql(sql, args = []) {
    const stmt = db.prepare(sql), rows = stmt.all(...args), names = stmt.columns().map(c => c.name);
    let index = -1; opened++;
    return { goToNextRow: () => ++index < rows.length, getColumnIndex: n => names.indexOf(n),
      isColumnNull: i => rows[index][names[i]] == null,
      getLong: i => Number(rows[index][names[i]]), getString: i => String(rows[index][names[i]]), close() { closed++; } };
  }
};
function load(file, dependencies) {
  const module = { exports: {} };
  const js = ts.transpileModule(source(file), { compilerOptions: {
    module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2020
  } }).outputText;
  vm.runInNewContext(js, { module, exports: module.exports, require: n => dependencies[n] || {} });
  return module.exports;
}
const { ScheduleRepo } = load('data/src/main/ets/repo/ScheduleRepo.ets', {
  domain, '../db/Db': { Db: { get: () => store } }, '@kit.ArkData': { relationalStore: {} },
  commons: { Logger: { warn() {} } }
});
const { CommonTimeQueryService } = load('feature/src/main/ets/usecase/CommonTimeQueryService.ets', { domain });
let passed = 0, failed = 0;
async function test(name, work) {
  try { await work(); passed++; console.log('PASS ' + name); }
  catch (e) { failed++; console.error('FAIL ' + name + ': ' + e.message); }
}
const time = Date.UTC(2026, 9, 10, 3);
const row = { start: 100, end: 200, durationMin: 100, tags: [], channel: 'REGULAR' };
async function run() {
  await test('pre-policy-upgrade cache requires recalculation without deleting stored rows', async () => {
    assert.equal(await ScheduleRepo.windowCacheComputedAt(), 0);
    db.prepare('INSERT INTO computed_window VALUES(?,?,?,?,?,?)').run(10, 20, 10, '', time - 1000, 'REGULAR');
    db.prepare('INSERT INTO sync_meta VALUES(?,?)').run('window_cache_computed_at_v1', String(time - 1000));
    assert.equal(await ScheduleRepo.windowCacheComputedAt(), 0);
    assert.equal(db.prepare('SELECT COUNT(*) AS n FROM computed_window').get().n, 1);
  });
  await test('successful zero-window calculation has a fresh timestamp, not January 1 or stale state', async () => {
    await ScheduleRepo.replaceWindows([row], time);
    await ScheduleRepo.replaceWindows([], time + 1);
    assert.equal(db.prepare('SELECT COUNT(*) AS n FROM computed_window').get().n, 0);
    const actual = await ScheduleRepo.windowCacheComputedAt();
    assert.equal(actual, time + 1);
    assert.equal(CommonTimeQueryService.isStale(actual, domain.nowEpochMin(time + 1)), false);
    assert.equal(CommonTimeQueryService.isStale(actual, domain.nowEpochMin(time + 86400000)), true);
  });
  await test('timestamp-write failure rolls back the entire cache replacement', async () => {
    await ScheduleRepo.replaceWindows([row], time + 2);
    failure = 'INSERT OR REPLACE INTO sync_meta';
    try { await assert.rejects(ScheduleRepo.replaceWindows([], time + 3), /injected/); }
    finally { failure = ''; }
    assert.equal(db.prepare('SELECT COUNT(*) AS n FROM computed_window').get().n, 1);
    assert.equal(await ScheduleRepo.windowCacheComputedAt(), time + 2);
  });
  await test('policy-write failure rolls back new rows and completion time as one batch', async () => {
    failure = 'window_cache_policy_v1';
    try { await assert.rejects(ScheduleRepo.replaceWindows([], time + 4), /injected/); }
    finally { failure = ''; }
    assert.equal(db.prepare('SELECT COUNT(*) AS n FROM computed_window').get().n, 1);
    assert.equal(await ScheduleRepo.windowCacheComputedAt(), time + 2);
  });
  await test('explicitly cleared cache plus metadata returns never-computed again and closes cursors', async () => {
    db.exec('DELETE FROM computed_window; DELETE FROM sync_meta');
    assert.equal(await ScheduleRepo.windowCacheComputedAt(), 0);
    assert.equal(opened, closed);
  });
  const helperFile = 'entry/src/main/ets/util/ScrollOffset.ets';
  await test('safe scroll reader handles detached, null, nonfinite and throwing controllers without losing valid position', async () => {
    const { readScrollY } = load(helperFile, {});
    for (const value of [undefined, null, { yOffset: NaN }]) {
      assert.equal(readScrollY({ offset: () => value }, 48), 48);
    }
    assert.equal(readScrollY({ offset() { throw new Error('unbound'); } }, 48), 48);
    assert.equal(readScrollY({ offset: () => undefined }, NaN), 0);
    assert.equal(readScrollY({ offset: () => ({ yOffset: -2 }) }, 48), 0);
    assert.equal(readScrollY({ offset: () => ({ yOffset: 121 }) }, 48), 121);
  });
  await test('production tab-commit method switches from empty list to week and back without dereferencing undefined', async () => {
    const { readScrollY } = load(helperFile, {});
    const view = source('entry/src/main/ets/view/CoTimeView.ets');
    const method = view.slice(view.indexOf('  private commitView('), view.indexOf('  private selectedWindow('));
    const js = ts.transpileModule(`export class CommitHarness {${method}}`, {
      compilerOptions: { module: ts.ModuleKind.CommonJS }
    }).outputText;
    const exports = {};
    new Function('exports', 'readScrollY', 'VIEW_LIST', 'VIEW_WEEK', js)(exports, readScrollY, 'list', 'week');
    const state = new exports.CommitHarness();
    Object.assign(state, { viewMode: 'list', listScrollY: 28, weekScrollY: 43,
      windowScroller: { offset: () => undefined }, weekScroller: { offset: () => undefined } });
    state.commitView(1);
    assert.equal(state.viewMode, 'week'); assert.equal(state.listScrollY, 28);
    state.commitView(0);
    assert.equal(state.viewMode, 'list'); assert.equal(state.weekScrollY, 43);
    assert.doesNotMatch(view, /currentOffset\(\)\.yOffset/);
  });
  console.log(`schedule-cache-navigation: ${passed} passed, ${failed} failed (isolated storage/production control methods; NOT rendered-device evidence)`);
  db.close(); if (failed) process.exitCode = 1;
}
run().catch(e => { console.error(e.stack); db.close(); process.exitCode = 1; });
