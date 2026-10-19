/** Pure production orchestration with isolated ports. No device, login or cloud mutation. */
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const ts = require('D:/local/DevEcoStudio/tools/hvigor/hvigor/node_modules/typescript');
const root = path.resolve(__dirname, '../..');
const file = path.join(root, 'feature/src/main/ets/usecase/SecurePairingUseCase.ets');
const diagnosticModule = { exports: {} };
vm.runInNewContext(ts.transpileModule(fs.readFileSync(path.join(root,
 'commons/src/main/ets/util/PlanConnectionDiagnostic.ets'), 'utf8'), {
 compilerOptions: { module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2021 }
}).outputText, { module: diagnosticModule, exports: diagnosticModule.exports });
const diagnostics = diagnosticModule.exports;
// Actual installed SDK deserializer, isolated from auth/HTTP and SDK background timers.
const sdkUtilsFile = path.resolve(root,
 '../FortwoCloud/CloudProgram/cloudfunctions/pairing/node_modules/@hw-agconnect/cloud-server/database-service/utils/Utils.js');
const sdkUtilsModule = { exports: {} };
vm.runInNewContext(fs.readFileSync(sdkUtilsFile, 'utf8'), { module: sdkUtilsModule,
 exports: sdkUtilsModule.exports, console, require: name => {
  if (name === './FieldType' || name === './Constant') return require(path.resolve(path.dirname(sdkUtilsFile), name));
  return {}; // Unused error/schema/query helpers; this fixture only exercises deserialization.
 } });
