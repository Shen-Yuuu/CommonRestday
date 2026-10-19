import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import { createRequire } from 'node:module';
import { fileURLToPath } from 'node:url';
import { createECDH, generateKeyPairSync, verify, constants } from 'node:crypto';
import vm from 'node:vm';

const require = createRequire(import.meta.url);
const repo = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '../..');
const dir = path.join(repo, 'cloud-backend/cloudfunctions/dateplan');
assert.ok(fs.existsSync(path.join(dir, 'dateplan.ts')), 'dateplan implementation must exist');
const ts = require(path.join(repo, '../CloudDevSpikeOfficial/CloudProgram/node_modules/typescript'));
const sdkDir = path.join(repo, '../FortwoCloud/CloudProgram/cloudfunctions/pairing/node_modules/@hw-agconnect/cloud-server');
const types = path.join(repo, '../FortwoCloud/CloudProgram/node_modules/@types');
// Exercise CloudDev's actual ES5 default as well as the modern local target.
const emitTarget = process.argv.includes('--es5') ? ts.ScriptTarget.ES5 : ts.ScriptTarget.ES2020;
const program = ts.createProgram([path.join(dir, 'dateplan.ts'), path.join(dir, 'dispatch.ts'), path.join(dir, 'wake.ts')], {
  strict: true, noEmit: true, skipLibCheck: true, target: ts.ScriptTarget.ES2020,
  module: ts.ModuleKind.CommonJS, moduleResolution: ts.ModuleResolutionKind.NodeJs,
  types: ['node'], typeRoots: [types], baseUrl: repo,
  paths: { '@hw-agconnect/cloud-server': [path.join(sdkDir, 'index.d.ts')] }
});
const diagnostics = ts.getPreEmitDiagnostics(program);
if (diagnostics.length) {
  console.error(ts.formatDiagnosticsWithColorAndContext(diagnostics, {
    getCanonicalFileName: n => n, getCurrentDirectory: () => repo, getNewLine: () => '\n'
  }));
  process.exit(1);
}
console.log('dateplan SDK strict/noEmit: PASS');

const models = require(path.join(dir, 'models.js'));
// Match production CloudDB reads using the installed SDK, not number-preserving structuredClone.
// In SDK 1.0.5 Long fields remain decimal strings; Integer fields are decoded to numbers.
const utilsFile = path.join(sdkDir, 'database-service/utils/Utils.js');
const utilsModule = { exports: {} };
vm.runInNewContext(fs.readFileSync(utilsFile, 'utf8'), { module: utilsModule, exports: utilsModule.exports,
  console, require: name => name === './FieldType' || name === './Constant'
    ? require(path.resolve(path.dirname(utilsFile), name)) : {} });
function sdkRead(row) {
  const wire = structuredClone(row);
  for (const [field, type] of row.getFieldTypeMap()) {
    if (type === 'Long' && wire[field] !== null && wire[field] !== undefined) wire[field] = String(wire[field]);
  }
  return utilsModule.exports.Utils.deserializeObjects([wire], row.getFieldTypeMap(), row.constructor, row.getClassName())[0];
}
const tables = new Map();
let epoch = 0;
let failCommit = false;
let loseCommitResponse = false;
let ignoreCas = false;
let dbCalls = 0;
function table(name) {
  if (!tables.has(name)) tables.set(name, new Map());
  return tables.get(name);
}
function clone(value) { return Object.assign(new value.constructor(), structuredClone(value)); }
function collection(Model) {
  const name = new Model().getClassName();
  return {
    query() {
      const filters = []; let count = Infinity; let offset = 0; let ordering = null;
      const q = { name,
        equalTo(key, value) { filters.push([key, value]); return q; },
        greaterThanOrEqualTo(key, value) { filters.push([key, value, 'gte']); return q; },
        greaterThan(key, value) { filters.push([key, value, 'gt']); return q; },
        lessThan(key, value) { filters.push([key, value, 'lt']); return q; },
        lessThanOrEqualTo(key, value) { filters.push([key, value, 'lte']); return q; },
        orderByAsc(key) { ordering = key; return q; },
        limit(n, start = 0) { count = n; offset = start; return q; },
        rows() { const rows = [...table(name).values()].filter(e => filters.every(([k, v, op]) =>
          op === 'gte' ? e.row[k] >= v : op === 'gt' ? e.row[k] > v : op === 'lt' ? e.row[k] < v
            : op === 'lte' ? e.row[k] <= v : e.row[k] === v));
          if (ordering) rows.sort((a, b) => a.row[ordering] - b.row[ordering]);
          return rows.slice(offset, offset + count); },
        async get() { dbCalls++; return q.rows().map(e => sdkRead(e.row)); }
      };
      return q;
    },
    async insert(row) {
      dbCalls++;
      if (table(name).has(row.id)) throw new Error('duplicate');
      table(name).set(row.id, { row: clone(row), epoch: ++epoch }); return 1;
    },
    async delete(row) { dbCalls++; return table(name).delete(row.id) ? 1 : 0; },
    async runTransaction(fn) {
      dbCalls++;
      const reads = []; const writes = []; let writing = false;
      const tx = {
        async executeQuery(q) {
          assert.equal(writing, false, 'SDK requires every query before any write');
          const found = q.rows();
          for (const entry of found) reads.push([q.name, entry.row.id, entry.epoch]);
          // Deliberately do NOT lock absence: safety must anchor on the existing binding row.
          await Promise.resolve();
          return found.map(e => sdkRead(e.row));
        },
        executeUpsert(rows) { writing = true; for (const row of rows) writes.push(['put', clone(row)]); return tx; },
        executeDelete(rows) { writing = true; for (const row of rows) writes.push(['delete', clone(row)]); return tx; }
      };
      if (!await fn.apply(tx)) return false;
      if (!ignoreCas && reads.some(([n, id, version]) => table(n).get(id)?.epoch !== version)) return false;
      if (failCommit) throw new Error('fixture secret must never be returned');
      for (const [op, row] of writes) {
        const target = table(row.getClassName());
        if (op === 'put') target.set(row.id, { row, epoch: ++epoch }); else target.delete(row.id);
      }
      if (loseCommitResponse) { loseCommitResponse = false; throw new Error('response lost after commit'); }
      return true;
    }
  };
}
const env = { FORTWO_AUTH_PROJECT_ID: 'test-project', FORTWO_ENABLE_SHARED_PLAN_V1: 'true',
  FORTWO_SHARED_PLAN_ZONE: 'FortwoPlanProbe' };
const sdk = { Region: { REGION_CN: 'CN' }, cloud: { createInstance: () => ({
  auth: () => ({ async verifyAccessToken(params) {
    assert.equal(params.checkRevoked, true);
    if (!['token-A', 'token-B', 'token-C', 'wrong-project', 'expired', 'empty-sub'].includes(params.accessToken)) throw new Error('auth secret');
    return { getAud: () => params.accessToken === 'wrong-project' ? 'elsewhere' : 'test-project',
      getSub: () => params.accessToken === 'empty-sub' ? '' : params.accessToken,
      getExp: () => params.accessToken === 'expired' ? 0 : Date.now() / 1000 + 600 };
  } }), database: ({ zoneName }) => { assert.equal(zoneName, 'FortwoPlanProbe'); return { collection }; }
}) } };
const cache = new Map();
function load(file) {
  if (cache.has(file)) return cache.get(file);
  const js = ts.transpileModule(fs.readFileSync(path.join(dir, file + '.ts'), 'utf8'), {
    compilerOptions: { target: emitTarget, module: ts.ModuleKind.CommonJS }
  }).outputText;
  const module = { exports: {} };
  new Function('require', 'module', 'exports', 'process', js)(name => name === '@hw-agconnect/cloud-server' ? sdk
    : name === './models' ? models : name.startsWith('./') ? load(name.slice(2)) : require(name),
  module, module.exports, { env });
  cache.set(file, module.exports); return module.exports;
}
const { DatePlan } = load('dateplan');
const api = new DatePlan();
const key = createECDH('prime256v1').generateKeys().toString('base64');
const envelope = (revision = 1, content = 'x') => JSON.stringify({ protocolVersion: 1, contentRevision: revision,
  algorithm: 'AES-256-GCM', iv: Buffer.alloc(12, 1).toString('base64'),
  authTag: Buffer.alloc(16, 2).toString('base64'), ciphertext: Buffer.from(content).toString('base64') });
