import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { createRequire } from 'node:module';

const require = createRequire(import.meta.url);
const repo = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '../../..');
const harmonyRoot = path.dirname(repo);
const functionDir = path.join(repo, 'experiments/shared-plan-preflight/cloudfunctions/sharedplanpreflight');
const tsCandidates = [
  path.join(harmonyRoot, 'FortwoCloud/CloudProgram/node_modules/typescript'),
  path.join(harmonyRoot, 'CloudDevSpikeOfficial/CloudProgram/node_modules/typescript'),
  'D:/local/DevEcoStudio/tools/hvigor/hvigor/node_modules/typescript'
];
const tsPath = tsCandidates.find(candidate => fs.existsSync(path.join(candidate, 'lib/typescript.js')));
assert.ok(tsPath, 'Install/use an existing local TypeScript compiler before running this offline probe');
const ts = require(tsPath);
const sdkPath = path.join(harmonyRoot, 'FortwoCloud/CloudProgram/cloudfunctions/pairing/node_modules/@hw-agconnect/cloud-server');
const nodeTypes = path.join(harmonyRoot, 'FortwoCloud/CloudProgram/node_modules/@types');
assert.ok(fs.existsSync(path.join(sdkPath, 'index.d.ts')), 'Real local Server SDK declarations are required');
assert.ok(fs.existsSync(path.join(nodeTypes, 'node/index.d.ts')), 'Real local Node declarations are required');

const program = ts.createProgram(['authProbe.ts', 'sharedplanpreflight.ts'].map(name => path.join(functionDir, name)), {
  target: ts.ScriptTarget.ES2020, module: ts.ModuleKind.CommonJS,
  moduleResolution: ts.ModuleResolutionKind.NodeJs, strict: true, noEmit: true,
  skipLibCheck: true, types: ['node'], typeRoots: [nodeTypes],
  baseUrl: repo, paths: { '@hw-agconnect/cloud-server': [path.join(sdkPath, 'index.d.ts')] }
});
const diagnostics = ts.getPreEmitDiagnostics(program);
if (diagnostics.length !== 0) {
  process.stderr.write(ts.formatDiagnosticsWithColorAndContext(diagnostics, {
    getCanonicalFileName: name => name, getCurrentDirectory: () => repo, getNewLine: () => '\n'
  }));
  process.exit(1);
}
console.log('SDK typecheck: PASS (noEmit; actual Server SDK 1.0.5 declarations)');

function load(name, dependency, runtimeProcess = process) {
  const fileName = path.join(functionDir, name);
  const js = ts.transpileModule(fs.readFileSync(fileName, 'utf8'), {
    fileName, compilerOptions: { target: ts.ScriptTarget.ES2020, module: ts.ModuleKind.CommonJS }
  }).outputText;
  const module = { exports: {} };
  new Function('require', 'module', 'exports', 'process', js)(dependency, module, module.exports, runtimeProcess);
  return module.exports;
}
const pure = load('authProbe.ts', require);
const { inspectVerifiedToken } = pure;
const model = require(path.join(functionDir, 'PlanCasProbe.js'));
const cas = load('casProbe.ts', name => {
  if (name === './PlanCasProbe') return model;
  return require(name);
});
let passed = 0;
async function test(name, fn) {
  await fn();
  passed++;
  console.log(`PASS ${name}`);
}
const projectId = 'isolated-project';
const secret = 'test-access-token-not-for-production';
const claims = (aud = projectId, sub = 'subject-A', exp = Math.floor(Date.now() / 1000) + 600) => ({
  getAud: () => aud, getSub: () => sub, getExp: () => exp
});
const good = async () => claims();
function denied(result, code = 'AUTH_REJECTED') {
  assert.equal(result.code, code);
  assert.equal(result.authenticated, false);
  assert.equal(result.sharedPlanReady, false);
  assert.equal(result.subjectFingerprint, '');
}