const { Utils: sdkUtils } = sdkUtilsModule.exports;
const { PairMemberBinding } = require(path.resolve(root, 'cloud-backend/cloudfunctions/dateplan/models.js'));
const mod = { exports: {} };
vm.runInNewContext(ts.transpileModule(fs.readFileSync(file, 'utf8'), {
 compilerOptions: { module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2021 }
}).outputText, { module: mod, exports: mod.exports, require: n => {
 if (n === 'commons') return diagnostics;
 throw Error('unexpected dependency ' + n);
} });
const { SecurePairingUseCase } = mod.exports;
const pair = 'sp-' + 'a'.repeat(32), actor = 'm-' + 'a'.repeat(64), peer = 'm-' + 'b'.repeat(64);
const key = 'B' + 'A'.repeat(86) + '=', proof = 'p'.repeat(32);
function fixture() {
 const f = { raw: '', calls: [], authCalls: [], keyCalls: [], uid: 'auth-a', anchor: 'legacy-a', enabled: true,
  cleanup: true, debt: false, epoch: '0', serial: 0, active: null, hooks: null, response: null, cas: true, proofAvailable: true };
 const identity = { async credential(create) { f.authCalls.push(create); return { uid: f.uid, accessToken: 'token-' + f.uid }; } };
 const cloud = { async invoke(method, token, params) {
  assert.ok(f.raw, 'intent must be durable before a cloud call');
  f.calls.push({ method, token, params });
  if (f.hooks) await f.hooks(method);
  const value = f.response ?? { code: 'OK', pairId: pair, status: 'WAITING', myUid: actor,
   peerUid: '', peerPublicKey: '', protocolVersion: 1, projectionVersion: 1,
   sharedPlanReady: false, revision: 1, expiresAt: Date.now() + 100000,
   inviteCode: '123456', confirmSecret: proof };
  return JSON.stringify(value);
 } };
 const keys = { async publicKey(uid, create) { f.keyCalls.push(create); return key; },
  async sealProof(uid, flow, plain) { assert.equal(plain, proof); return 'sealed-proof'; },
  async openProof() { return f.proofAvailable ? proof : null; }, async agree() {}, async available() { return true; },
  async dropProof() {}, async drop() {} };
 const store = { async load() { return f.raw; }, async hasCleanup() { return f.debt; }, async save(expected, next) {
  if (!f.cas || expected !== f.raw) return false; f.raw = next; return true;
 }, async activate(expected, next, session) {
  if (!f.cas || expected !== f.raw) return false; f.raw = next; f.active = session; return true;
 }, async revoke(expected, next) {
  if (!f.cas || expected !== f.raw) return false; f.raw = next; f.active = null; return true;
 } };
 const env = { enabled: () => f.enabled, cleanupEnabled: () => f.cleanup, anchor: () => f.anchor,
  epoch: () => f.epoch,
  nextId: () => 'flow-' + ++f.serial };
 f.make = () => new SecurePairingUseCase(identity, cloud, keys, store, env);
 f.usecase = f.make();
 f.binding = (status, revision = 2) => ({ code: 'OK', pairId: pair, status, myUid: actor, peerUid: peer,
  peerPublicKey: key, protocolVersion: 1, projectionVersion: 1, sharedPlanReady: status === 'ACTIVE',
  revision, expiresAt: status === 'ACTIVE' ? 0 : Date.now() + 100000 });
 f.keys = keys;
 f.identity = identity; f.cloud = cloud; f.store = store;
 return f;
}
let passed = 0;
async function test(name, run) { await run(); passed++; console.log('PASS ' + name); }
async function main() {
 await test('actual CloudDB SDK Long expiry is decoded on create and persisted as a number', async () => {
  const Model = PairMemberBinding, original = new Model();
  const expiry = Date.now() + 100000;
  const [hydrated] = sdkUtils.deserializeObjects([{ ...original, expiresAt: String(expiry), revision: '2' }],
   original.getFieldTypeMap(), Model, original.getClassName());
  assert.equal(typeof hydrated.getExpiresAt(), 'string', 'installed SDK retains Long text');
  assert.equal(typeof hydrated.getRevision(), 'number', 'Integer is already decoded by SDK');
  const f = fixture(); f.response = { code: 'OK', pairId: pair, status: 'WAITING', myUid: actor,
   peerUid: '', peerPublicKey: '', protocolVersion: 1, projectionVersion: 1, sharedPlanReady: false,
   revision: hydrated.getRevision(), expiresAt: hydrated.getExpiresAt(), inviteCode: '123456', confirmSecret: proof };
  const result = await f.usecase.create();
  assert.equal(result.code, 'OK'); assert.equal(result.inviteCode, '123456');
  assert.equal(JSON.parse(f.raw).expiresAt, expiry); assert.equal(f.active, null);
 });
 await test('decimal Long expiry works for join, confirm and ACTIVE refresh, including zero', async () => {
  const joined = fixture(); joined.response = joined.binding('PENDING_CONFIRM');
  joined.response.expiresAt = String(joined.response.expiresAt);
  assert.equal((await joined.usecase.join('123456')).phase, 'PENDING_CONFIRM');
  assert.equal(typeof JSON.parse(joined.raw).expiresAt, 'number'); assert.equal(joined.active, null);
  joined.response = joined.binding('ACTIVE', 3); joined.response.expiresAt = '0';
  assert.equal((await joined.make().resume()).phase, 'ACTIVE');
  assert.equal(JSON.parse(joined.raw).expiresAt, 0);
  assert.equal((await joined.make().refreshActive()).phase, 'ACTIVE');
  const creator = fixture(); await creator.usecase.create();
  creator.response = creator.binding('PENDING_CONFIRM'); creator.response.expiresAt = String(Date.now() + 100000);
  await creator.usecase.resume(); creator.response = creator.binding('ACTIVE', 3); creator.response.expiresAt = '0';
  assert.equal((await creator.usecase.confirm()).phase, 'ACTIVE');
  assert.equal(JSON.parse(creator.raw).expiresAt, 0);
 });
 await test('expiry rejects coercion, malformed decimals and unsafe integers without activation', async () => {
  const invalid = ['', '01', '+1', '-1', '1.0', '1e3', ' 1000', '1000 ', '0x10', 'NaN',
   '9007199254740992', '99999999999999999', null, true, false, [], {}, -1, 1.5, 9007199254740992];
  for (const expiresAt of invalid) {
   const f = fixture(); f.response = { ...f.binding('ACTIVE'), expiresAt };
   const result = await f.usecase.create();
   assert.equal(result.code, 'INVALID_REPLY'); assert.equal(result.diagnostic.stage, 'reply.validate.expiry');
   assert.equal(JSON.parse(f.raw).phase, 'CREATING'); assert.equal(f.active, null);
  }
 });
 await test('an invalid initial reply resumes the same durable request with no new identity', async () => {
  const f = fixture(); f.response = { ...f.binding('WAITING'), peerUid: '', peerPublicKey: '',
   expiresAt: 'not-a-long', inviteCode: '123456', confirmSecret: proof };
  const failed = await f.usecase.create(); assert.equal(failed.code, 'INVALID_REPLY');
  const flow = JSON.parse(f.raw).flowId, uid = JSON.parse(f.raw).authUid, publicKey = JSON.parse(f.raw).publicKey;
  f.response.expiresAt = String(Date.now() + 100000);
  const result = await f.make().resume(); assert.equal(result.phase, 'WAITING'); assert.equal(result.inviteCode, '123456');
  assert.equal(f.calls[0].params[0], flow); assert.equal(f.calls[1].params[0], flow);
  assert.equal(JSON.parse(f.raw).authUid, uid); assert.equal(JSON.parse(f.raw).publicKey, publicKey);
  assert.equal(f.authCalls.filter(Boolean).length, 1); assert.equal(f.keyCalls.filter(Boolean).length, 1);
 });
 await test('reply validation diagnoses fixed field groups and never coerces identity or capabilities', async () => {
  const base = { code: 'OK', pairId: pair, status: 'WAITING', myUid: actor, peerUid: '', peerPublicKey: '',
   protocolVersion: 1, projectionVersion: 1, sharedPlanReady: false, revision: 2,
   expiresAt: String(Date.now() + 100000), inviteCode: '123456', confirmSecret: proof };
  const cases = [
   [{ status: 'private-server-detail' }, 'status'], [{ myUid: 'private-uid' }, 'identity'],
   [{ pairId: null }, 'identity'], [{ protocolVersion: '1' }, 'capability'],
   [{ projectionVersion: '1' }, 'capability'], [{ sharedPlanReady: 'false' }, 'capability'],
   [{ revision: '2' }, 'revision'], [{ revision: 0 }, 'revision'],
   [{ peerUid: null }, 'peer'], [{ peerPublicKey: null }, 'peer'],
   [{ inviteCode: 'secret-invalid-code' }, 'invite'], [{ confirmSecret: 'private-proof' }, 'proof']
  ];
  for (const [changed, group] of cases) {
   const f = fixture(); f.response = { ...base, ...changed };
   const result = await f.usecase.create(); assert.equal(result.code, 'INVALID_REPLY');
   const report = JSON.parse(diagnostics.planConnectionReport(result.diagnostic, result.code));
   assert.equal(report.stage, 'reply.validate.' + group); assert.equal(report.build, '2026-10-08-diag3');
   assert.deepEqual(Object.keys(report).sort(), ['build', 'code', 'sdkCode', 'stage', 'tag']);
   assert.ok(!JSON.stringify(result).includes('private-')); assert.ok(!JSON.stringify(result).includes('secret-'));
   assert.equal(JSON.parse(f.raw).phase, 'CREATING'); assert.equal(f.active, null);
  }
 });
 await test('diagnostics whitelist stages and expose only numeric SDK codes', async () => {
  const secret = 'private-token-and-code';
  assert.equal(diagnostics.planConnectionSdkCode({ code: 1008200009, message: secret }), '1008200009');
  assert.equal(diagnostics.planConnectionSdkCode({ code: secret }), '');
  assert.equal(diagnostics.planConnectionSdkCode({ get code() { throw Error(secret); } }), '');
  assert.equal(diagnostics.planConnectionSdkCode({ code: Infinity }), '');
  const report = diagnostics.planConnectionReport({ stage: secret, sdkCode: secret }, secret);
  assert.ok(!report.includes(secret));
  assert.equal(JSON.parse(report).stage, 'setup');
  assert.equal(JSON.parse(report).code, 'RESULT_UNKNOWN');
 });
 await test('auth failure has a safe diagnostic and leaves no pending state or cloud request', async () => {
  const f = fixture();
  f.identity.credential = async () => { throw new diagnostics.PlanConnectionFailure('auth.signIn',
   { code: 1008210009, message: 'private-token' }, 'AUTH_UNAVAILABLE'); };
  const result = await f.usecase.create();
  assert.equal(result.code, 'RESULT_UNKNOWN');
  assert.equal(result.diagnostic.stage, 'auth.signIn');
  assert.equal(result.diagnostic.sdkCode, '1008210009');
  assert.equal(f.raw, ''); assert.equal(f.calls.length, 0);
  assert.ok(!JSON.stringify(result).includes('private-token'));
 });
 await test('key and partner-proof failures are distinguished before the cloud call', async () => {
  const f = fixture(); f.keys.publicKey = async () => { throw { code: 12000001 }; };
  const result = await f.usecase.create();
  assert.equal(result.diagnostic.stage, 'key.identity');
  assert.equal(result.diagnostic.sdkCode, '12000001'); assert.equal(f.calls.length, 0);
  const g = fixture(); g.keys.linkProof = async () => { throw Error('private-key'); };
  const proofResult = await g.usecase.create();
  assert.equal(proofResult.diagnostic.stage, 'key.partnerProof'); assert.equal(g.calls.length, 0);
 });
 await test('cloud failure preserves intent and manual retry clears the diagnostic', async () => {
  const f = fixture(); const invoke = f.cloud.invoke;
  f.cloud.invoke = async () => { throw new diagnostics.PlanConnectionFailure('cloud.call',
   { code: 1008200009 }, 'CLOUD_RESULT_UNKNOWN'); };
  const result = await f.usecase.create();
  assert.equal(result.diagnostic.stage, 'cloud.call');
  assert.equal(result.diagnostic.sdkCode, '1008200009'); assert.ok(f.raw);
  const flowId = JSON.parse(f.raw).flowId;
  f.cloud.invoke = invoke;
  const retried = await f.usecase.resume();
  assert.equal(retried.code, 'OK'); assert.equal(retried.diagnostic, undefined);
  assert.equal(JSON.parse(f.raw).flowId, flowId);
 });
 await test('storage and cloud business rejection diagnostics remain separate', async () => {
  const f = fixture(); f.store.save = async () => { throw { code: 14800000 }; };
  const storageResult = await f.usecase.create();
  assert.equal(storageResult.diagnostic.stage, 'store.write');
  assert.equal(storageResult.diagnostic.sdkCode, '14800000'); assert.equal(f.calls.length, 0);
  const g = fixture(); g.response = { code: 'FEATURE_DISABLED', message: 'private-server-detail' };
  const rejected = await g.usecase.create();
  assert.equal(rejected.code, 'FEATURE_DISABLED');
  assert.equal(rejected.diagnostic.stage, 'cloud.reply');
  assert.equal(rejected.diagnostic.sdkCode, '');
  assert.ok(!JSON.stringify(rejected).includes('private-server-detail'));
 });
 await test('foreground check never replays unknown setup and revocation removes the active projection', async () => {
  const f = fixture(); await f.usecase.create(); const calls = f.calls.length;
  assert.equal((await f.usecase.refreshActive()).code, 'NO_PROGRESS'); assert.equal(f.calls.length, calls);
  f.response = f.binding('ACTIVE'); assert.equal((await f.usecase.resume()).phase, 'ACTIVE');
  f.response = { code: 'SESSION_REVOKED' };
  assert.equal((await f.usecase.refreshActive()).phase, 'REVOKED'); assert.equal(f.active, null);
  assert.equal(f.calls.at(-1).method, 'pairStatus');
 });
 await test('linked retries reuse the persisted proof and reject a different legacy partner', async () => {
  const f = fixture(); let seals = 0;
  f.keys.linkProof = async () => { seals++; return 'encrypted-legacy-proof'; };
  f.keys.verifyLink = async () => false;
  assert.equal((await f.usecase.create()).code, 'OK');
  assert.equal(f.calls[0].params[3], 'encrypted-legacy-proof');
  await f.make().resume(); assert.equal(seals, 1);
  f.response = f.binding('ACTIVE'); f.response.peerLink = 'different-partner-proof';
  assert.equal((await f.usecase.resume()).code, 'PARTNER_LINK_REQUIRED');
  assert.equal(f.active, null);
 });
 await test('known pair is durable before key derivation and a late clear deletes the derived alias', async () => {
  const f = fixture(); const dropped = [];
  await f.usecase.create(); f.response = f.binding('ACTIVE');
  f.keys.agree = async () => {
    assert.equal(JSON.parse(f.raw).pairId, pair);
    f.epoch = 'after-clear'; f.raw = '';
  };
  f.keys.drop = async id => { dropped.push(id); };
  assert.equal((await f.usecase.resume()).code, 'SESSION_CHANGED');
  assert.deepEqual(dropped, [pair]); assert.equal(f.active, null);
 });
 await test('clear epoch fences the in-flight call but is not persisted across process recreation', async () => {
  const f = fixture(); f.hooks = () => { f.epoch = '1'; };
  assert.equal((await f.usecase.create()).code, 'SESSION_CHANGED');
  assert.equal(JSON.parse(f.raw).anchor, 'legacy-a');
  f.epoch = '0'; f.hooks = null;
  assert.equal((await f.make().resume()).code, 'OK');
 });
 await test('pending cleanup prevents creating or rejoining a binding that a retry could revoke', async () => {
  const f = fixture(); f.debt = true;
  assert.equal((await f.usecase.create()).code, 'CLEANUP_REQUIRED');
  assert.equal((await f.usecase.join('123456')).code, 'CLEANUP_REQUIRED');
  assert.equal(f.authCalls.length, 0); assert.equal(f.calls.length, 0); assert.equal(f.raw, '');
 });
 await test('closed creation and resume make no auth or cloud calls', async () => {
  const f = fixture(); f.enabled = false;
  assert.equal((await f.usecase.create()).code, 'FEATURE_DISABLED');
  assert.equal((await f.usecase.resume()).code, 'FEATURE_DISABLED');
  assert.equal(f.authCalls.length, 0); assert.equal(f.calls.length, 0);
 });
 await test('create persists only sealed proof and never the token', async () => {
  const f = fixture(); const r = await f.usecase.create();
  assert.equal(r.phase, 'WAITING'); assert.equal(r.inviteCode, '123456'); assert.equal(f.active, null);
  assert.ok(!f.raw.includes(proof)); assert.ok(!f.raw.includes('token-'));
  assert.equal(JSON.parse(f.raw).sealedProof, 'sealed-proof');
 });
 await test('lost create reply retries original request after process reconstruction', async () => {
  const f = fixture(); f.hooks = () => { throw Error('lost reply'); };
  assert.equal((await f.usecase.create()).code, 'RESULT_UNKNOWN');
  const id = f.calls[0].params[0]; f.hooks = null;
  assert.equal((await f.make().resume()).phase, 'WAITING');
  assert.equal(f.calls[1].params[0], id); assert.equal(f.authCalls.filter(Boolean).length, 1);
  assert.equal(f.keyCalls.filter(Boolean).length, 1);
 });
 await test('invalid short code makes no login or cloud call', async () => {
  const f = fixture(); assert.equal((await f.usecase.join('12x')).code, 'BAD_REQUEST');
  assert.equal(f.authCalls.length, 0); assert.equal(f.calls.length, 0);
 });
 await test('join pending cannot activate or confirm itself', async () => {
  const f = fixture(); f.response = f.binding('PENDING_CONFIRM');
  assert.equal((await f.usecase.join('123456')).phase, 'PENDING_CONFIRM');
  assert.equal(f.active, null); const n = f.calls.length;
  assert.equal((await f.usecase.confirm()).code, 'FORBIDDEN'); assert.equal(f.calls.length, n);
 });
 await test('lost join reply resumes original code and activates only verified ACTIVE', async () => {
  const f = fixture(); f.hooks = () => { throw Error('lost reply'); };
  await f.usecase.join('123456'); f.hooks = null; f.response = f.binding('ACTIVE', 3);
  const r = await f.make().resume(); assert.equal(r.phase, 'ACTIVE');
  assert.equal(f.calls[1].method, 'joinPair'); assert.equal(f.calls[1].params[0], '123456');
  assert.equal(f.active.generation, 'flow-1');
 });
 await test('creator confirms explicitly and later refresh preserves generation', async () => {
  const f = fixture(); await f.usecase.create(); f.response = f.binding('PENDING_CONFIRM', 2);
  await f.usecase.resume(); assert.equal(f.active, null);
  f.response = f.binding('ACTIVE', 3); assert.equal((await f.usecase.confirm()).phase, 'ACTIVE');
  assert.equal(f.calls.at(-1).method, 'confirmPair'); assert.equal(f.calls.at(-1).params[1], proof);
  const generation = f.active.generation; await f.make().resume();
  assert.equal(f.active.generation, generation); assert.equal(f.serial, 1);
 });
 await test('missing confirmation key never sends a code as confirmation proof', async () => {
  const f = fixture(); await f.usecase.create(); f.response = f.binding('PENDING_CONFIRM'); await f.usecase.resume();
  f.proofAvailable = false; const n = f.calls.length;
  assert.equal((await f.usecase.confirm()).code, 'PROOF_UNAVAILABLE'); assert.equal(f.calls.length, n);
 });
 await test('explicit resume reacquires creator proof using the same request, not a new identity', async () => {
  const f = fixture(); await f.usecase.create(); f.proofAvailable = false;
  await f.make().resume(); assert.equal(f.calls.at(-1).method, 'createPair');
  assert.equal(f.calls.at(-1).params[0], 'flow-1'); assert.equal(f.authCalls.filter(Boolean).length, 1);
  assert.equal(f.keyCalls.filter(Boolean).length, 1);
 });
 await test('failed CAS before cloud sends nothing; passive key loss does not create a replacement', async () => {
  const f = fixture(); f.cas = false; assert.equal((await f.usecase.create()).code, 'SESSION_CHANGED');
  assert.equal(f.calls.length, 0);
  f.cas = true; await f.usecase.create(); const n = f.calls.length;
  // Persisted public key no longer matches the device's export.
  const saved = JSON.parse(f.raw); saved.publicKey = 'B' + 'C'.repeat(86) + '='; f.raw = JSON.stringify(saved);
  assert.equal((await f.make().resume()).code, 'KEY_CHANGED'); assert.equal(f.calls.length, n);
 });
 await test('changed auth identity or legacy anchor refuses recovery without new identity', async () => {
  for (const changed of ['uid', 'anchor']) {
   const f = fixture(); await f.usecase.create(); const old = f.raw, n = f.calls.length;
   f[changed] = 'changed'; assert.notEqual((await f.make().resume()).code, 'OK');
   assert.equal(f.raw, old); assert.equal(f.calls.length, n); assert.equal(f.authCalls.filter(Boolean).length, 1);
  }
 });
 await test('late response cannot resurrect a cleared flow', async () => {
  const f = fixture(); f.hooks = () => { f.raw = ''; };
  assert.equal((await f.usecase.create()).code, 'SESSION_CHANGED'); assert.equal(f.raw, ''); assert.equal(f.active, null);
 });
 await test('identity changes during cloud call prevent committing returned binding', async () => {
  const f = fixture(); f.hooks = () => { f.uid = 'changed'; };
  assert.equal((await f.usecase.create()).code, 'IDENTITY_CHANGED');
  assert.equal(JSON.parse(f.raw).phase, 'CREATING'); assert.equal(f.active, null);
 });
 await test('double click is rejected by an in-flight latch', async () => {
  const f = fixture(); let release; const wait = new Promise(r => { release = r; }); f.hooks = () => wait;
  const pending = f.usecase.create(); assert.equal((await f.usecase.create()).code, 'BUSY');
  release(); await pending; assert.equal(f.calls.length, 1);
 });
 await test('older revision and changed peer cannot overwrite pinned binding', async () => {
  const f = fixture(); await f.usecase.create(); f.response = f.binding('PENDING_CONFIRM', 3); await f.usecase.resume();
  const pinned = f.raw; f.response = f.binding('PENDING_CONFIRM', 2);
  const older = await f.usecase.resume();
  assert.equal(older.code, 'INVALID_REPLY'); assert.equal(older.diagnostic.stage, 'reply.validate.revision'); assert.equal(f.raw, pinned);
  f.response = f.binding('PENDING_CONFIRM', 4); f.response.peerUid = 'm-' + 'c'.repeat(64);
  const changed = await f.usecase.resume();
  assert.equal(changed.code, 'INVALID_REPLY'); assert.equal(changed.diagnostic.stage, 'reply.validate.binding'); assert.equal(f.raw, pinned);
 });
 await test('unpair failure and closed network retain credentials; known success revokes atomically', async () => {
  const f = fixture(); await f.usecase.create(); const old = f.raw;
  f.response = { code: 'RESULT_UNKNOWN' }; assert.equal((await f.usecase.disconnect()).code, 'RESULT_UNKNOWN');
  assert.equal(f.raw, old); f.cleanup = false; const n = f.calls.length;
  assert.equal((await f.usecase.disconnect()).code, 'FEATURE_DISABLED'); assert.equal(f.calls.length, n);
  f.cleanup = true; f.enabled = false; f.response = { code: 'OK', status: 'REVOKED' };
  assert.equal((await f.usecase.disconnect()).phase, 'REVOKED'); assert.equal(JSON.parse(f.raw).sealedProof, '');
 });
 await test('local inspection is network-free and unknown/malformed status cannot activate', async () => {
  const f = fixture(); await f.usecase.create(); const n = f.calls.length, a = f.authCalls.length;
  await f.make().local(); assert.equal(f.calls.length, n); assert.equal(f.authCalls.length, a);
  f.response = f.binding('ACTIVE'); f.response.sharedPlanReady = false;
  assert.equal((await f.usecase.resume()).code, 'INVALID_REPLY'); assert.equal(f.active, null);
 });
 await test('closed setup still exposes local progress and allows original authenticated UID to clean up after key loss', async () => {
  const f = fixture(); await f.usecase.create(); f.enabled = false;
  const state = JSON.parse(f.raw); state.publicKey = 'B' + 'C'.repeat(86) + '='; f.raw = JSON.stringify(state);
  const n = f.calls.length; assert.equal((await f.make().local()).phase, 'WAITING'); assert.equal(f.calls.length, n);
  f.response = { code: 'OK', status: 'REVOKED' };
  assert.equal((await f.make().disconnect()).phase, 'REVOKED');
 });
 await test('encrypted handoff is durable before publication and reuses randomized ciphertext on retry', async () => {
  const f = fixture(); await f.usecase.create(); let seals = 0;
  f.response = { code: 'RESULT_UNKNOWN' };
  const seal = async () => { seals++; return 'encrypted-offer-' + seals; };
  assert.equal((await f.usecase.publishLink('a'.repeat(64), seal)).code, 'RESULT_UNKNOWN');
  assert.equal(JSON.parse(f.raw).bootstrapOffer, 'encrypted-offer-1');
  f.response = { code: 'OK' };
  assert.equal((await f.make().publishLink('a'.repeat(64), seal)).code, 'OK');
  assert.equal(seals, 1);
  assert.equal(f.calls.at(-1).params[2], 'encrypted-offer-1');
 });
 await test('automatic join pins decrypted pair and public key before any activation', async () => {
  const f = fixture(); f.response = f.binding('PENDING_CONFIRM');
  const other = 'sp-' + 'c'.repeat(32);
  assert.equal((await f.usecase.joinLinked('123456', other, key)).code, 'PARTNER_LINK_REQUIRED');
  assert.equal(f.active, null); assert.equal(JSON.parse(f.raw).expectedPairId, other);
  f.response = { ...f.binding('ACTIVE'), pairId: other };
  assert.equal((await f.make().resume()).phase, 'ACTIVE'); assert.equal(f.active.pairId, other);
 });
 await test('a lost creator reply can be cancelled without replaying create or dropping credentials early', async () => {
  const f = fixture(); f.hooks = method => { if (method === 'createPair') throw Error('lost'); };
  await f.usecase.create(); const raw = f.raw;
  f.hooks = null; f.response = { code: 'CLEANUP_PENDING' };
  assert.equal((await f.usecase.disconnect()).code, 'CLEANUP_PENDING'); assert.equal(f.raw, raw);
  assert.equal(f.calls.at(-1).method, 'cleanupCreate');
  f.response = { code: 'OK', status: 'REVOKED', pairId: pair };
  assert.equal((await f.usecase.disconnect()).phase, 'REVOKED');
  assert.equal(f.calls.filter(c => c.method === 'createPair').length, 1);
 });
 await test('a lost automatic join reply uses pinned pair for revocation without rejoining', async () => {
  const f = fixture(); f.hooks = () => { throw Error('lost'); };
  await f.usecase.joinLinked('123456', pair, key); f.hooks = null;
  f.response = { code: 'OK', status: 'REVOKED' };
  assert.equal((await f.usecase.disconnect()).phase, 'REVOKED');
  assert.equal(f.calls.at(-1).method, 'unpair'); assert.equal(f.calls.at(-1).params[0], pair);
 });
 console.log('secure pairing orchestration: ' + passed + ' passed, 0 failed (offline only)');
}
main().catch(e => { console.error(e); process.exitCode = 1; });