let passed = 0;
async function test(name, fn) { await fn(); passed++; console.log('PASS ' + name); }
const mutation = (pairId, planId, requestId, action, version, cipher = '') =>
  JSON.stringify({ pairId, planId, requestId: pairId + '-' + requestId, action, expectedVersion: version, envelope: cipher });
async function paired(suffix) {
  const made = await api.createPair('token-A', 'create-' + suffix, key, 1);
  assert.equal(made.code, 'OK');
  assert.equal((await api.joinPair('token-B', made.inviteCode, key, 1)).code, 'OK');
  assert.equal((await api.confirmPair('token-A', made.pairId, made.confirmSecret)).code, 'OK');
  return made.pairId;
}
async function proposed(pairId, planId = 'plan-one', request = 'propose-one') {
  const result = await api.mutate('token-A', mutation(pairId, planId, request, 'PROPOSE', 0, envelope()));
  assert.equal(result.code, 'OK'); return result;
}

await test('models, schema and administrator-only permissions match', async () => {
  for (const Model of Object.values(models)) {
    const row = new Model();
    const schema = JSON.parse(fs.readFileSync(path.join(repo, 'cloud-backend/clouddb/objecttype', row.getClassName() + '.json')));
    assert.deepEqual([...row.getFieldTypeMap()], schema.fields.map(f => [f.fieldName, f.fieldType]));
    assert.deepEqual(row.getPrimaryKeyList(), ['id']);
    assert.deepEqual(row.getIndexList(), schema.indexes.map(index => index.indexList.map(field => field.fieldName).join(',')));
    assert.ok(schema.permissions.filter(p => p.role !== 'Administrator').every(p => p.rights.length === 0));
  }
});
await test('disabled gate sends no database request', async () => {
  env.FORTWO_ENABLE_SHARED_PLAN_V1 = 'false'; const before = dbCalls;
  assert.equal((await api.createPair('token-A', 'disabled', key, 1)).code, 'FEATURE_DISABLED');
  assert.equal(dbCalls, before); env.FORTWO_ENABLE_SHARED_PLAN_V1 = 'true';
});
await test('bad token, wrong project, expired and absent subjects reject', async () => {
  for (const token of ['invalid', 'wrong-project', 'expired', 'empty-sub']) {
    assert.equal((await api.createPair(token, 'denied', key, 1)).code, 'AUTH_REJECTED');
  }
});
await test('missing project or zone fails closed without database access', async () => {
  for (const variable of ['FORTWO_AUTH_PROJECT_ID', 'FORTWO_SHARED_PLAN_ZONE']) {
    const old = env[variable]; delete env[variable]; const before = dbCalls;
    assert.equal((await api.createPair('token-A', 'missing-config', key, 1)).code, 'CONFIG_MISSING');
    assert.equal(dbCalls, before); env[variable] = old;
  }
});
await test('invalid curve point or unsupported projection cannot establish a pair', async () => {
  assert.equal((await api.createPair('token-A', 'bad-point', Buffer.alloc(65, 4).toString('base64'), 1)).code, 'BAD_REQUEST');
  assert.equal((await api.createPair('token-A', 'bad-capability', key, 0)).code, 'BAD_REQUEST');
});
await test('create retries are stable and do not disclose proof to others', async () => {
  const a = await api.createPair('token-A', 'stable-create', key, 1);
  const b = await api.createPair('token-A', 'stable-create', key, 1);
  assert.equal(a.pairId, b.pairId); assert.notEqual(a.confirmSecret, b.confirmSecret);
  assert.equal((await api.joinPair('token-B', b.inviteCode, key, 1)).code, 'OK');
  assert.equal((await api.confirmPair('token-A', b.pairId, a.confirmSecret)).code, 'FORBIDDEN');
  assert.equal((await api.confirmPair('token-A', b.pairId, b.confirmSecret)).code, 'OK');
  assert.equal((await api.pairStatus('token-C', a.pairId)).code, 'FORBIDDEN');
  assert.equal((await api.createPair('token-A', 'stable-create', createECDH('prime256v1').generateKeys().toString('base64'), 1)).code, 'REQUEST_REUSED');
});
await test('secure join never trusts uid and only creator can confirm', async () => {
  const a = await api.createPair('token-A', 'secure-join', key, 1);
  assert.equal((await api.joinPair('token-A', a.inviteCode, key, 1)).code, 'FORBIDDEN');
  assert.equal((await api.joinPair('token-B', a.inviteCode, key, 1)).status, 'PENDING_CONFIRM');
  assert.equal((await api.joinPair('token-C', a.inviteCode, key, 1)).code, 'CODE_TAKEN');
  assert.equal((await api.confirmPair('token-B', a.pairId, a.confirmSecret)).code, 'FORBIDDEN');
  assert.equal((await api.confirmPair('token-A', a.pairId, 'invalid')).code, 'FORBIDDEN');
  const confirmed = await api.confirmPair('token-A', a.pairId, a.confirmSecret);
  assert.equal(confirmed.status, 'ACTIVE');
  assert.equal(Object.hasOwn(confirmed, 'confirmSecret'), false);
  assert.equal(Object.hasOwn(await api.pairStatus('token-B', a.pairId), 'confirmSecret'), false);
});
await test('two joiners cannot both become the recipient', async () => {
  const made = await api.createPair('token-A', 'join-race', key, 1);
  const results = await Promise.all([api.joinPair('token-B', made.inviteCode, key, 1), api.joinPair('token-C', made.inviteCode, key, 1)]);
  assert.equal(results.filter(r => r.code === 'OK').length, 1);
  assert.equal(results.filter(r => r.code === 'VERSION_CONFLICT').length, 1);
});
await test('lost join reply can recover the authenticated original binding after the code is cleared', async () => {
  const made = await api.createPair('token-A', 'lost-join-reply', key, 1);
  const joined = await api.joinPair('token-B', made.inviteCode, key, 1);
  await api.confirmPair('token-A', made.pairId, made.confirmSecret);
  assert.equal(table('PairMemberBinding').get(made.pairId).row.inviteCode, '');
  const recovered = await api.joinPair('token-B', made.inviteCode, key, 1);
  assert.equal(recovered.code, 'OK'); assert.equal(recovered.status, 'ACTIVE'); assert.equal(recovered.pairId, joined.pairId);
  assert.equal((await api.joinPair('token-C', made.inviteCode, key, 1)).code, 'CODE_EXPIRED');
  const otherKey = createECDH('prime256v1').generateKeys().toString('base64');
  assert.equal((await api.joinPair('token-B', made.inviteCode, otherKey, 1)).code, 'CODE_EXPIRED');
  await api.unpair('token-A', made.pairId);
  assert.equal((await api.joinPair('token-B', made.inviteCode, key, 1)).code, 'CODE_EXPIRED');
});
await test('duplicate short codes fail closed rather than choosing an arbitrary session', async () => {
  const a = await api.createPair('token-A', 'code-collision-a', key, 1);
  const b = await api.createPair('token-A', 'code-collision-b', key, 1);
  table('PairMemberBinding').get(b.pairId).row.inviteCode = a.inviteCode;
  assert.equal((await api.joinPair('token-B', a.inviteCode, key, 1)).code, 'CODE_COLLISION');
});
await test('duplicate authenticated join recovery digests never choose an arbitrary binding', async () => {
  const a = await api.createPair('token-A', 'recovery-collision-a', key, 1);
  const b = await api.createPair('token-A', 'recovery-collision-b', key, 1);
  await api.joinPair('token-B', a.inviteCode, key, 1);
  const original = table('PairMemberBinding').get(a.pairId).row;
  const other = table('PairMemberBinding').get(b.pairId).row;
  other.recipientSubject = original.recipientSubject;
  other.recipientJoinDigest = original.recipientJoinDigest;
  assert.equal((await api.joinPair('token-B', a.inviteCode, key, 1)).code, 'CODE_COLLISION');
});
await test('legacy pair IDs cannot be claimed as authenticated sessions', async () => {
  assert.equal((await api.pairStatus('token-A', 'old-legacy-pair')).code, 'NOT_FOUND');
  assert.equal((await api.mutate('token-A', mutation('old-legacy-pair', 'p', 'r', 'PROPOSE', 0, envelope()))).code, 'NOT_FOUND');
});
await test('pending proposal, request receipt and outbox commit together', async () => {
  const pair = await paired('pending'); const result = await proposed(pair);
  assert.equal(result.plan.state, 'PENDING'); assert.equal(result.plan.acceptedRevision, 0);
  assert.equal(result.plan.acceptedEnvelope, '');
  assert.equal([...table('PairPlanRequest').values()].filter(e => e.row.pairId === pair).length, 1);
  assert.equal([...table('PairPlanOutbox').values()].filter(e => e.row.pairId === pair).length, 1);
  assert.ok(!JSON.stringify(result).includes('token-A'));
});
await test('duplicate request is immutable; changed content rejects and scopes are independent', async () => {
  const pair = await paired('replay');
  const first = await proposed(pair);
  assert.deepEqual(await api.mutate('token-A', mutation(pair, 'plan-one', 'propose-one', 'PROPOSE', 0, envelope())), first);
  assert.equal((await api.mutate('token-A', mutation(pair, 'plan-one', 'propose-one', 'PROPOSE', 0, envelope(1, 'changed')))).code, 'REQUEST_REUSED');
  const another = await paired('replay-other');
  const stolen = JSON.parse(mutation(pair, 'plan-one', 'propose-one', 'PROPOSE', 0, envelope()));
  stolen.pairId = another;
  assert.equal((await api.mutate('token-A', JSON.stringify(stolen))).code, 'OK');
  assert.equal([...table('PairPlanRequest').values()].filter(e => e.row.pairId === another).length, 1);
  assert.equal((await api.mutate('token-C', JSON.stringify(stolen))).code, 'FORBIDDEN');
});
await test('the same request ID in concurrent pairs never overwrites another receipt', async () => {
  const a = await paired('scoped-a'); const b = await paired('scoped-b');
  const ca = JSON.parse(mutation(a, 'p', 'same', 'PROPOSE', 0, envelope()));
  const cb = JSON.parse(mutation(b, 'p', 'same', 'PROPOSE', 0, envelope()));
  ca.requestId = 'same-global-id'; cb.requestId = 'same-global-id';
  const results = await Promise.all([api.mutate('token-A', JSON.stringify(ca)), api.mutate('token-A', JSON.stringify(cb))]);
  assert.ok(results.every(r => r.code === 'OK'));
  for (const pair of [a, b]) assert.equal([...table('PairPlanRequest').values()].filter(e => e.row.pairId === pair).length, 1);
});
await test('author cannot self-accept; nonmember cannot read or mutate', async () => {
  const pair = await paired('roles'); await proposed(pair);
  assert.equal((await api.mutate('token-A', mutation(pair, 'plan-one', 'self', 'ACCEPT', 1))).code, 'FORBIDDEN');
  assert.equal((await api.read('token-C', pair)).code, 'FORBIDDEN');
  assert.equal((await api.mutate('token-C', mutation(pair, 'plan-one', 'forge', 'ACCEPT', 1))).code, 'FORBIDDEN');
  assert.equal((await api.mutate('token-B', JSON.stringify({ pairId: pair, planId: 'plan-one', requestId: 'forged-field',
    action: 'ACCEPT', expectedVersion: 1, envelope: '', actorUid: 'token-A' }))).code, 'BAD_REQUEST');
});
await test('accept changes state only and leaves encrypted content revision unchanged', async () => {
  const pair = await paired('accept'); const first = await proposed(pair);
  const yes = await api.mutate('token-B', mutation(pair, 'plan-one', 'accept-one', 'ACCEPT', 1));
  assert.equal(yes.code, 'OK'); assert.equal(yes.plan.stateVersion, 2);
  assert.equal(yes.plan.acceptedRevision, 1); assert.equal(yes.plan.acceptedEnvelope, first.plan.pendingEnvelope);
  assert.equal(yes.plan.pendingEnvelope, '');
});
await test('amend reject preserves old accepted time; next revision increases', async () => {
  const pair = await paired('amend'); await proposed(pair);
  await api.mutate('token-B', mutation(pair, 'plan-one', 'yes', 'ACCEPT', 1));
  const amend = await api.mutate('token-B', mutation(pair, 'plan-one', 'amend', 'AMEND', 2, envelope(2, 'new')));
  assert.equal(amend.plan.state, 'ACCEPTED'); assert.equal(amend.plan.acceptedRevision, 1);
  assert.equal(amend.plan.contentRevision, 2);
  const no = await api.mutate('token-A', mutation(pair, 'plan-one', 'no', 'DECLINE', 3));
  assert.equal(no.plan.state, 'ACCEPTED'); assert.equal(no.plan.acceptedRevision, 1);
  assert.equal(no.plan.pendingEnvelope, '');
  assert.equal((await api.mutate('token-A', mutation(pair, 'plan-one', 'amend3', 'AMEND', 4, envelope(3)))).plan.contentRevision, 3);
});
await test('server retention expiry never confirms a pending invitation', async () => {
  const pair = await paired('expire'); await proposed(pair);
  const entry = [...table('PairDatePlan').values()].find(e => e.row.pairId === pair);
  entry.row.pendingExpiresAt = Date.now() - 1; entry.epoch = ++epoch;
  assert.equal((await api.mutate('token-B', mutation(pair, 'plan-one', 'late-accept', 'ACCEPT', 1))).code, 'INVITE_EXPIRED');
  const expired = await api.read('token-B', pair);
  assert.equal(expired.plans[0].state, 'EXPIRED'); assert.equal(expired.plans[0].stateVersion, 2);
  assert.equal(expired.plans[0].pendingEnvelope, '');
});
await test('expired rescheduling preserves accepted envelope and clears pending only', async () => {
  const pair = await paired('expire-amend'); await proposed(pair);
  await api.mutate('token-B', mutation(pair, 'plan-one', 'yes', 'ACCEPT', 1));
  await api.mutate('token-A', mutation(pair, 'plan-one', 'amend', 'AMEND', 2, envelope(2)));
  const entry = [...table('PairDatePlan').values()].find(e => e.row.pairId === pair);
  entry.row.pendingExpiresAt = Date.now() - 1; entry.epoch = ++epoch;
  const result = await api.read('token-B', pair);
  assert.equal(result.plans[0].state, 'ACCEPTED'); assert.equal(result.plans[0].acceptedRevision, 1);
  assert.equal(result.plans[0].pendingEnvelope, ''); assert.equal(result.plans[0].stateVersion, 4);
});
await test('accept versus withdraw commits exactly once', async () => {
  const pair = await paired('race'); await proposed(pair);
  const result = await Promise.all([
    api.mutate('token-A', mutation(pair, 'plan-one', 'withdraw-race', 'WITHDRAW', 1)),
    api.mutate('token-B', mutation(pair, 'plan-one', 'accept-race', 'ACCEPT', 1))
  ]);
  assert.equal(result.filter(r => r.code === 'OK').length, 1);
  assert.equal(result.filter(r => r.code === 'VERSION_CONFLICT').length, 1);
  const rows = await api.read('token-A', pair);
  assert.equal(rows.plans[0].stateVersion, 2);
  assert.equal([...table('PairPlanRequest').values()].filter(e => e.row.pairId === pair).length, 2);
});
await test('two absent proposals are serialized on the existing binding', async () => {
  const pair = await paired('absent-race');
  const result = await Promise.all([proposed(pair, 'same-plan', 'same-request'), proposed(pair, 'same-plan', 'same-request')]);
  assert.deepEqual(result[0], result[1]);
  assert.equal([...table('PairDatePlan').values()].filter(e => e.row.pairId === pair).length, 1);
  assert.equal([...table('PairPlanOutbox').values()].filter(e => e.row.pairId === pair).length, 1);
});
await test('network/SDK failure cannot persist optimistic state', async () => {
  const pair = await paired('failure'); await proposed(pair);
  failCommit = true;
  const result = await api.mutate('token-B', mutation(pair, 'plan-one', 'failed', 'ACCEPT', 1));
  failCommit = false;
  assert.equal(result.code, 'RESULT_UNKNOWN');
  assert.equal((await api.read('token-A', pair)).plans[0].state, 'PENDING');
  assert.equal([...table('PairPlanRequest').values()].filter(e => e.row.pairId === pair).length, 1);
  assert.ok(!JSON.stringify(result).includes('fixture secret'));
});
await test('lost response retries exact request without a second event', async () => {
  const pair = await paired('lost'); await proposed(pair);
  loseCommitResponse = true;
  const input = mutation(pair, 'plan-one', 'lost-yes', 'ACCEPT', 1);
  assert.equal((await api.mutate('token-B', input)).code, 'RESULT_UNKNOWN');
  const replay = await api.mutate('token-B', input);
  assert.equal(replay.code, 'OK'); assert.equal(replay.plan.stateVersion, 2);
  assert.equal([...table('PairPlanOutbox').values()].filter(e => e.row.pairId === pair).length, 2);
});
await test('encrypted envelope validates protocol, revision and bounded base64', async () => {
  const pair = await paired('envelope');
  for (const cipher of ['plaintext', envelope(2), '{}', envelope(1, 'x'.repeat(9000))]) {
    assert.equal((await api.mutate('token-A', mutation(pair, 'p', 'bad-cipher', 'PROPOSE', 0, cipher))).code, 'BAD_ENVELOPE');
  }
});
await test('push registration is self-only and not exposed in read response', async () => {
  const pair = await paired('push');
  const result = await api.registerPush('token-B', pair, 'fixture-push-token', true);
  assert.equal(result.code, 'OK');
  const targets = [...table('PairPushTarget').values()].filter(e => e.row.pairId === pair);
  assert.equal(targets.length, 1); assert.equal(targets[0].row.memberUid, result.myUid);
  assert.equal((await api.registerPush('token-C', pair, 'stolen', true)).code, 'FORBIDDEN');
  assert.ok(!JSON.stringify(await api.read('token-A', pair)).includes('fixture-push-token'));
});
await test('cancel is terminal and cannot be revived', async () => {
  const pair = await paired('cancel'); await proposed(pair);
  await api.mutate('token-B', mutation(pair, 'plan-one', 'yes', 'ACCEPT', 1));
  assert.equal((await api.mutate('token-A', mutation(pair, 'plan-one', 'cancel', 'CANCEL', 2))).plan.state, 'CANCELLED');
  assert.equal((await api.mutate('token-B', mutation(pair, 'plan-one', 'revive', 'ACCEPT', 3))).code, 'STATE_CONFLICT');
});
await test('secure unpair deletes all children and fences old writes', async () => {
  const pair = await paired('unpair'); await proposed(pair);
  await api.registerPush('token-B', pair, 'fixture', true);
  assert.equal((await api.unpair('token-C', pair)).code, 'FORBIDDEN');
  assert.equal((await api.unpair('token-A', pair)).code, 'OK');
  for (const name of ['PairDatePlan', 'PairPlanRequest', 'PairPlanOutbox', 'PairPushTarget']) {
    assert.equal([...table(name).values()].filter(e => e.row.pairId === pair).length, 0);
  }
  assert.equal((await api.read('token-B', pair)).code, 'SESSION_REVOKED');
  assert.equal((await api.mutate('token-B', mutation(pair, 'p', 'late', 'PROPOSE', 0, envelope()))).code, 'SESSION_REVOKED');
  assert.equal((await api.unpair('token-B', pair)).code, 'OK');
});
await test('unpair failure preserves all credentials and children', async () => {
  const pair = await paired('unpair-fail'); await proposed(pair);
  failCommit = true; assert.equal((await api.unpair('token-A', pair)).code, 'RESULT_UNKNOWN'); failCommit = false;
  assert.equal((await api.pairStatus('token-B', pair)).status, 'ACTIVE');
  assert.equal((await api.read('token-B', pair)).plans.length, 1);
});
await test('bounded request backlog refuses a write without losing existing plans', async () => {
  const pair = await paired('backlog'); await proposed(pair);
  for (let i = 0; i < 200; i++) {
    const row = new models.PairPlanRequest(); row.setId('backlog-' + pair + '-' + i); row.setPairId(pair);
    table('PairPlanRequest').set(row.id, { row, epoch: ++epoch });
  }
  assert.equal((await api.mutate('token-B', mutation(pair, 'plan-one', 'over-limit', 'ACCEPT', 1))).code, 'BACKLOG_FULL');
  assert.equal((await api.read('token-A', pair)).plans[0].state, 'PENDING');
});
await test('oversized cleanup never truncates deletion or clears its authorization', async () => {
  const pair = await paired('cleanup-size'); await proposed(pair);
  const entry = [...table('PairPlanRequest').values()].find(e => e.row.pairId === pair);
  entry.row.response = 'x'.repeat(1500001); entry.epoch = ++epoch;
  assert.equal((await api.unpair('token-A', pair)).code, 'CLEANUP_REQUIRED');
  assert.equal((await api.pairStatus('token-B', pair)).status, 'ACTIVE');
  assert.equal((await api.read('token-B', pair)).plans.length, 1);
});
await test('unpair versus acceptance cannot leave active children in a revoked pair', async () => {
  const pair = await paired('unpair-race'); await proposed(pair);
  await Promise.all([api.unpair('token-A', pair), api.mutate('token-B', mutation(pair, 'plan-one', 'race-accept', 'ACCEPT', 1))]);
  const status = await api.pairStatus('token-A', pair);
  if (status.code !== 'SESSION_REVOKED') assert.equal((await api.unpair('token-A', pair)).code, 'OK');
  for (const name of ['PairDatePlan', 'PairPlanRequest', 'PairPlanOutbox', 'PairPushTarget']) {
    assert.equal([...table(name).values()].filter(e => e.row.pairId === pair).length, 0);
  }
});
await test('receipt lookup is read-only, authenticated and tied to the exact original wire', async () => {
  const pair = await paired('receipt-query');
  const input = mutation(pair, 'plan-one', 'query', 'PROPOSE', 0, envelope());
  const before = epoch;
  assert.equal((await api.requestStatus('token-A', input)).code, 'REQUEST_NOT_COMMITTED');
  assert.equal(epoch, before);
  const committed = await api.mutate('token-A', input);
  const after = epoch;
  assert.deepEqual(await api.requestStatus('token-A', input), committed);
  assert.equal(epoch, after);
  assert.equal((await api.requestStatus('token-C', input)).code, 'FORBIDDEN');
  assert.equal((await api.requestStatus('token-A', mutation(pair, 'plan-one', 'query', 'PROPOSE', 0, envelope(1, 'altered')))).code, 'REQUEST_REUSED');
});
await test('unknown create cleanup never recreates an invitation and fences late creation', async () => {
  const cleaned = await api.cleanupCreate('token-A', 'lost-create-cleanup');
  assert.equal(cleaned.code, 'OK'); assert.equal(cleaned.status, 'REVOKED');
  assert.equal((await api.createPair('token-A', 'lost-create-cleanup', key, 1)).code, 'REQUEST_REUSED');
  const created = await api.createPair('token-A', 'existing-create-cleanup', key, 1);
  assert.equal((await api.cleanupCreate('token-A', 'existing-create-cleanup')).pairId, created.pairId);
  assert.equal((await api.pairStatus('token-A', created.pairId)).code, 'SESSION_REVOKED');
  assert.equal((await api.cleanupCreate('invalid', 'never-auth')).code, 'AUTH_REJECTED');
});
await test('partner binding proof is immutable and exposed only to the authenticated other member', async () => {
  const made = await api.createPair('token-A', 'linked-channel', key, 1, 'creator-encrypted-proof');
  const joined = await api.joinPair('token-B', made.inviteCode, key, 1, 'recipient-encrypted-proof');
  assert.equal(joined.peerLink, 'creator-encrypted-proof');
  assert.equal((await api.pairStatus('token-A', made.pairId)).peerLink, 'recipient-encrypted-proof');
  assert.equal((await api.createPair('token-A', 'linked-channel', key, 1, 'altered-proof')).code, 'REQUEST_REUSED');
  assert.equal((await api.joinPair('token-B', made.inviteCode, key, 1, 'altered-proof')).code, 'CODE_EXPIRED');
  assert.equal((await api.pairStatus('token-C', made.pairId)).code, 'FORBIDDEN');
});
await test('push account chunks preserve the private key and support the original full JSON', async () => {
  const { readPushAccount } = load('push-account');
  const keys = generateKeyPairSync('rsa', { modulusLength: 2048 });
  const account = { project_id: '123', key_id: 'kid-chunk-test', sub_account: 'service-chunk-sub',
    private_key: keys.privateKey.export({ format: 'pem', type: 'pkcs8' }).toString() };
  const json = JSON.stringify(account); const parts = json.match(/[\s\S]{1,512}/g);
  const chunked = { FORTWO_PUSH_SERVICE_ACCOUNT_PARTS: String(parts.length) };
  parts.forEach((part, i) => { chunked['FORTWO_PUSH_SERVICE_ACCOUNT_' + (i + 1)] = part; });
  assert.deepEqual(readPushAccount(chunked), account);
  assert.deepEqual(readPushAccount({ FORTWO_PUSH_SERVICE_ACCOUNT: json }), account);
  const jwt = load('push').serviceJwt(readPushAccount(chunked), 100);
  const [head, body, signature] = jwt.split('.');
  assert.ok(verify('sha256', Buffer.from(head + '.' + body), { key: keys.publicKey,
    padding: constants.RSA_PKCS1_PSS_PADDING, saltLength: 32 }, Buffer.from(signature, 'base64url')));
});
await test('push account configuration rejects partial, mixed and malformed settings without exposing input', async () => {
  const { readPushAccount } = load('push-account');
  const valid = JSON.stringify({ project_id: '123', key_id: 'test', sub_account: 'test',
    private_key: '-----BEGIN PRIVATE KEY-----\nfixture-not-real\n-----END PRIVATE KEY-----\n' });
  const chunked = { FORTWO_PUSH_SERVICE_ACCOUNT_PARTS: '1', FORTWO_PUSH_SERVICE_ACCOUNT_1: valid };
  const bad = [ {}, { FORTWO_PUSH_SERVICE_ACCOUNT: 'private-invalid-input' },
    { ...chunked, FORTWO_PUSH_SERVICE_ACCOUNT: valid },
    { ...chunked, FORTWO_PUSH_SERVICE_ACCOUNT_PARTS: '2' },
    { ...chunked, FORTWO_PUSH_SERVICE_ACCOUNT_PARTS: '01' },
    { ...chunked, FORTWO_PUSH_SERVICE_ACCOUNT_PARTS: '33' },
    { ...chunked, FORTWO_PUSH_SERVICE_ACCOUNT_2: 'unexpected' },
    { ...chunked, FORTWO_PUSH_SERVICE_ACCOUNT_01: 'unexpected' },
    { FORTWO_PUSH_SERVICE_ACCOUNT_1: valid },
    { ...chunked, FORTWO_PUSH_SERVICE_ACCOUNT_1: '' },
    { ...chunked, FORTWO_PUSH_SERVICE_ACCOUNT_1: 'x'.repeat(513) },
    { FORTWO_PUSH_SERVICE_ACCOUNT: 'x'.repeat(16385) },
    ...[null, [], { project_id: 123 }, { project_id: '123', key_id: 'test', sub_account: 'test', private_key: 12 }]
      .map(value => ({ FORTWO_PUSH_SERVICE_ACCOUNT: JSON.stringify(value) })) ];
  for (const config of bad) assert.throws(() => readPushAccount(config), error => error.message === 'PUSH_CONFIG_INVALID');
});
await test('worker account context replaces warm-instance chunks rather than filling missing parts with old secrets', async () => {
  const { installPushAccountEnvironment, readPushAccount } = load('push-account');
  const saved = { ...env };
  try {
    env.FORTWO_PUSH_SERVICE_ACCOUNT = 'old-full-json';
    env.FORTWO_PUSH_SERVICE_ACCOUNT_2 = 'old-private-fragment';
    installPushAccountEnvironment({ FORTWO_PUSH_SERVICE_ACCOUNT_PARTS: '2', FORTWO_PUSH_SERVICE_ACCOUNT_1: '{' });
    assert.equal(env.FORTWO_PUSH_SERVICE_ACCOUNT, undefined);
    assert.equal(env.FORTWO_PUSH_SERVICE_ACCOUNT_2, undefined);
    assert.throws(() => readPushAccount(env), /PUSH_CONFIG_INVALID/);
    installPushAccountEnvironment({ FORTWO_AUTH_PROJECT_ID: 'unrelated' });
    assert.equal(env.FORTWO_PUSH_SERVICE_ACCOUNT_1, '{');
    const json = JSON.stringify({ project_id: '123', key_id: 'test', sub_account: 'test',
      private_key: '-----BEGIN PRIVATE KEY-----\nfixture-not-real\n-----END PRIVATE KEY-----\n' });
    installPushAccountEnvironment({ FORTWO_PUSH_SERVICE_ACCOUNT: json });
    assert.equal(env.FORTWO_PUSH_SERVICE_ACCOUNT_PARTS, undefined);
    assert.equal(readPushAccount(env).project_id, '123');
  } finally {
    for (const name of Object.keys(env)) delete env[name]; Object.assign(env, saved);
  }
});
await test('push uses PS256 service-account JWT and lockscreen copy contains no plan details', async () => {
  const { serviceJwt, notification } = load('push');
  const keys = generateKeyPairSync('rsa', { modulusLength: 2048 });
  const account = { project_id: '123', key_id: 'kid-test', sub_account: 'service-sub',
    private_key: keys.privateKey.export({ format: 'pem', type: 'pkcs8' }).toString() };
  const jwt = serviceJwt(account, 100); const [head, body, signature] = jwt.split('.');
  assert.equal(JSON.parse(Buffer.from(head, 'base64url')).alg, 'PS256');
  const claims = JSON.parse(Buffer.from(body, 'base64url')); assert.equal(claims.exp - claims.iat, 3600);
  assert.equal(claims.aud, 'https://oauth-login.cloud.huawei.com/oauth2/v3/token');
  assert.ok(verify('sha256', Buffer.from(head + '.' + body), { key: keys.publicKey,
    padding: constants.RSA_PKCS1_PSS_PADDING, saltLength: 32 }, Buffer.from(signature, 'base64url')));
  const message = JSON.stringify(notification('PROPOSE'));
  assert.ok(message.includes('WORK')); assert.ok(!message.includes('planId')); assert.ok(!message.includes('token'));
  const alert = notification('PROPOSE', 'a'.repeat(64));
  assert.equal(alert.payload.notification.appMessageId, 'a'.repeat(64));
  assert.equal(alert.pushOptions.collapseKey, 1);
  assert.ok(alert.payload.notification.notifyId >= 0);
});
await test('push lease serializes concurrent delivery and provider ACK alone marks SENT', async () => {
  const pair = await paired('push-serial'); await proposed(pair);
  assert.equal((await api.registerPush('token-B', pair, 'private-token-B', true)).code, 'OK');
  const { dispatch } = load('push'); let count = 0;
  const sender = { async send(token, kind) { assert.equal(token, 'private-token-B'); assert.equal(kind, 'PROPOSE'); count++; return true; } };
  env.FORTWO_ENABLE_PLAN_PUSH = 'true';
  try { await Promise.all([dispatch(pair, sender), dispatch(pair, sender)]); assert.equal(count, 1);
    assert.equal([...table('PairPlanOutbox').values()].find(e => e.row.pairId === pair).row.status, 'SENT'); }
  finally { env.FORTWO_ENABLE_PLAN_PUSH = 'false'; }
});
await test('push timeout retains a leased event without altering the authoritative plan', async () => {
  const pair = await paired('push-unknown'); await proposed(pair);
  await api.registerPush('token-B', pair, 'private-token-B', true);
  const { dispatch } = load('push'); let calls = 0;
  const sender = { async send() { calls++; throw new Error('fixture-secret'); } };
  env.FORTWO_ENABLE_PLAN_PUSH = 'true';
  try { assert.equal(await dispatch(pair, sender), 0); assert.equal(await dispatch(pair, sender), 0);
    assert.equal(calls, 1);
    const event = [...table('PairPlanOutbox').values()].find(e => e.row.pairId === pair).row;
    assert.match(event.status, /^SENDING:/); event.status = event.status.replace(/SENDING:\d+:/, 'SENDING:0:');
    assert.equal(await dispatch(pair, { async send() { return true; } }), 1);
    assert.equal((await api.read('token-A', pair)).plans[0].state, 'PENDING'); }
  finally { env.FORTWO_ENABLE_PLAN_PUSH = 'false'; }
});
await test('push stops after three attempts without consuming unlimited project quota', async () => {
  const pair = await paired('push-budget'); await proposed(pair);
  await api.registerPush('token-B', pair, 'private-token-B', true);
  const { dispatch } = load('push'); let calls = 0;
  env.FORTWO_ENABLE_PLAN_PUSH = 'true';
  try {
    for (let attempt = 0; attempt < 3; attempt++) {
      await dispatch(pair, { async send() { calls++; return false; } });
      const event = [...table('PairPlanOutbox').values()].find(e => e.row.pairId === pair).row;
      if (attempt < 2) event.status = event.status.replace(/SENDING:\d+:/, 'SENDING:0:');
    }
    await dispatch(pair, { async send() { calls++; return false; } }); assert.equal(calls, 3);
    assert.equal([...table('PairPlanOutbox').values()].find(e => e.row.pairId === pair).row.status, 'FAILED');
  } finally { env.FORTWO_ENABLE_PLAN_PUSH = 'false'; }
});
await test('push skips stale versions, disabled recipients and revoked connections', async () => {
  const pair = await paired('push-stale'); await proposed(pair);
  await api.mutate('token-B', mutation(pair, 'plan-one', 'accept-stale', 'ACCEPT', 1));
  const { dispatch } = load('push'); let calls = 0;
  env.FORTWO_ENABLE_PLAN_PUSH = 'true';
  try { assert.equal(await dispatch(pair, { async send() { calls++; return true; } }), 0); assert.equal(calls, 0);
    await dispatch(pair, { async send() { calls++; return true; } });
    assert.equal([...table('PairPlanOutbox').values()].filter(e => e.row.pairId === pair && e.row.status === 'SKIPPED').length, 2);
    await api.unpair('token-A', pair); assert.equal(await dispatch(pair, { async send() { calls++; return true; } }), 0); }
  finally { env.FORTWO_ENABLE_PLAN_PUSH = 'false'; }
});
await test('timer entry returns through the AGC callback without initiating anonymous authentication', async () => {
  const { handler } = load('dispatch'); let calls = 0;
  const secret = 'test-worker-secret-' + 'a'.repeat(32);
  const rejected = await new Promise(resolve => handler({}, { env: { FORTWO_PLAN_DISPATCH_SECRET: secret } }, resolve));
  assert.equal(rejected.code, 'DISPATCH_REJECTED');
  const malformed = await new Promise(resolve => handler({ dispatchSecret: '中'.repeat(secret.length) }, {}, resolve));
  assert.equal(malformed.code, 'DISPATCH_REJECTED');
  const result = await new Promise(resolve => handler({ data: { dispatchSecret: secret } },
    { env: { FORTWO_ENABLE_PLAN_PUSH: 'false' } }, value => {
    calls++; resolve(value);
  }));
  assert.equal(result.code, 'OK'); assert.equal(result.providerAccepted, 0); assert.equal(calls, 1);
});
await test('worker uses the invocation logger and logs completion before callback without secrets', async () => {
  const { handler } = load('dispatch'); const saved = { ...env }; const previous = globalThis.logger;
  const logs = []; const globalLogs = []; const secret = 'worker-fixture-' + 'c'.repeat(40);
  globalThis.logger = { info: line => globalLogs.push(line) };
  try {
    const result = await new Promise(resolve => handler({ dispatchSecret: secret, token: 'fixture-private-token' }, { env: {
      FORTWO_PLAN_DISPATCH_SECRET: secret, FORTWO_ENABLE_PLAN_PUSH: 'false'
    } }, value => {
      assert.equal(logs.at(-1).stage, 'finish'); resolve(value);
    }, { info: line => logs.push(JSON.parse(line)) }));
    assert.deepEqual(result, { code: 'OK', providerAccepted: 0 });
    assert.deepEqual(logs.map(row => row.stage), ['start', 'auth', 'dispatch', 'finish']);
    assert.equal(logs.at(-1).code, 'OK'); assert.equal(logs.at(-1).providerAccepted, 0);
    assert.ok(logs.every(row => row.tag === 'FORTWO_PLAN_PUSH' && row.build === '2026-10-10-worker-diag1'));
    assert.equal(logs[0].inputShape, 'direct'); assert.equal(logs[0].pushEnabled, false);
    assert.equal(globalLogs.length, 0); assert.ok(!JSON.stringify(logs).includes(secret));
    assert.ok(!JSON.stringify(logs).includes('fixture-private-token'));
  } finally {
    for (const name of Object.keys(env)) delete env[name]; Object.assign(env, saved);
    if (previous === undefined) delete globalThis.logger; else globalThis.logger = previous;
  }
});
await test('worker global logger records rejected input without SDK access or raw payloads', async () => {
  const { handler } = load('dispatch'); const saved = { ...env }; const previous = globalThis.logger;
  const logs = []; const before = dbCalls; globalThis.logger = { info: line => logs.push(JSON.parse(line)) };
  try {
    const result = await new Promise(resolve => handler({ data: '{private-broken-fixture' }, { env: {
      FORTWO_PLAN_DISPATCH_SECRET: 'worker-fixture-' + 'd'.repeat(40)
    } }, resolve));
    assert.equal(result.code, 'DISPATCH_REJECTED'); assert.equal(dbCalls, before);
    assert.deepEqual(logs.map(row => row.stage), ['start', 'auth']);
    assert.equal(logs.at(-1).code, 'DISPATCH_REJECTED'); assert.equal(logs[0].inputShape, 'invalid');
    assert.ok(!JSON.stringify(logs).includes('private-broken-fixture'));
  } finally {
    for (const name of Object.keys(env)) delete env[name]; Object.assign(env, saved);
    if (previous === undefined) delete globalThis.logger; else globalThis.logger = previous;
  }
});
await test('worker accepts bounded direct and scheduler envelopes with unchanged task authentication', async () => {
  const { handler } = load('dispatch'); const saved = { ...env }; const secret = 'worker-fixture-' + 'e'.repeat(40);
  const payload = { dispatchSecret: secret }; const json = JSON.stringify(payload);
  try {
    for (const [input, shape] of [[payload, 'direct'], [json, 'string'], [{ data: payload }, 'data'],
      [{ data: json }, 'data'], [{ userData: payload }, 'userData'], [{ userData: json }, 'userData'],
      [{ user_event: payload }, 'user_event'], [{ user_event: json }, 'user_event']]) {
      const logs = [];
      const result = await new Promise(resolve => handler(input, { env: {
        FORTWO_PLAN_DISPATCH_SECRET: secret, FORTWO_ENABLE_PLAN_PUSH: 'false'
      } }, resolve, { info: line => logs.push(JSON.parse(line)) }));
      assert.equal(result.code, 'OK'); assert.equal(logs[0].inputShape, shape);
      assert.ok(!JSON.stringify(logs).includes(secret));
    }
  } finally { for (const name of Object.keys(env)) delete env[name]; Object.assign(env, saved); }
});
await test('worker rejects malformed, ambiguous and oversized inputs before dispatch', async () => {
  const { handler } = load('dispatch'); const saved = { ...env }; const before = dbCalls;
  const secret = 'worker-fixture-' + 'f'.repeat(40); const payload = { dispatchSecret: secret };
  try {
    for (const input of [null, [], 'x'.repeat(4097), '{private-broken-fixture', { data: [] },
      { data: JSON.stringify([payload]) }, { data: null }, { data: JSON.stringify({ data: payload }) },
      { dispatchSecret: secret, data: payload }, { data: payload, userData: payload },
      { request: payload }, { user_event: { dispatchSecret: 'wrong' } }]) {
      const logs = [];
      const result = await new Promise(resolve => handler(input, { env: {
        FORTWO_PLAN_DISPATCH_SECRET: secret, FORTWO_ENABLE_PLAN_PUSH: 'true'
      } }, resolve, { info: line => logs.push(JSON.parse(line)) }));
      assert.equal(result.code, 'DISPATCH_REJECTED'); assert.equal(dbCalls, before);
      assert.ok(logs.every(row => row.stage !== 'dispatch'));
      assert.ok(!JSON.stringify(logs).includes(secret));
    }
  } finally { for (const name of Object.keys(env)) delete env[name]; Object.assign(env, saved); }
});
await test('worker loggers remain invocation local and logging failure cannot change callbacks', async () => {
  const { handler } = load('dispatch'); const saved = { ...env }; const secret = 'worker-fixture-' + 'g'.repeat(40);
  try {
    const first = []; const second = [];
    const invoke = logger => new Promise(resolve => handler({ dispatchSecret: secret }, { env: {
      FORTWO_PLAN_DISPATCH_SECRET: secret, FORTWO_ENABLE_PLAN_PUSH: 'false'
    } }, resolve, logger));
    await Promise.all([invoke({ info: line => first.push(JSON.parse(line)) }),
      invoke({ info: line => second.push(JSON.parse(line)) })]);
    assert.equal(first.length, 4); assert.equal(second.length, 4);
    assert.equal((await invoke({ info() { throw new Error('private-logger-error'); } })).code, 'OK');
  } finally { for (const name of Object.keys(env)) delete env[name]; Object.assign(env, saved); }
});
await test('worker reports sync and async dispatch errors without logging their contents', async () => {
  const { handler } = load('dispatch'); const push = load('push'); const original = push.dispatch; const saved = { ...env };
  const secret = 'worker-fixture-' + 'h'.repeat(40);
  try {
    for (const asyncFailure of [false, true]) {
      push.dispatch = () => { const error = new Error('private-provider-credential');
        if (asyncFailure) return Promise.reject(error); throw error; };
      const logs = [];
      const result = await new Promise(resolve => handler({ dispatchSecret: secret }, { env: {
        FORTWO_PLAN_DISPATCH_SECRET: secret, FORTWO_ENABLE_PLAN_PUSH: 'false'
      } }, resolve, { info: line => logs.push(JSON.parse(line)) }));
      assert.equal(result.code, 'PUSH_DEFERRED'); assert.equal(logs.at(-1).code, 'PUSH_DEFERRED');
      assert.ok(!JSON.stringify(logs).includes('private-provider-credential'));
    }
  } finally { push.dispatch = original; for (const name of Object.keys(env)) delete env[name]; Object.assign(env, saved); }
});
await test('worker validates account chunks before database access and reports only fixed configuration codes', async () => {
  const { handler } = load('dispatch'); const saved = { ...env }; const calls = dbCalls;
  const secret = 'test-worker-secret-' + 'b'.repeat(32);
  try {
    const result = await new Promise(resolve => handler({ dispatchSecret: secret }, { env: {
      FORTWO_ENABLE_SHARED_PLAN_V1: 'true', FORTWO_ENABLE_PLAN_PUSH: 'true', FORTWO_PLAN_DISPATCH_SECRET: secret,
      FORTWO_PUSH_SERVICE_ACCOUNT_PARTS: '2', FORTWO_PUSH_SERVICE_ACCOUNT_1: 'private-invalid-fragment'
    } }, resolve));
    assert.equal(result.code, 'PUSH_CONFIG_INVALID'); assert.equal(dbCalls, calls);
    assert.equal(env.FORTWO_PUSH_SERVICE_ACCOUNT_1, 'private-invalid-fragment');
    const keys = generateKeyPairSync('rsa', { modulusLength: 2048 });
    const json = JSON.stringify({ project_id: '123', key_id: 'worker-test', sub_account: 'worker-sub',
      private_key: keys.privateKey.export({ format: 'pem', type: 'pkcs8' }).toString() });
    const mismatch = await new Promise(resolve => handler({ dispatchSecret: secret }, { env: {
      FORTWO_PUSH_SERVICE_ACCOUNT: json, FORTWO_AUTH_PROJECT_ID: '456'
    } }, resolve));
    assert.equal(mismatch.code, 'PUSH_PROJECT_MISMATCH'); assert.equal(dbCalls, calls);
  } finally {
    for (const name of Object.keys(env)) delete env[name]; Object.assign(env, saved);
  }
});
await test('handlers tolerate cloud framework calling a detached method', async () => {
  const method = api.createPair;
  assert.equal((await method('token-A', 'detached-method', key, 1)).code, 'OK');
});
await test('CAS counterfactual produces two winners, proving race assertion is meaningful', async () => {
  const pair = await paired('counterfactual'); await proposed(pair);
  ignoreCas = true;
  const result = await Promise.all([
    api.mutate('token-A', mutation(pair, 'plan-one', 'wa', 'WITHDRAW', 1)),
    api.mutate('token-B', mutation(pair, 'plan-one', 'yb', 'ACCEPT', 1))
  ]);
  ignoreCas = false; assert.equal(result.filter(r => r.code === 'OK').length, 2);
});
await test('business Error subclass survives the deployment transpilation target', async () => {
  const { Rejection } = load('identity'); const error = new Rejection('FORBIDDEN');
  assert.ok(error instanceof Error); assert.ok(error instanceof Rejection);
});
await test('auth diagnostic stages distinguish config, audience and SDK rejection safely', async () => {
  const { guarded, actor } = load('identity'); const old = globalThis.logger; const logs = [];
  globalThis.logger = { error: line => logs.push(JSON.parse(line)) };
  try {
    const oldGate = env.FORTWO_ENABLE_SHARED_PLAN_V1;
    env.FORTWO_ENABLE_SHARED_PLAN_V1 = 'false';
    try {
      assert.equal((await guarded(ctx => actor('token-A', ctx), 'mutate')).code, 'FEATURE_DISABLED');
      assert.equal(logs.at(-1).stage, 'auth.featureGate');
    } finally { env.FORTWO_ENABLE_SHARED_PLAN_V1 = oldGate; }
    assert.equal((await guarded(ctx => actor('wrong-project', ctx), 'mutate')).code, 'AUTH_REJECTED');
    assert.equal(logs.at(-1).stage, 'auth.audience');
    assert.equal((await guarded(ctx => actor('invalid', ctx), 'mutate')).code, 'AUTH_REJECTED');
    assert.equal(logs.at(-1).stage, 'auth.sdkVerify');
    assert.equal((await guarded(ctx => actor('expired', ctx), 'mutate')).code, 'AUTH_REJECTED');
    assert.equal(logs.at(-1).stage, 'auth.expiry');
  } finally { if (old === undefined) delete globalThis.logger; else globalThis.logger = old; }
});
await test('diagnostics correlate failures without exposing raw error secrets', async () => {
  const { guarded, Rejection } = load('identity');
  const logs = []; const old = globalThis.logger;
  globalThis.logger = { error: line => logs.push(JSON.parse(line)) };
  try {
    const error = Object.assign(new TypeError('token-A PRIVATE-KEY PLAN-TITLE'), { code: 123, errno: 456 });
    error.stack = 'TypeError: token-A PRIVATE-KEY PLAN-TITLE\n    at fn (/secret/path/service.ts:12:34)\n    at token-A (/secrets/unknown.js:1:2)';
    const result = await guarded(async ctx => { ctx.stage = 'mutate.tx.transition'; throw error; }, 'mutate');
    assert.equal(result.code, 'RESULT_UNKNOWN'); assert.equal(result.retryable, true);
    assert.match(result.diagnosticId, /^[a-f0-9-]{36}$/);
    assert.equal(logs[0].diagnosticId, result.diagnosticId);
    assert.equal(logs[0].category, 'TYPE_ERROR'); assert.equal(logs[0].sdkCode, 123);
    assert.equal(logs[0].stage, 'mutate.tx.transition'); assert.deepEqual(logs[0].frames, ['service:12:34']);
    assert.ok(!/token-A|PRIVATE-KEY|PLAN-TITLE|secret\/path|unknown.js/.test(JSON.stringify({ logs, result })));
    const rejected = await guarded(async () => { throw new Rejection('FORBIDDEN'); }, 'mutate');
    assert.equal(rejected.code, 'FORBIDDEN'); assert.equal(rejected.retryable, false);
    assert.equal(logs[1].category, 'BUSINESS_REJECTION');
  } finally { if (old === undefined) delete globalThis.logger; else globalThis.logger = old; }
});
await test('a failing logger cannot turn business rejection into unknown or throw', async () => {
  const { guarded, Rejection } = load('identity'); const old = globalThis.logger;
  globalThis.logger = { error: () => { throw new Error('logger unavailable'); } };
  try {
    assert.equal((await guarded(async () => { throw new Rejection('FORBIDDEN'); }, 'mutate')).code, 'FORBIDDEN');
  } finally { if (old === undefined) delete globalThis.logger; else globalThis.logger = old; }
});
await test('closing an uncommitted request fences a late mutate and is idempotent', async () => {
  const pair = await paired('close-uncommitted');
  const cmd = mutation(pair, 'close-plan', 'close-request', 'PROPOSE', 0, envelope());
  assert.equal((await api.closeRequest('token-A', cmd)).code, 'REQUEST_CLOSED');
  assert.equal((await api.closeRequest('token-A', cmd)).code, 'REQUEST_CLOSED');
  assert.equal((await api.requestStatus('token-A', cmd)).code, 'REQUEST_CLOSED');
  assert.equal((await api.mutate('token-A', cmd)).code, 'REQUEST_CLOSED');
  assert.equal((await api.read('token-B', pair)).plans.length, 0);
  assert.equal([...table('PairPlanOutbox').values()].filter(e => e.row.pairId === pair).length, 0);
  const altered = JSON.parse(cmd); altered.envelope = envelope(1, 'changed');
  assert.equal((await api.closeRequest('token-A', JSON.stringify(altered))).code, 'REQUEST_REUSED');
  assert.equal((await api.closeRequest('token-C', cmd)).code, 'FORBIDDEN');
});
await test('closing an already committed request restores its receipt without cancelling the plan', async () => {
  const pair = await paired('close-committed'); const created = await proposed(pair);
  const cmd = mutation(pair, 'plan-one', 'propose-one', 'PROPOSE', 0, envelope());
  assert.deepEqual(await api.closeRequest('token-A', cmd), created);
  assert.equal((await api.read('token-B', pair)).plans[0].state, 'PENDING');
});
await test('a simultaneous close and mutate can only commit one immutable verdict', async () => {
  for (const reverse of [false, true]) {
    const pair = await paired('close-race-' + reverse); const cmd = mutation(pair, 'race-plan', 'race-request', 'PROPOSE', 0, envelope());
    const results = await Promise.all(reverse
      ? [api.mutate('token-A', cmd), api.closeRequest('token-A', cmd)]
      : [api.closeRequest('token-A', cmd), api.mutate('token-A', cmd)]);
    const receipt = await api.requestStatus('token-A', cmd);
    assert.ok(['OK', 'REQUEST_CLOSED'].includes(receipt.code));
    assert.ok(!results.some(r => r.code === 'OK') || !results.some(r => r.code === 'REQUEST_CLOSED'),
      'cannot acknowledge closed while a concurrent mutation also succeeds');
    assert.deepEqual(await api.closeRequest('token-A', cmd), receipt);
    assert.deepEqual(await api.mutate('token-A', cmd), receipt);
    assert.equal((await api.read('token-B', pair)).plans.length, receipt.code === 'OK' ? 1 : 0);
  }
});
await test('close response loss preserves the negative receipt for subsequent recovery', async () => {
  const pair = await paired('close-lost-response'); const cmd = mutation(pair, 'none', 'closed', 'PROPOSE', 0, envelope());
  loseCommitResponse = true;
  assert.equal((await api.closeRequest('token-A', cmd)).code, 'RESULT_UNKNOWN');
  assert.equal((await api.requestStatus('token-A', cmd)).code, 'REQUEST_CLOSED');
  assert.equal((await api.closeRequest('token-A', cmd)).code, 'REQUEST_CLOSED');
  assert.equal((await api.mutate('token-A', cmd)).code, 'REQUEST_CLOSED');
});
await test('without binding CAS a close/mutate race has contradictory successes (counterfactual)', async () => {
  const pair = await paired('close-no-cas'); const cmd = mutation(pair, 'none', 'closed', 'PROPOSE', 0, envelope());
  let results;
  ignoreCas = true;
  try { results = await Promise.all([api.closeRequest('token-A', cmd), api.mutate('token-A', cmd)]); }
  finally { ignoreCas = false; }
  assert.ok(results.some(r => r.code === 'OK') && results.some(r => r.code === 'REQUEST_CLOSED'));
});
console.log(`dateplan contract: ${passed} passed, 0 failed (offline; not a deployment receipt)`);
// Shared isolated production harness; importing runs the existing regression contract first.
export { api, env, tables, table, paired, proposed, mutation, envelope, load, models, sdkRead };