await test('missing server project refuses before SDK', async () => {
  let calls = 0;
  denied(await inspectVerifiedToken(secret, ' ', async () => { calls++; return claims(); }), 'CONFIG_MISSING');
  assert.equal(calls, 0);
});
await test('empty, non-string and oversized inputs refuse before SDK', async () => {
  let calls = 0;
  for (const input of ['', ' ', null, 12, 'a'.repeat(16385)]) {
    denied(await inspectVerifiedToken(input, projectId, async () => { calls++; return claims(); }), 'BAD_REQUEST');
  }
  assert.equal(calls, 0);
});
await test('SDK rejection never returns sensitive error', async () => {
  const result = await inspectVerifiedToken(secret, projectId, async () => { throw new Error(`sdk detail ${secret}`); });
  denied(result);
  assert.ok(!JSON.stringify(result).includes(secret));
});
await test('wrong project is rejected', async () => {
  denied(await inspectVerifiedToken(secret, projectId, async () => claims('another-project')));
});
await test('empty or absent verified subject is rejected', async () => {
  for (const sub of ['', ' ', undefined]) {
    denied(await inspectVerifiedToken(secret, projectId, async () => ({ ...claims(), getSub: () => sub })));
  }
});
await test('expired, non-numeric and missing expiration is rejected', async () => {
  for (const exp of [0, Math.floor(Date.now() / 1000) - 1, NaN, Infinity, '9000000000', undefined]) {
    denied(await inspectVerifiedToken(secret, projectId, async () => ({ ...claims(), getExp: () => exp })));
  }
});
await test('malformed verifier result is rejected', async () => {
  denied(await inspectVerifiedToken(secret, projectId, async () => null));
});
await test('verified identity succeeds without exposing raw identity or claiming readiness', async () => {
  const result = await inspectVerifiedToken(secret, projectId, good);
  assert.equal(result.code, 'OK');
  assert.equal(result.authenticated, true);
  assert.equal(result.sharedPlanReady, false);
  assert.match(result.subjectFingerprint, /^[a-f0-9]{16}$/);
  assert.ok(!JSON.stringify(result).includes(secret));
  assert.ok(!JSON.stringify(result).includes('subject-A'));
});
await test('same identity is stable; different subject has different fingerprint', async () => {
  const first = await inspectVerifiedToken(secret, projectId, good);
  const again = await inspectVerifiedToken(secret, projectId, good);
  const other = await inspectVerifiedToken(secret, projectId, async () => claims(projectId, 'subject-B'));
  assert.equal(first.subjectFingerprint, again.subjectFingerprint);
  assert.notEqual(first.subjectFingerprint, other.subjectFingerprint);
});

const calls = [];
const fakeSdk = {
  Region: { REGION_CN: 'CN' },
  cloud: { createInstance(config, instance, region) {
    calls.push({ config, instance, region });
    return { auth: () => ({ verifyAccessToken: async params => { calls.push(params); return claims(); } }) };
  } }
};
const entry = load('sharedplanpreflight.ts', name => {
  if (name === '@hw-agconnect/cloud-server') return fakeSdk;
  if (name === './authProbe') return pure;
  if (name === './casProbe') return cas;
  if (name === './PlanCasProbe') return model;
  throw new Error(`Unexpected dependency: ${name}`);
}, { env: { FORTWO_AUTH_PROJECT_ID: projectId } });

await test('real entry invokes server verifier with revocation check and no this', async () => {
  const method = new entry.SharedPlanPreflight().verifyIdentity;
  const result = await method(secret);
  assert.equal(result.code, 'OK');
  assert.deepEqual(calls[0], { config: undefined, instance: 'fortwo-plan-preflight', region: 'CN' });
  assert.deepEqual(calls[1], { accessToken: secret, checkRevoked: true });
});
await test('client extra project argument cannot replace server project', async () => {
  const method = new entry.SharedPlanPreflight().verifyIdentity;
  const result = await method(secret, 'attacker-project');
  assert.equal(result.code, 'OK');
});
await test('cloud entry with missing configuration fails closed', async () => {
  const before = calls.length;
  const unconfigured = load('sharedplanpreflight.ts', name => {
    if (name === './authProbe') return pure;
    if (name === './casProbe') return cas;
    if (name === './PlanCasProbe') return model;
    return fakeSdk;
  }, { env: {} });
  denied(await new unconfigured.SharedPlanPreflight().verifyIdentity(secret), 'CONFIG_MISSING');
  assert.equal(calls.length, before);
});

await test('transaction probe is disabled by default even with valid authentication', async () => {
  const result = await new entry.SharedPlanPreflight().runRace(secret);
  assert.equal(result.code, 'PROBE_DISABLED');
  assert.equal(result.sharedPlanReady, false);
  assert.equal(result.probeId, '');
});

function copyRow(row) {
  const copy = new model.PlanCasProbe();
  copy.setId(row.getId()); copy.setVersion(row.getVersion());
  copy.setState(row.getState()); copy.setCreatedAt(row.getCreatedAt());
  return copy;
}

