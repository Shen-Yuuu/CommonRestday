/** Production repository SQL on isolated SQLite; never opens an app database or a device. */
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const { DatabaseSync } = require('node:sqlite');
const migration = require('./out/data/main/ets/db/MigrationRunner.js');
const root = path.resolve(__dirname, '../..');
const ts = require('D:/local/DevEcoStudio/tools/hvigor/hvigor/node_modules/typescript');
const file = path.join(root, 'data/src/main/ets/repo/SharedPlanRepo.ets');
assert.ok(fs.existsSync(file), 'shared plan production repository is missing');
const db = new DatabaseSync(':memory:');
const schema = require('./out/data/main/ets/db/SharedPlanSchema.js');
for (const sql of schema.SHARED_PLAN_DDL) db.exec(sql);
db.exec(`CREATE TABLE plan(id TEXT PRIMARY KEY,title TEXT,kind TEXT,start_min INTEGER,end_min INTEGER,
 status TEXT,created_by TEXT,window_ref TEXT,conflict_hint TEXT,my_event_id TEXT,reminder_id INTEGER,
 updated_at INTEGER,calendar_state TEXT,sync_state TEXT)`);
let fail = ''; let transactions = 0; let readsInTx = 0; let inTx = false;
const store = {
 beginTransaction() { db.exec('BEGIN'); inTx = true; transactions++; },
 commit() { db.exec('COMMIT'); inTx = false; },
 rollBack() { db.exec('ROLLBACK'); inTx = false; },
 async executeSql(sql, args = []) {
   if (fail && sql.includes(fail)) throw new Error('injected write failure');
   db.prepare(sql).run(...args);
 },
 async querySql(sql, args = []) {
   if (inTx) readsInTx++;
   const rows = db.prepare(sql).all(...args); let index = -1; const names = db.prepare(sql).columns().map(c => c.name);
   return { goToNextRow: () => ++index < rows.length, getColumnIndex: n => names.indexOf(n),
     getString: i => String(rows[index][names[i]]), getLong: i => Number(rows[index][names[i]]), close() {} };
 }
};
const deps = {
 '../db/Db': { Db: { get: () => store } },
 './ScheduleRepo': { ScheduleRepo: { async runInTransaction(work) {
   db.exec('BEGIN'); inTx = true; transactions++;
   try { await work(); db.exec('COMMIT'); } catch (e) { db.exec('ROLLBACK'); throw e; }
   finally { inTx = false; }
 } } }
};
const moduleObj = { exports: {} };
vm.runInNewContext(ts.transpileModule(fs.readFileSync(file, 'utf8'), {
 compilerOptions: { module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2021 }
}).outputText, { module: moduleObj, exports: moduleObj.exports, require: n => {
 if (!deps[n]) throw new Error('unexpected import ' + n); return deps[n];
} });
const { SharedPlanRepo } = moduleObj.exports;
deps['./SharedPlanRepo'] = { SharedPlanRepo };
const pairingModule = { exports: {} };
vm.runInNewContext(ts.transpileModule(fs.readFileSync(path.join(root, 'data/src/main/ets/repo/SecurePairingRepo.ets'), 'utf8'), {
 compilerOptions: { module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2021 }
}).outputText, { module: pairingModule, exports: pairingModule.exports, require: n => {
 if (!deps[n]) throw new Error('unexpected pairing import ' + n); return deps[n];
} });
const { SecurePairingRepo } = pairingModule.exports;
const scheduleModule = { exports: {} };
vm.runInNewContext(ts.transpileModule(fs.readFileSync(path.join(root, 'data/src/main/ets/repo/ScheduleRepo.ets'), 'utf8'), {
 compilerOptions: { module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2021 }
}).outputText, { module: scheduleModule, exports: scheduleModule.exports, require: n => {
 if (n === '@kit.ArkData') return { relationalStore: {} };
 if (n === 'domain') return {};
 if (n === 'commons') return { Logger: { warn() {} } };
 if (!deps[n]) throw new Error('unexpected schedule import ' + n); return deps[n];
} });
const ProductionScheduleRepo = scheduleModule.exports.ScheduleRepo;
const session = { pairId: 'pair-a', actorId: 'actor-a', generation: 'generation-1' };
function row(version, start = 600, active = true) {
 return { pairId: session.pairId, planId: 'plan-a', stateVersion: version, recordJson: JSON.stringify({ v: version, start }), terminal: !active && version > 1,
   activity: active ? { id: 'shared:pair-a:plan-a', title: '午餐', kind: 'meal', start, end: start + 60, contentRevision: version > 2 ? 2 : 1 } : null };
}
const activity = () => db.prepare("SELECT * FROM plan WHERE status <> 'CANCELLED'").all();
async function migrationChecks() {
 const old = new DatabaseSync(':memory:'); let failure = '';
 const adapter = {
   async execute(sql) { if (failure && sql.includes(failure)) throw new Error('v5 migration failure'); old.exec(sql); },
   async canSelect(sql) { try { old.prepare(sql).all(); return true; } catch { return false; } },
   async tableDDL(name) { return old.prepare('SELECT sql FROM sqlite_master WHERE name=?').get(name)?.sql ?? ''; },
   async getMeta(key) { return old.prepare('SELECT v FROM sync_meta WHERE k=?').get(key)?.v ?? ''; },
   async setMeta(key, value) { old.prepare('INSERT OR REPLACE INTO sync_meta(k,v) VALUES(?,?)').run(key, value); },
   begin() { old.exec('BEGIN'); }, commit() { old.exec('COMMIT'); }, rollback() { old.exec('ROLLBACK'); }
 };
 try {
   for (const sql of migration.ownerScopedDdlList()) old.exec(sql);
   old.exec(`CREATE TABLE sync_meta(k TEXT PRIMARY KEY,v TEXT);
     INSERT INTO sync_meta VALUES('schema_version','4');
     CREATE TABLE plan(id TEXT PRIMARY KEY,title TEXT,status TEXT,my_event_id TEXT,reminder_id INTEGER,
       updated_at INTEGER,calendar_state TEXT,sync_state TEXT);
     INSERT INTO plan VALUES('old','旧计划','OK','event-old',9,100,'MANAGED_WRITTEN','LOCAL_ONLY');
     CREATE TABLE computed_window(start_min INTEGER,computed_at INTEGER,channel TEXT);
     INSERT INTO cycle_template(id,owner,name,seq,anchor_day,weekdays_mask) VALUES('old','ME','旧循环','A',100,31)`);
   failure = 'CREATE TABLE IF NOT EXISTS shared_plan_outgoing';
   await assert.rejects(() => migration.MigrationRunner.upgrade(adapter), /v5 migration failure/);
   assert.equal(await adapter.getMeta('schema_version'), '4');
   assert.equal(old.prepare("SELECT count(*) AS n FROM sqlite_master WHERE name LIKE 'shared_plan_%'").get().n, 0);
   assert.equal(old.prepare('SELECT my_event_id FROM plan').get().my_event_id, 'event-old');
   failure = ''; await migration.MigrationRunner.upgrade(adapter);
   assert.equal(await adapter.getMeta('schema_version'), String(migration.SCHEMA_VERSION));
   // An already-installed v5 database upgrades by adding only the independent wire table.
   old.exec("DROP TABLE shared_plan_wire; UPDATE sync_meta SET v='5' WHERE k='schema_version'");
   failure = 'CREATE TABLE IF NOT EXISTS shared_plan_wire';
   await assert.rejects(() => migration.MigrationRunner.upgrade(adapter), /v5 migration failure/);
   assert.equal(await adapter.getMeta('schema_version'), '5');
   assert.equal(old.prepare("SELECT count(*) AS n FROM sqlite_master WHERE name='shared_plan_wire'").get().n, 0);
   failure = ''; await migration.MigrationRunner.upgrade(adapter);
   assert.equal(await adapter.getMeta('schema_version'), String(migration.SCHEMA_VERSION));
   // Existing v6: adding the setup table and version stamp are one rollback boundary.
   old.exec("DROP TABLE shared_pairing_setup; UPDATE sync_meta SET v='6' WHERE k='schema_version'");
   failure = 'CREATE TABLE IF NOT EXISTS shared_pairing_setup';
   await assert.rejects(() => migration.MigrationRunner.upgrade(adapter), /v5 migration failure/);
   assert.equal(await adapter.getMeta('schema_version'), '6');
   assert.equal(old.prepare("SELECT count(*) AS n FROM sqlite_master WHERE name='shared_pairing_setup'").get().n, 0);
   failure = ''; await migration.MigrationRunner.upgrade(adapter);
   assert.equal(await adapter.getMeta('schema_version'), '9');
   old.exec("DROP TABLE shared_pairing_cleanup; UPDATE sync_meta SET v='7' WHERE k='schema_version'");
   failure = 'CREATE TABLE IF NOT EXISTS shared_pairing_cleanup';
   await assert.rejects(() => migration.MigrationRunner.upgrade(adapter), /v5 migration failure/);
   assert.equal(await adapter.getMeta('schema_version'), '7');
   failure = ''; await migration.MigrationRunner.upgrade(adapter);
   assert.equal(await adapter.getMeta('schema_version'), '9');
   assert.equal(old.prepare('SELECT weekdays_mask FROM cycle_template').get().weekdays_mask, 31);
   assert.equal(old.prepare('SELECT title,my_event_id FROM plan').get().title, '旧计划');
   old.exec(`INSERT INTO shared_plan_session VALUES(1,'pair-a','actor-a','old-generation');
     INSERT INTO shared_plan_cache VALUES('pair-a','plan-a',2,'{}',0);
     INSERT INTO shared_plan_outgoing VALUES('pair-a','actor-a','old-generation','request-a','{}',100);
     INSERT INTO shared_plan_wire VALUES('pair-a','actor-a','old-generation','request-a','{}','cipher');
     INSERT INTO shared_plan_source VALUES('old','pair-a','plan-a','actor-a',1);
     INSERT INTO shared_pairing_setup VALUES(1,'restore-flow','sealed-progress');
     INSERT INTO shared_pairing_cleanup VALUES('restore-flow','old-auth','pair-a','LIVE');
     INSERT INTO sync_meta VALUES('restore_pending','1')`);
   await migration.MigrationRunner.upgrade(adapter);
   assert.equal(old.prepare('SELECT status FROM plan').get().status, 'CANCELLED');
   assert.equal(old.prepare('SELECT my_event_id FROM plan').get().my_event_id, '');
   assert.equal(old.prepare('SELECT status FROM shared_pairing_cleanup').get().status, 'RESTORED');
   for (const name of ['shared_plan_session','shared_plan_cache','shared_plan_outgoing','shared_plan_wire','shared_pairing_setup']) {
     assert.equal(old.prepare('SELECT count(*) AS n FROM ' + name).get().n, 0);
   }
   old.exec("INSERT INTO shared_pairing_setup VALUES(1,'v7-restore-no-ledger','legacy-progress'); INSERT INTO shared_plan_session VALUES(1,'old-pair','old-actor','v7-restore-no-ledger'); UPDATE sync_meta SET v='1' WHERE k='restore_pending'");
   await migration.MigrationRunner.upgrade(adapter);
   const legacyRestore = old.prepare("SELECT * FROM shared_pairing_cleanup WHERE flow_id='v7-restore-no-ledger'").get();
   assert.equal(legacyRestore.status, 'RESTORED'); assert.equal(legacyRestore.auth_uid, ''); assert.equal(legacyRestore.pair_id, 'old-pair');
 } finally { old.close(); }
}
async function main() {
 await migrationChecks();
 const secure = { pairId: 'sp-' + 'a'.repeat(32), actorId: 'm-' + 'a'.repeat(64), generation: 'setup-flow' };
 const pending = JSON.stringify({ flowId: secure.generation, pairId: secure.pairId, actorId: secure.actorId, authUid: 'auth-a', phase: 'PENDING_CONFIRM' });
 const active = JSON.stringify({ flowId: secure.generation, pairId: secure.pairId, actorId: secure.actorId, authUid: 'auth-a', phase: 'ACTIVE' });
 const revoked = JSON.stringify({ flowId: secure.generation, pairId: secure.pairId, actorId: secure.actorId, authUid: 'auth-a', phase: 'REVOKED' });
 assert.equal(await SecurePairingRepo.save('', pending), true);
 assert.equal(await SecurePairingRepo.save('', JSON.stringify({ flowId: 'other-flow', pairId: '', actorId: '', phase: 'CREATING' })), false);
 fail = 'INSERT INTO shared_plan_session';
 await assert.rejects(() => SecurePairingRepo.activate(pending, active, secure));
 fail = ''; assert.equal(await SecurePairingRepo.load(), pending);
 assert.equal(await SharedPlanRepo.session(), null, 'failed activation rolls back both session and progress');
 db.exec("DELETE FROM shared_pairing_setup");
 assert.equal(await SecurePairingRepo.activate(pending, active, secure), false);
 assert.equal(await SharedPlanRepo.session(), null, 'late activation cannot resurrect cleared progress');
 assert.equal(await SecurePairingRepo.save('', pending), true);
 assert.equal(await SecurePairingRepo.activate(pending, active, secure), true);
 assert.equal(await SecurePairingRepo.activate(active, active, secure), true);
 assert.equal(await SharedPlanRepo.isCurrent(secure), true);
 fail = 'DELETE FROM shared_plan_session';
 await assert.rejects(() => SecurePairingRepo.revoke(active, revoked));
 fail = ''; assert.equal(await SecurePairingRepo.load(), active); assert.equal(await SharedPlanRepo.isCurrent(secure), true);
 assert.equal(await SecurePairingRepo.revoke(active, revoked), true);
 assert.equal(await SharedPlanRepo.session(), null);
 db.exec('DELETE FROM shared_pairing_setup');
 db.exec("INSERT INTO shared_plan_session VALUES(1,'another-pair','another-actor','another-generation')");
 assert.equal(await SecurePairingRepo.save('', pending), false, 'cannot adopt an unowned old session');
 db.exec('DELETE FROM shared_plan_session');
 assert.equal(await SecurePairingRepo.save('', pending), true);
 db.exec("INSERT INTO shared_plan_session VALUES(1,'another-pair','another-actor','another-generation')");
 assert.equal(await SecurePairingRepo.activate(pending, active, secure), false, 'cannot replace another live connection');
 assert.equal(await SecurePairingRepo.load(), pending);
 db.exec('DELETE FROM shared_plan_session; DELETE FROM shared_pairing_setup');
 await SharedPlanRepo.activate(session);
 assert.equal(await SharedPlanRepo.cursor(session), 0);
 assert.equal(await SharedPlanRepo.saveCursor(session, 12), true);
 assert.equal(await SharedPlanRepo.saveCursor(session, 11), false, 'cursor cannot regress');
 assert.equal(await SharedPlanRepo.cursor(session), 12);
 await SharedPlanRepo.markVote(session, 'plan-a', 2);
 await SharedPlanRepo.markVote(session, 'plan-a', 1);
 assert.deepEqual(Array.from(await SharedPlanRepo.voted(session)), ['plan-a:2']);
 await SharedPlanRepo.apply(session, [row(1, 600, false)]); assert.equal(activity().length, 0);
 await SharedPlanRepo.apply(session, [row(2)]); assert.equal(activity().length, 1);
 assert.equal(await SharedPlanRepo.localActivityId(session, 'plan-a'), 'shared:pair-a:plan-a');
 assert.equal(await SharedPlanRepo.localActivityId({ ...session, actorId: 'other' }, 'plan-a'), '');
 assert.equal(await SharedPlanRepo.localActivityId(session, 'other-plan'), '');
 const firstUpdated = activity()[0].updated_at;
 assert.equal(activity()[0].calendar_state, 'NOT_REQUESTED');
 await SharedPlanRepo.apply(session, [row(2)]); assert.equal(activity().length, 1);
 assert.equal(activity()[0].updated_at, firstUpdated, 'equal versions do not rewrite activity metadata');
 await SharedPlanRepo.apply(session, [row(1, 900)]); assert.equal(activity()[0].start_min, 600);
 // Equal-version tampering may not change either cache or activity.
 await SharedPlanRepo.apply(session, [row(2, 900)]); assert.equal(activity()[0].start_min, 600);
 // Pending amendment keeps the confirmed content (provided by validated feature projection).
 await SharedPlanRepo.apply(session, [row(3, 600)]); assert.equal(activity()[0].start_min, 600);
 db.exec("UPDATE plan SET my_event_id='calendar-1',calendar_state='MANAGED_WRITTEN'");
 await SharedPlanRepo.apply(session, [row(4, 900)]);
 assert.equal(activity()[0].start_min, 900); assert.equal(activity()[0].my_event_id, 'calendar-1');
 assert.equal(activity()[0].calendar_state, 'CLEANUP_PENDING');
 fail = 'shared_plan_source';
 await assert.rejects(() => SharedPlanRepo.apply(session, [row(5, 1000)]));
 fail = ''; assert.equal(activity()[0].start_min, 900);
 assert.equal(db.prepare('SELECT state_version FROM shared_plan_cache').get().state_version, 4);
 await SharedPlanRepo.enqueue(session, 'req-1', '{"action":"CANCEL"}');
 assert.equal(await SharedPlanRepo.wire(session, 'req-1', '{"action":"CANCEL"}'), '');
 const firstWire = await SharedPlanRepo.saveWire(session, 'req-1', '{"action":"CANCEL"}', '{"envelope":"cipher-first"}');
 assert.equal(firstWire, '{"envelope":"cipher-first"}');
 assert.equal(await SharedPlanRepo.saveWire(session, 'req-1', '{"action":"CANCEL"}', '{"envelope":"cipher-second"}'), firstWire);
 await assert.rejects(() => SharedPlanRepo.saveWire(session, 'req-1', '{"action":"ACCEPT"}', '{}'));
 assert.equal(await SharedPlanRepo.wire(session, 'req-1', '{"action":"CANCEL"}'), firstWire);
 await SharedPlanRepo.enqueue(session, 'req-1', '{"action":"CANCEL"}');
 assert.equal((await SharedPlanRepo.pending(session)).length, 1);
 await assert.rejects(() => SharedPlanRepo.enqueue(session, 'req-1', '{"action":"ACCEPT"}'));
 fail = 'DELETE FROM shared_plan_wire';
 await assert.rejects(() => SharedPlanRepo.finishRequest(session, 'req-1'));
 fail = '';
 assert.equal((await SharedPlanRepo.pending(session)).length, 1, 'failed wire cleanup rolls back draft deletion');
 assert.equal(await SharedPlanRepo.wire(session, 'req-1', '{"action":"CANCEL"}'), firstWire);
 await SharedPlanRepo.finishRequest(session, 'req-1');
 assert.equal((await SharedPlanRepo.pending(session)).length, 0);
 assert.equal(await SharedPlanRepo.wire(session, 'req-1', '{"action":"CANCEL"}'), '');
 await SharedPlanRepo.enqueue(session, 'req-1', '{"action":"CANCEL"}');
 await SharedPlanRepo.saveWire(session, 'req-1', '{"action":"CANCEL"}', firstWire);
 const next = { ...session, generation: 'generation-2' }; await SharedPlanRepo.activate(next);
 assert.equal(await SharedPlanRepo.cursor(next), 0); assert.deepEqual(Array.from(await SharedPlanRepo.voted(next)), []);
 assert.equal(await SharedPlanRepo.saveCursor(session, 13), false, 'old generation cannot advance new cursor');
 assert.equal(await SharedPlanRepo.apply(session, [row(5, 1100)]), false);
 assert.equal(activity()[0].start_min, 900);
 assert.equal((await SharedPlanRepo.pending(next)).length, 0);
 assert.equal(db.prepare('SELECT count(*) AS n FROM shared_plan_wire').get().n, 0);
 await assert.rejects(() => SharedPlanRepo.saveWire(session, 'req-1', '{"action":"CANCEL"}', '{}'));
 await SharedPlanRepo.apply(next, [row(5, 900, false)]);
 assert.equal(activity().length, 0);
 assert.equal(db.prepare('SELECT my_event_id FROM plan').get().my_event_id, 'calendar-1');
 assert.equal(db.prepare('SELECT calendar_state FROM plan').get().calendar_state, 'CLEANUP_PENDING');
 await SharedPlanRepo.apply(next, [row(6, 1100)]); assert.equal(activity().length, 0, 'terminal cannot revive');
 db.prepare('INSERT INTO plan(id,title,status,start_min,end_min) VALUES(?,?,?,?,?)').run('personal', '自己的安排', 'OK', 800, 860);
 await SharedPlanRepo.invalidate(); assert.equal(activity().length, 1); assert.equal(activity()[0].id, 'personal');
 // Actual production clear-all SQL, not a copied algorithm. Only this in-memory fixture is cleared.
 for (const table of ['shift_type', 'cycle_template', 'schedule_override', 'course', 'term_config', 'computed_window', 'sync_meta']) {
   db.exec(`CREATE TABLE IF NOT EXISTS ${table}(id TEXT)`);
 }
 db.exec('DELETE FROM shared_pairing_setup; DELETE FROM shared_pairing_cleanup; DELETE FROM shared_plan_session');
 const full = JSON.stringify({ flowId: 'clear-flow', authUid: 'auth-original', pairId: secure.pairId,
   actorId: secure.actorId, phase: 'ACTIVE', sealedProof: 'not-in-ledger', inviteCode: '123456' });
 assert.equal(await SecurePairingRepo.save('', full), true);
 const clearSession = { ...secure, generation: 'clear-flow' };
 assert.equal(await SecurePairingRepo.activate(full, full, clearSession), true);
 db.exec("INSERT INTO shared_pairing_cleanup VALUES('unknown-flow','auth-original','','LIVE'); INSERT INTO shared_pairing_cleanup VALUES('old-debt','old-auth','old-pair','REVIEW')");
 fail = 'DELETE FROM course';
 await assert.rejects(() => ProductionScheduleRepo.clearAllData());
 fail = '';
 assert.equal(await SecurePairingRepo.load(), full);
 assert.equal(db.prepare("SELECT status FROM shared_pairing_cleanup WHERE flow_id='clear-flow'").get().status, 'LIVE');
 assert.equal(activity().length, 1, 'failed clear rolls back schedule and ledger transition together');
 await ProductionScheduleRepo.clearAllData();
 assert.equal(await SecurePairingRepo.load(), ''); assert.equal(await SharedPlanRepo.session(), null);
 const debts = await SecurePairingRepo.cleanupRecords(); assert.equal(debts.length, 3);
 assert.equal(debts.find(r => r.flowId === 'clear-flow').authUid, 'auth-original');
 assert.equal(debts.find(r => r.flowId === 'clear-flow').status, 'WAITING');
 assert.equal(debts.find(r => r.flowId === 'unknown-flow').status, 'UNRESOLVED');
 assert.equal(debts.find(r => r.flowId === 'old-debt').status, 'REVIEW');
 assert.ok(!JSON.stringify(debts).includes('not-in-ledger')); assert.ok(!JSON.stringify(debts).includes('123456'));
 await ProductionScheduleRepo.clearAllData(); assert.equal((await SecurePairingRepo.cleanupRecords()).length, 3);
 assert.equal(await SecurePairingRepo.activate(full, full, clearSession), false);
 assert.equal(await SecurePairingRepo.save(full, full), false);
 assert.equal(db.prepare("SELECT status FROM shared_pairing_cleanup WHERE flow_id='clear-flow'").get().status, 'WAITING');
 const debt = debts.find(r => r.flowId === 'clear-flow');
 await SecurePairingRepo.finishCleanup({ ...debt, authUid: 'wrong-auth' }, '');
 assert.equal((await SecurePairingRepo.cleanupRecords()).length, 3);
 await SecurePairingRepo.finishCleanup(debt, ''); assert.equal((await SecurePairingRepo.cleanupRecords()).length, 2);
 // Upgraded v7 progress existed before the ledger was introduced; clear must capture its real auth UID.
 db.prepare('INSERT INTO shared_pairing_setup VALUES(1,?,?)').run('upgrade-flow', JSON.stringify({ flowId: 'upgrade-flow', authUid: 'upgrade-auth', pairId: secure.pairId, phase: 'ACTIVE' }));
 await ProductionScheduleRepo.clearAllData();
 assert.equal((await SecurePairingRepo.cleanupRecords()).find(r => r.flowId === 'upgrade-flow').authUid, 'upgrade-auth');
 db.prepare('INSERT INTO shared_pairing_setup VALUES(1,?,?)').run('corrupt-flow', 'not-json');
 await ProductionScheduleRepo.clearAllData();
 assert.equal((await SecurePairingRepo.cleanupRecords()).find(r => r.flowId === 'corrupt-flow').status, 'REVIEW');
 assert.equal(readsInTx, 0, 'pooled RDB readers must not be used within a write transaction');
 assert.ok(transactions > 0);
 console.log('shared-plan-storage: PASS (v4/v5/v6/v7/v8→v9 rollback/restore/CAS/cursor/vote generation fences/idempotence/exact ciphertext retry)');
}
main().catch(e => { console.error(e.stack); process.exitCode = 1; }).finally(() => db.close());