/** A deliberately explicit simulated database. Passing this is NOT proof of real CloudDB CAS. */
function memoryCollection(mode = 'cas') {
  let stored = null;
  let transactions = 0;
  return {
    get transactions() { return transactions; },
    get stored() { return stored; },
    async insert(row) {
      if (mode === 'insert-error') throw new Error('private database detail');
      stored = copyRow(row);
      return 1;
    },
    query() {
      return { equalTo(field, id) {
        assert.equal(field, 'id');
        return { id, async get() {
          if (mode === 'read-error') throw new Error('private network detail');
          return stored && stored.getId() === id ? [copyRow(stored)] : [];
        } };
      } };
    },
    async runTransaction(operation) {
      transactions++;
      const snapshot = copyRow(stored);
      let next = null;
      const accepted = await operation.apply({
        async executeQuery(query) { assert.equal(query.id, snapshot.getId()); return [snapshot]; },
        executeUpsert(rows) { assert.equal(rows.length, 1); next = copyRow(rows[0]); }
      });
      if (!accepted) return false;
      if (mode === 'commit-error' && next.getState() === 'WITHDRAWN') throw new Error('private SDK error');
      if (mode !== 'no-cas' && stored.getVersion() !== snapshot.getVersion()) return false;
      stored = next;
      return true;
    }
  };
}

await test('overlapping reads with simulated CAS produce one winner and version two', async () => {
  const collection = memoryCollection();
  const result = await cas.probeTransactionRace(collection);
  assert.equal(result.code, 'OK');
  assert.equal(result.overlapObserved, true);
  assert.equal(result.finalVersion, 2);
  assert.equal(result.legs.filter(leg => leg.outcome === 'APPLIED').length, 1);
  assert.equal(result.legs.filter(leg => leg.outcome === 'NOT_COMMITTED').length, 1);
  assert.equal(collection.transactions, 2);
  assert.equal(result.sharedPlanReady, false);
});
await test('a broken query-upsert-like backend is detected, not given a false pass', async () => {
  const result = await cas.probeTransactionRace(memoryCollection('no-cas'));
  assert.equal(result.code, 'RACE_FAILED');
  assert.equal(result.legs.filter(leg => leg.outcome === 'APPLIED').length, 2);
});
await test('SDK or network error is not misclassified as a legitimate CAS loser', async () => {
  const result = await cas.probeTransactionRace(memoryCollection('commit-error'));
  assert.equal(result.code, 'RACE_INCONCLUSIVE');
  assert.equal(result.legs.filter(leg => leg.outcome === 'SDK_ERROR').length, 1);
  assert.ok(!JSON.stringify(result).includes('private SDK error'));
});
await test('missing isolated table stops before either transaction', async () => {
  const collection = memoryCollection('insert-error');
  const result = await cas.probeTransactionRace(collection);
  assert.equal(result.code, 'DB_UNAVAILABLE');
  assert.equal(collection.transactions, 0);
});
await test('final read failure never passes the race', async () => {
  const result = await cas.probeTransactionRace(memoryCollection('read-error'));
  assert.equal(result.code, 'RACE_INCONCLUSIVE');
});
await test('each race inserts a fresh diagnostic row, never resets an existing row', async () => {
  const first = await cas.probeTransactionRace(memoryCollection());
  const next = await cas.probeTransactionRace(memoryCollection());
  assert.notEqual(first.probeId, next.probeId);
  assert.match(first.probeId, /^cas-[a-f0-9-]{36}$/);
});
await test('model fields and permissions exactly match the isolated object definition', async () => {
  const schema = JSON.parse(fs.readFileSync(path.join(repo, 'experiments/shared-plan-preflight/clouddb/objecttype/PlanCasProbe.json'), 'utf8'));
  const reflected = new model.PlanCasProbe();
  assert.equal(reflected.getClassName(), schema.objectTypeName);
  assert.deepEqual([...reflected.getFieldTypeMap()], schema.fields.map(field => [field.fieldName, field.fieldType]));
  assert.deepEqual(reflected.getPrimaryKeyList(), schema.fields.filter(field => field.belongPrimaryKey).map(field => field.fieldName));
  assert.ok(schema.permissions.filter(role => role.role !== 'Administrator').every(role => role.rights.length === 0));
});

const functionConfig = JSON.parse(fs.readFileSync(path.join(functionDir, 'function-config.json'), 'utf8'));
assert.equal(functionConfig.handler, 'sharedplanpreflight.SharedPlanPreflight');
assert.equal(functionConfig.triggers[0].properties.authFlag, 'true');
console.log(`Shared-plan preflight: ${passed} passed, 0 failed. OFFLINE ONLY; simulated CAS, no network, deployment, pairing or Push registration.`);
