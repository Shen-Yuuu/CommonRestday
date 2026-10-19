/** Real Node P-256/AES-GCM with production ArkTS control flow; NOT device HUKS evidence. */
const assert = require('node:assert/strict');
const crypto = require('node:crypto');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const ts = require('D:/local/DevEcoStudio/tools/hvigor/hvigor/node_modules/typescript');
const root = path.resolve(__dirname, '../..');
const modules = new Map(); const keys = new Map(); const sessions = new Map();
let handle = 1, generated = 0, deletes = 0, authInit = 0, signIns = 0, forceRefresh = [];
let authUser = null, switchOnToken = false, invocation = null, failEncrypt = false;
let cloudFailure = null;
let publicFormat = 'SEC1';
let failHash = false;
const logs = [];
function spkiFromPoint(point) {
 return crypto.createPublicKey({ format: 'jwk', key: { kty: 'EC', crv: 'P-256',
   x: point.subarray(1, 33).toString('base64url'), y: point.subarray(33).toString('base64url') }
 }).export({ format: 'der', type: 'spki' });
}
function pointFromSpki(bytes) {
 const jwk = crypto.createPublicKey({ key: bytes, format: 'der', type: 'spki' }).export({ format: 'jwk' });
 assert.equal(jwk.crv, 'P-256');
 return Buffer.concat([Buffer.from([4]), Buffer.from(jwk.x, 'base64url'), Buffer.from(jwk.y, 'base64url')]);
}
const constants = names => Object.fromEntries(names.map(n => [n, n]));
const huks = {
 HuksTag: constants(['HUKS_TAG_ALGORITHM','HUKS_TAG_KEY_SIZE','HUKS_TAG_PURPOSE','HUKS_TAG_DIGEST',
  'HUKS_TAG_PADDING','HUKS_TAG_BLOCK_MODE','HUKS_TAG_DERIVED_AGREED_KEY_STORAGE_FLAG','HUKS_TAG_IS_KEY_ALIAS',
  'HUKS_TAG_KEY_ALIAS','HUKS_TAG_KEY_TYPE','HUKS_TAG_NONCE','HUKS_TAG_ASSOCIATED_DATA','HUKS_TAG_AE_TAG']),
 HuksKeyAlg: constants(['HUKS_ALG_ECC','HUKS_ALG_ECDH','HUKS_ALG_AES']),
 HuksKeySize: { HUKS_ECC_KEY_SIZE_256: 256, HUKS_AES_KEY_SIZE_256: 256 },
 HuksKeyPurpose: { HUKS_KEY_PURPOSE_AGREE: 1, HUKS_KEY_PURPOSE_ENCRYPT: 2, HUKS_KEY_PURPOSE_DECRYPT: 4 },
 HuksKeyDigest: { HUKS_DIGEST_NONE: 0 }, HuksKeyPadding: { HUKS_PADDING_NONE: 0 },
 HuksCipherMode: constants(['HUKS_MODE_CBC','HUKS_MODE_GCM']),
 HuksKeyStorageType: { HUKS_STORAGE_ONLY_USED_IN_HUKS: 2 },
 HuksImportKeyType: { HUKS_KEY_TYPE_PUBLIC_KEY: 1 },
 async hasKeyItem(alias) { return keys.has(alias); },
 async generateKeyItem(alias, options) {
   assert.ok(!keys.has(alias), 'no existing identity is overwritten'); generated++;
   if (prop(options, 'HUKS_TAG_ALGORITHM') === 'HUKS_ALG_ECC') {
     const ecc = crypto.createECDH('prime256v1'); ecc.generateKeys(); keys.set(alias, { ecc });
   } else keys.set(alias, { aes: crypto.randomBytes(32) });
 },
 async exportKeyItem(alias) {
   const point = keys.get(alias).ecc.getPublicKey();
   return { outData: new Uint8Array(publicFormat === 'DER' ? spkiFromPoint(point)
     : publicFormat === 'XY' ? point.subarray(1) : point) };
 },
 async deleteKeyItem(alias) { deletes++; if (!keys.delete(alias)) throw { code: 12000011 }; },
 async initSession(alias, options) {
   assert.ok(keys.has(alias), 'key must exist');
   const id = handle++; sessions.set(id, { alias, options, peer: null }); return { handle: id };
 },
 async updateSession(id, options) { sessions.get(id).peer = Buffer.from(options.inData); return {}; },
 async finishSession(id, options) {
   const session = sessions.get(id); const key = keys.get(session.alias);
   if (prop(session.options, 'HUKS_TAG_ALGORITHM') === 'HUKS_ALG_ECDH') {
     assert.equal(prop(options, 'HUKS_TAG_DERIVED_AGREED_KEY_STORAGE_FLAG'), 2);
     const alias = Buffer.from(prop(options, 'HUKS_TAG_KEY_ALIAS')).toString();
     assert.ok(alias.startsWith('ft-plan-pair-') || alias.startsWith('crd-pair-'));
     let peer = session.peer;
     if (publicFormat === 'DER') { assert.equal(peer.length, 91); peer = pointFromSpki(peer); }
     else if (publicFormat === 'XY') { assert.equal(peer.length, 64); peer = Buffer.concat([Buffer.from([4]), peer]); }
     else { assert.equal(peer.length, 65); assert.equal(peer[0], 4); }
     keys.set(alias, { aes: key.ecc.computeSecret(peer) }); sessions.delete(id); return {};
   }
   const iv = Buffer.from(prop(options, 'HUKS_TAG_NONCE'));
   const aad = Buffer.from(prop(options, 'HUKS_TAG_ASSOCIATED_DATA'));
   const data = Buffer.from(options.inData);
   let out;
   if (prop(options, 'HUKS_TAG_PURPOSE') === 2) {
     if (failEncrypt) throw new Error('injected cipher failure');
     const cipher = crypto.createCipheriv('aes-256-gcm', key.aes, iv); cipher.setAAD(aad);
     out = Buffer.concat([cipher.update(data), cipher.final(), cipher.getAuthTag()]);
   } else {
     const cipher = crypto.createDecipheriv('aes-256-gcm', key.aes, iv); cipher.setAAD(aad);
     cipher.setAuthTag(Buffer.from(prop(options, 'HUKS_TAG_AE_TAG')));
     out = Buffer.concat([cipher.update(data), cipher.final()]);
   }
   sessions.delete(id); return { outData: new Uint8Array(out) };
 },
 async abortSession(id) { sessions.delete(id); }
};
function prop(options, name) { return options.properties.find(p => p.tag === name)?.value; }
const util = {
 Base64Helper: class { encodeToStringSync(b) { return Buffer.from(b).toString('base64'); }
   decodeSync(s) { return new Uint8Array(Buffer.from(s, 'base64')); } },
 TextEncoder: class { encodeInto(s) { return new Uint8Array(Buffer.from(s)); } },
 TextDecoder: class { static create() { return { decodeToString: b => Buffer.from(b).toString() }; } },
 generateRandomUUID: () => crypto.randomUUID()
};
const auth = {
 init() { authInit++; }, async getCurrentUser() { return authUser; },
 async signInAnonymously() { signIns++; authUser = user('device-a'); return { getUser: () => authUser }; }
};
function user(uid, anonymous = true) {
 return { getUid: () => uid, isAnonymous: () => anonymous, async getToken(force) {
   forceRefresh.push(force); if (switchOnToken) authUser = user('device-other');
   return { getString: () => 'token-' + uid };
 } };
}
function load(relative) {
 const file = path.resolve(root, relative); if (modules.has(file)) return modules.get(file).exports;
 const module = { exports: {} }; modules.set(file, module);
 const source = ts.transpileModule(fs.readFileSync(file, 'utf8'), {
   compilerOptions: { module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2021 }
 }).outputText;
 vm.runInNewContext(source, { module, exports: module.exports, Uint8Array, console, require: name => {
   if (name === '@hw-agconnect/auth') return { default: auth };
   if (name === '@kit.UniversalKeystoreKit') return { huks };
   if (name === '@kit.ArkTS') return { util };
   if (name === '@kit.CryptoArchitectureKit') return { cryptoFramework: {
     createRandom: () => ({ generateRandomSync: n => ({ data: new Uint8Array(crypto.randomBytes(n)) }) }),
     createMd: () => { if (failHash) throw { code: 17620001, message: 'private-hash' };
       const hash = crypto.createHash('sha256'); return {
       async update(value) { hash.update(value.data); }, async digest() { return { data: new Uint8Array(hash.digest()) }; }
     }; }
   } };
   if (name === '@kit.CloudFoundationKit') return { cloudFunction: { async call(arg) {
     invocation = arg; if (cloudFailure) throw cloudFailure; return { result: '{"code":"OK"}' };
   } } };
   if (name === './CloudApi') return { CLOUD_TIMEOUT_MS: 30000 };
   if (name === 'commons') return { ...load('commons/src/main/ets/util/PlanConnectionDiagnostic.ets'),
     Logger: { info: (...a) => logs.push(a), warn: (...a) => logs.push(a) } };
   if (name.startsWith('@kit.')) return {};
   if (name.startsWith('.')) return load(path.relative(root, path.resolve(path.dirname(file), name + '.ets')));
   throw new Error('Unexpected import ' + name);
 } }, { filename: file });
 return module.exports;
}
const { AnonymousIdentity } = load('cloud/src/main/ets/api/AnonymousIdentity.ets');
const { DatePlanCloudApi } = load('cloud/src/main/ets/api/DatePlanCloudApi.ets');
const { SecurePlanKeyStore, planPublicPoint } = load('cloud/src/main/ets/api/SecurePlanKeyStore.ets');
const { PairKeyStore } = load('cloud/src/main/ets/api/PairKeyStore.ets');
const { SnapshotCrypto } = load('cloud/src/main/ets/api/SnapshotCrypto.ets');
const { planConnectionReport, planConnectionStageLabel } = load('commons/src/main/ets/util/PlanConnectionDiagnostic.ets');
const { SecureSharedPlanGateway } = load('feature/src/main/ets/usecase/SecureSharedPlanGateway.ets');
const { SharedPlanUseCase } = load('feature/src/main/ets/usecase/SharedPlanUseCase.ets');
const { sharedPlanAad } = load('feature/src/main/ets/model/SharedPlanFlow.ets');
const pair = 'sp-' + '1'.repeat(32), a = 'm-' + 'a'.repeat(64), b = 'm-' + 'b'.repeat(64);
const ctx = { pairId: pair, actorId: a, peerId: b, generation: 'gen-1', protocolVersion: 1, projectionVersion: 1 };
const content = { title: '晚饭', kind: 'meal', start: 600, end: 660 };
let count = 0;
async function check(name, work) { await work(); count++; console.log('PASS ' + name); }
async function main() {
 await check('local UID fence has no auth initialization, sign-in, or token request', async () => {
   const initBefore = authInit, tokensBefore = forceRefresh.length;
   assert.equal(await AnonymousIdentity.currentUid(), '');
   assert.equal(authInit, initBefore); assert.equal(forceRefresh.length, tokensBefore); assert.equal(signIns, 0);
 });
 await check('attach has no SDK login or network effect; passive credential does not create identity', async () => {
   AnonymousIdentity.attach({ resourceManager: { getRawFileContentSync: () => new Uint8Array(Buffer.from('{}')) } });
   assert.equal(authInit, 0); await assert.rejects(AnonymousIdentity.credential(false), /AUTH_UNAVAILABLE/);
   assert.equal(signIns, 0); assert.equal(authInit, 1);
 });
 await check('concurrent explicit anonymous creation has one login and refreshes real SDK token', async () => {
   const result = await Promise.all([AnonymousIdentity.credential(true), AnonymousIdentity.credential(true)]);
   assert.equal(signIns, 1); assert.equal(result[0].uid, 'device-a'); assert.equal(result[1].accessToken, 'token-device-a');
   assert.ok(forceRefresh.every(v => v === true));
 });
 await check('non-anonymous identity is not replaced, and switching during token acquisition fails closed', async () => {
   authUser = user('signed-user', false); await assert.rejects(AnonymousIdentity.credential(true)); assert.equal(signIns, 1);
   authUser = user('device-a'); switchOnToken = true; await assert.rejects(AnonymousIdentity.credential(false)); switchOnToken = false;
 });
 await check('cloud call has explicit timeout and token only in RPC arguments; invalid methods send nothing', async () => {
   await DatePlanCloudApi.invoke('capabilities', 'access-test', [pair]);
   assert.equal(invocation.timeout, 30000); assert.equal(invocation.name, 'dateplan');
   assert.equal(invocation.data.params[0], 'access-test'); assert.equal(invocation.data.params[1], pair);
   const n = DatePlanCloudApi.calls; await assert.rejects(DatePlanCloudApi.invoke('deleteAll', 'access-test', []));
   assert.equal(DatePlanCloudApi.calls, n);
 });
 await check('cloud latency diagnostic contains only fixed operation, duration and transport-return status', async () => {
   await DatePlanCloudApi.invoke('read', 'private-token-for-timing', ['private-pair-for-timing']);
   const entry = logs.filter(row => row[0] === 'DatePlanCloudApi').at(-1);
   const timing = JSON.parse(entry[1]);
   assert.deepEqual(Object.keys(timing).sort(), ['elapsedMs', 'method', 'returned', 'tag']);
   assert.equal(timing.tag, 'FORTWO_PLAN_RPC_TIMING'); assert.equal(timing.method, 'read');
   assert.equal(timing.returned, true); assert.ok(Number.isSafeInteger(timing.elapsedMs) && timing.elapsedMs >= 0);
   assert.ok(!JSON.stringify(logs).includes('private-token-for-timing'));
   assert.ok(!JSON.stringify(logs).includes('private-pair-for-timing'));
 });
 await check('anonymous login and token failures preserve safe stage and numeric SDK code', async () => {
   const signIn = auth.signInAnonymously;
   authUser = null;
   auth.signInAnonymously = async () => { throw { code: 203817987, message: 'private-token' }; };
   try {
     await assert.rejects(AnonymousIdentity.credential(true), error =>
       error.message === 'AUTH_UNAVAILABLE' && error.diagnostic.stage === 'auth.signIn' &&
       error.diagnostic.sdkCode === '203817987' && !JSON.stringify(error).includes('private-token'));
   } finally { auth.signInAnonymously = signIn; }
   authUser = user('device-a');
   authUser.getToken = async () => { throw { code: '1008200009', message: 'private-token' }; };
   try {
     await assert.rejects(AnonymousIdentity.credential(false), error =>
       error.diagnostic.stage === 'auth.token' && error.diagnostic.sdkCode === '1008200009');
   } finally { authUser = user('device-a'); }
 });
 await check('cloud SDK failure does not expose a token or arbitrary message', async () => {
   cloudFailure = { code: 1008200009, message: 'private-access-token' };
   try {
     await assert.rejects(DatePlanCloudApi.invoke('capabilities', 'private-access-token', [pair]), error =>
       error.message === 'CLOUD_RESULT_UNKNOWN' && error.diagnostic.stage === 'cloud.call' &&
       error.diagnostic.sdkCode === '1008200009' && !JSON.stringify(error).includes('private-access-token'));
   } finally { cloudFailure = null; }
 });
 await check('resource and SDK initialization failures are distinguished before login', async () => {
   const file = path.resolve(root, 'cloud/src/main/ets/api/AnonymousIdentity.ets');
   const originalModule = modules.get(file); const originalInit = auth.init;
   const normalContext = { resourceManager: { getRawFileContentSync: () => new Uint8Array(Buffer.from('{}')) } };
   const before = signIns;
   try {
     modules.delete(file);
     const fresh = load('cloud/src/main/ets/api/AnonymousIdentity.ets').AnonymousIdentity;
     fresh.attach({ resourceManager: { getRawFileContentSync() { throw { code: 9001001 }; } } });
     await assert.rejects(fresh.credential(true), error =>
       error.diagnostic.stage === 'auth.resource' && error.diagnostic.sdkCode === '9001001');
     fresh.attach(normalContext); auth.init = () => { throw { code: 203817999 }; };
     await assert.rejects(fresh.credential(true), error =>
       error.diagnostic.stage === 'auth.init' && error.diagnostic.sdkCode === '203817999');
     assert.equal(signIns, before);
   } finally { auth.init = originalInit; modules.set(file, originalModule); }
 });
 let publicA, publicB;
 await check('real P-256 X.509 SPKI converts to the same 65-byte cloud public point', async () => {
   const publicKey = crypto.generateKeyPairSync('ec', { namedCurve: 'prime256v1' }).publicKey;
   const der = publicKey.export({ format: 'der', type: 'spki' });
   assert.equal(der.length, 91);
   const point = Buffer.from(planPublicPoint(new Uint8Array(der)));
   assert.deepEqual(point, pointFromSpki(der));
   assert.deepEqual(Buffer.from(planPublicPoint(new Uint8Array(point))), point);
   assert.deepEqual(Buffer.from(planPublicPoint(new Uint8Array(point.subarray(1)))), point);
 });
 await check('DER rejects altered algorithm, curve, lengths, BIT STRING and trailing material', async () => {
   const key = crypto.generateKeyPairSync('ec', { namedCurve: 'prime256v1' });
   const der = key.publicKey.export({ format: 'der', type: 'spki' });
   for (let i = 0; i < 26; i++) {
     const broken = Buffer.from(der); broken[i] ^= 1;
     assert.throws(() => planPublicPoint(new Uint8Array(broken)), /PLAN_PUBLIC_KEY_FORMAT/);
   }
   for (const broken of [der.subarray(0, 90), Buffer.concat([der, Buffer.from([0])]), Buffer.alloc(91),
     key.privateKey.export({ format: 'der', type: 'pkcs8' })]) {
     assert.throws(() => planPublicPoint(new Uint8Array(broken)), /PLAN_PUBLIC_KEY_FORMAT/);
   }
   const compressed = Buffer.from(der); compressed[26] = 2;
   assert.throws(() => planPublicPoint(new Uint8Array(compressed)), /PLAN_PUBLIC_KEY_FORMAT/);
 });
 await check('other named curves cannot masquerade as P-256 SPKI', async () => {
   for (const namedCurve of ['secp256k1', 'secp384r1', 'secp521r1']) {
     const der = crypto.generateKeyPairSync('ec', { namedCurve }).publicKey.export({ format: 'der', type: 'spki' });
     assert.throws(() => planPublicPoint(new Uint8Array(der)), /PLAN_PUBLIC_KEY_FORMAT/);
   }
 });
 await check('creator proof is sealed per authenticated UID and flow, never reused from legacy namespace', async () => {
   const secret = 'x'.repeat(32);
   const sealed = await SecurePlanKeyStore.sealProof('device-a', 'flow-a', secret);
   assert.ok(!sealed.includes(secret));
   assert.equal(await SecurePlanKeyStore.openProof('device-a', 'flow-a', sealed), secret);
   const before = generated;
   assert.equal(await SecurePlanKeyStore.openProof('device-b', 'flow-a', sealed), null);
   assert.equal(await SecurePlanKeyStore.openProof('device-a', 'flow-b', sealed), null);
   assert.equal(generated, before, 'opening a proof never creates a replacement key');
   assert.ok([...keys.keys()].some(k => k.startsWith('ft-plan-proof-') && k.length === 78));
   const modified = JSON.parse(sealed); modified.authTag = Buffer.alloc(16, 9).toString('base64');
   assert.equal(await SecurePlanKeyStore.openProof('device-a', 'flow-a', JSON.stringify(modified)), null);
   await SecurePlanKeyStore.dropProof('device-a', 'flow-a');
   assert.equal(await SecurePlanKeyStore.openProof('device-a', 'flow-a', sealed), null);
   assert.equal(generated, before);
   await assert.rejects(SecurePlanKeyStore.sealProof('device-a', 'flow-a', '123456'));
 });
 await check('new plan keys do not reuse or overwrite legacy keys; public-only P-256 representation', async () => {
   await PairKeyStore.ensureIdentity('device-a'); const before = generated;
   publicA = await SecurePlanKeyStore.publicKey('device-a', true);
   publicB = await SecurePlanKeyStore.publicKey('device-b', true);
   assert.equal(generated, before + 2); assert.equal(Buffer.from(publicA, 'base64').length, 65);
   assert.notEqual(publicA, publicB); assert.ok([...keys.keys()].some(k => k.startsWith('crd-id-')));
   assert.ok([...keys.keys()].filter(k => k.startsWith('ft-plan-id-')).every(k => k.length === 75));
   assert.equal(Buffer.from(planPublicPoint(new Uint8Array(64))).length, 65);
   assert.throws(() => planPublicPoint(new Uint8Array(91)));
   await assert.rejects(SecurePlanKeyStore.publicKey('never-created', false));
   await assert.rejects(SecurePlanKeyStore.publicKey('', true));
 });
 // On one Node host both logical devices share a map; remove the first pair alias to exercise both derivations.
 await check('ECDH derives equal AES bytes, re-agreement does not delete a live key', async () => {
   await SecurePlanKeyStore.agree('device-a', pair, publicB);
   const alias = [...keys.keys()].find(k => k.startsWith('ft-plan-pair-')); const secretA = keys.get(alias).aes;
   const priorDeletes = deletes;
   await SecurePlanKeyStore.agree('device-a', pair, publicB); assert.equal(deletes, priorDeletes);
   keys.delete(alias); await SecurePlanKeyStore.agree('device-b', pair, publicA);
   assert.deepEqual(keys.get(alias).aes, secretA);
   assert.equal(await SecurePlanKeyStore.available(pair), true);
 });
 await check('SEC1, XY and X.509 export formats interoperate in all nine ECDH combinations', async () => {
   const before = generated, priorDeletes = deletes;
   let index = 2;
   try {
     for (const formatA of ['SEC1', 'XY', 'DER']) for (const formatB of ['SEC1', 'XY', 'DER']) {
       const testPair = 'sp-' + (index++).toString(16).padStart(32, '0');
       const pairAlias = 'ft-plan-pair-' + crypto.createHash('sha256').update('FT_PLAN_PAIR|' + testPair).digest('hex');
       publicFormat = formatA; assert.equal(await SecurePlanKeyStore.publicKey('device-a', false), publicA);
       await SecurePlanKeyStore.agree('device-a', testPair, publicB);
       const firstSecret = keys.get(pairAlias).aes;
       const wire = await SecurePlanKeyStore.seal(testPair, 'format-test', 'same secret', 1);
       keys.delete(pairAlias); // separate logical device's derived-key namespace in this Node fixture
       publicFormat = formatB; assert.equal(await SecurePlanKeyStore.publicKey('device-b', false), publicB);
       await SecurePlanKeyStore.agree('device-b', testPair, publicA);
       assert.deepEqual(keys.get(pairAlias).aes, firstSecret);
       assert.equal(await SecurePlanKeyStore.open(testPair, 'format-test', wire, 1), 'same secret');
       await SecurePlanKeyStore.agree('device-b', testPair, publicA);
       keys.delete(pairAlias);
     }
   } finally { publicFormat = 'SEC1'; }
   assert.equal(generated, before, 'export-format compatibility never regenerates an identity');
   assert.equal(deletes, priorDeletes, 'production never deletes a live key for format conversion');
 });
 await check('hash, lookup, generation and export failures retain only fixed stages and numeric codes', async () => {
   failHash = true;
   try { await assert.rejects(SecurePlanKeyStore.publicKey('device-a', false), error =>
     error.diagnostic.stage === 'key.hash' && error.diagnostic.sdkCode === '17620001'); }
   finally { failHash = false; }
   const before = generated, priorDeletes = deletes;
   for (const [method, stage] of [['hasKeyItem', 'key.identity.lookup'],
     ['generateKeyItem', 'key.identity.generate'], ['exportKeyItem', 'key.identity.export']]) {
     const original = huks[method];
     huks[method] = async () => { throw { code: 12000003, message: 'private-key-material' }; };
     try {
       await assert.rejects(SecurePlanKeyStore.publicKey(method === 'generateKeyItem' ? 'new-device' : 'device-a', true), error => {
         assert.equal(error.diagnostic.stage, stage); assert.equal(error.diagnostic.sdkCode, '12000003');
         const report = JSON.parse(planConnectionReport(error.diagnostic, 'RESULT_UNKNOWN'));
         assert.equal(report.build, '2026-10-08-diag3'); assert.equal(report.stage, stage);
         assert.ok(!JSON.stringify(error).includes('private-key-material'));
         assert.ok(!planConnectionStageLabel(stage).includes('准备共同计划连接'));
         return true;
       });
     } finally { huks[method] = original; }
   }
   assert.equal(generated, before); assert.equal(deletes, priorDeletes);
 });
 await check('unsupported export and encoding failures are distinct, with no regeneration fallback', async () => {
   const before = generated, priorDeletes = deletes, originalExport = huks.exportKeyItem;
   huks.exportKeyItem = async () => ({ outData: new Uint8Array(91) });
   try { await assert.rejects(SecurePlanKeyStore.publicKey('device-a', true), error =>
     error.diagnostic.stage === 'key.identity.format' && error.diagnostic.sdkCode === ''); }
   finally { huks.exportKeyItem = originalExport; }
   const originalEncode = SnapshotCrypto.toB64;
   SnapshotCrypto.toB64 = () => { throw { code: 401, message: 'private-public-key' }; };
   try { await assert.rejects(SecurePlanKeyStore.publicKey('device-a', true), error =>
     error.diagnostic.stage === 'key.identity.encode' && error.diagnostic.sdkCode === '401'); }
   finally { SnapshotCrypto.toB64 = originalEncode; }
   assert.equal(await SecurePlanKeyStore.publicKey('device-a', false), publicA);
   assert.equal(generated, before); assert.equal(deletes, priorDeletes);
 });
 await check('agreement init/update/finish failures preserve safe stage and abort any live session', async () => {
   const testPair = 'sp-' + 'e'.repeat(32);
   for (const [method, stage] of [['initSession', 'key.agree.init'],
     ['updateSession', 'key.agree.update'], ['finishSession', 'key.agree.finish']]) {
     const original = huks[method];
     huks[method] = async () => { throw { code: 12000003, message: 'private-agreement' }; };
     try { await assert.rejects(SecurePlanKeyStore.agree('device-a', testPair, publicB), error =>
       error.diagnostic.stage === stage && error.diagnostic.sdkCode === '12000003' &&
       !JSON.stringify(error).includes('private-agreement')); }
     finally { huks[method] = original; }
     assert.equal(sessions.size, 0); assert.equal(await SecurePlanKeyStore.available(testPair), false);
   }
 });
 let envelope;
 await check('real AES-GCM roundtrip and content revision binding; state changes do not change AAD', async () => {
   envelope = await SecurePlanKeyStore.seal(pair, sharedPlanAad(pair, 'p1', 1), JSON.stringify(content), 1);
   assert.deepEqual(JSON.parse(await SecurePlanKeyStore.open(pair, sharedPlanAad(pair, 'p1', 1), envelope, 1)), content);
   assert.equal(await SecurePlanKeyStore.open(pair, sharedPlanAad(pair, 'p2', 1), envelope, 1), null);
   assert.equal(await SecurePlanKeyStore.open(pair, sharedPlanAad(pair, 'p1', 2), envelope, 2), null);
   const edited = JSON.parse(envelope); edited.authTag = Buffer.alloc(16, 9).toString('base64');
   assert.equal(await SecurePlanKeyStore.open(pair, sharedPlanAad(pair, 'p1', 1), JSON.stringify(edited), 1), null);
   assert.equal(sessions.size, 0, 'failed decrypt sessions are aborted');
 });
 await check('failed encryption aborts its HUKS session and exposes no raw SDK failure', async () => {
   failEncrypt = true;
   await assert.rejects(SecurePlanKeyStore.seal(pair, sharedPlanAad(pair, 'p1', 1), JSON.stringify(content), 1),
     /HUKS_ENCRYPT_FAILED/);
   failEncrypt = false; assert.equal(sessions.size, 0);
 });
 let enabled = false, identityCalls = 0, rpc = [], uid = 'device-a', local = { ...ctx }, sealed = 0;
 let cached = null, readRows = [], responseCode = 'OK', switchAfterRpc = false;
 let switchDuringCapability = false, capabilityReady = true, storageFailure = false, mutationRow = null;
 const wires = new Map(); const drafts = new Map();
 const binding = () => ({ code: 'OK', pairId: pair, status: 'ACTIVE', myUid: a, peerUid: b,
   peerPublicKey: publicB, protocolVersion: 1, projectionVersion: 1, sharedPlanReady: capabilityReady });
 const store = { async session() { return local; }, async current(s) { return local !== null && s.generation === local.generation; },
   async cached() { return cached; }, async wire(s, id, draft) {
     if (drafts.get(id) !== draft) throw new Error('wrong draft'); return wires.get(id) ?? '';
   }, async saveWire(s, id, draft, wire) {
     if (storageFailure) throw new Error('disk unavailable');
     if (local === null || s.generation !== local.generation || drafts.get(id) !== draft) throw new Error('stale');
     if (!wires.has(id)) wires.set(id, wire); return wires.get(id);
   } };
 const identity = { async credential(create) { assert.equal(create, false); identityCalls++; return { uid, accessToken: 'tok-' + uid }; } };
 const cipher = { available: SecurePlanKeyStore.available.bind(SecurePlanKeyStore),
   async seal(...args) { sealed++; return SecurePlanKeyStore.seal(...args); }, open: SecurePlanKeyStore.open.bind(SecurePlanKeyStore) };
 function wireRow(env, state = 'PENDING', version = 1) {
   return { pairId: pair, planId: 'p1', proposerUid: a, recipientUid: b, state, stateVersion: version,
     contentRevision: 1, acceptedRevision: state === 'ACCEPTED' ? 1 : 0, protocolVersion: 1,
     pendingAuthorUid: state === 'PENDING' ? a : '', pendingEnvelope: state === 'PENDING' ? env : '',
     acceptedEnvelope: state === 'ACCEPTED' ? env : '' };
 }
 const cloud = { async invoke(method, token, args) {
   rpc.push({ method, token, args }); if (method === 'capabilities') {
     if (switchDuringCapability) uid = 'another-device';
     return JSON.stringify(binding());
   }
   if (switchAfterRpc) uid = 'another-device';
   if (method === 'read') return JSON.stringify({ code: responseCode, plans: readRows });
   if (responseCode !== 'OK') return JSON.stringify({ code: responseCode });
   const body = JSON.parse(args[0]); return JSON.stringify({ code: 'OK', plan: mutationRow ?? wireRow(body.envelope) });
 } };
 const gateway = () => new SecureSharedPlanGateway(identity, cloud, cipher, store, () => enabled);
 await check('closed gate does zero identity or cloud requests', async () => {
   assert.equal(await gateway().context(), null); assert.equal(identityCalls, 0); assert.equal(rpc.length, 0);
 });
 await check('context comes from authenticated server members, not a legacy UID', async () => {
   enabled = true; assert.deepEqual(JSON.parse(JSON.stringify(await gateway().context())), ctx);
   const old = local; local = { ...ctx, actorId: 'legacy-uid' }; assert.equal(await gateway().context(), null); local = old;
 });
 await check('identity switch during capability verification cannot authorize a read or mutation', async () => {
   switchDuringCapability = true;
   assert.equal(await gateway().context(), null); uid = 'device-a';
   const reads = rpc.filter(r => r.method === 'read').length;
   assert.equal((await gateway().read(ctx)).code, 'SECURE_SESSION_REQUIRED');
   assert.equal(rpc.filter(r => r.method === 'read').length, reads);
   switchDuringCapability = false; uid = 'device-a';
 });
 await check('unready peer capability blocks secure transport without affecting legacy state', async () => {
   capabilityReady = false; assert.equal(await gateway().context(), null);
   const writes = rpc.filter(r => r.method === 'mutate').length;
   assert.equal((await gateway().send(ctx, { requestId: 'blocked', planId: 'p1', action: 'ACCEPT',
     expectedVersion: 1, nextContent: null })).code, 'SECURE_SESSION_REQUIRED');
   assert.equal(rpc.filter(r => r.method === 'mutate').length, writes); capabilityReady = true;
 });
 const command = { requestId: 'req-1', planId: 'p1', action: 'PROPOSE', expectedVersion: 0, nextContent: content };
 drafts.set(command.requestId, JSON.stringify(command));
 await check('wire is persisted before first RPC; ambiguous result retains ciphertext, recreation retries exact bytes', async () => {
   responseCode = 'RESULT_UNKNOWN'; assert.equal((await gateway().send(ctx, command)).code, 'RESULT_UNKNOWN');
   const first = rpc.filter(r => r.method === 'mutate').at(-1).args[0]; assert.equal(first, wires.get('req-1'));
   assert.ok(!first.includes(content.title)); const n = sealed;
   responseCode = 'OK'; const result = await gateway().send(ctx, command);
   assert.equal(result.code, 'OK'); assert.equal(result.records[0].pendingContent.title, content.title);
   assert.equal(sealed, n); assert.equal(rpc.filter(r => r.method === 'mutate').at(-1).args[0], first);
 });
 await check('confirmed content decrypts at acceptedRevision even after stateVersion changes', async () => {
   readRows = [wireRow(envelope, 'ACCEPTED', 2)];
   const result = await gateway().read(ctx); assert.equal(result.code, 'OK'); assert.equal(result.records[0].acceptedContent.start, 600);
 });
 await check('amendment revision two decrypts beside the retained revision one agreement', async () => {
   const next = { ...content, start: 720, end: 780 };
   cached = { contentRevision: 1, stateVersion: 2 };
   const amend = { requestId: 'req-amend', planId: 'p1', action: 'AMEND', expectedVersion: 2, nextContent: next };
   drafts.set(amend.requestId, JSON.stringify(amend)); responseCode = 'RESULT_UNKNOWN';
   assert.equal((await gateway().send(ctx, amend)).code, 'RESULT_UNKNOWN');
   const body = JSON.parse(wires.get(amend.requestId));
   assert.equal(JSON.parse(body.envelope).contentRevision, 2);
   mutationRow = { ...wireRow(envelope, 'ACCEPTED', 3), contentRevision: 2,
     pendingAuthorUid: a, pendingEnvelope: body.envelope };
   responseCode = 'OK'; const result = await gateway().send(ctx, amend);
   assert.equal(result.code, 'OK'); assert.equal(result.records[0].acceptedContent.start, 600);
   assert.equal(result.records[0].pendingContent.start, 720); mutationRow = null; cached = null;
 });
 await check('failed durable wire write never sends an unrecorded mutation', async () => {
   const cmd = { ...command, requestId: 'req-disk-fail' }; drafts.set(cmd.requestId, JSON.stringify(cmd));
   const n = rpc.filter(r => r.method === 'mutate').length; storageFailure = true;
   assert.equal((await gateway().send(ctx, cmd)).code, 'RESULT_UNKNOWN'); storageFailure = false;
   assert.equal(rpc.filter(r => r.method === 'mutate').length, n); assert.equal(wires.has(cmd.requestId), false);
 });
 await check('one bad row rejects entire read; cross-member, duplicate and malformed success cannot project', async () => {
   const valid = wireRow(envelope, 'ACCEPTED', 2);
   for (const invalid of [{ ...valid, planId: 'p2' }, { ...valid, proposerUid: 'other' },
     { ...valid, acceptedRevision: 2 }, { ...valid, protocolVersion: 2 }, { ...valid, state: 'UNKNOWN' }]) {
     readRows = [valid, invalid]; const result = await gateway().read(ctx);
     assert.equal(result.code, 'BAD_RECORD'); assert.equal(result.records.length, 0);
   }
   readRows = [valid, valid]; assert.equal((await gateway().read(ctx)).code, 'BAD_RECORD');
 });
 await check('identity/session switch during cloud request rejects even a valid response', async () => {
   readRows = [wireRow(envelope, 'ACCEPTED', 2)]; switchAfterRpc = true;
   assert.equal((await gateway().read(ctx)).code, 'SESSION_CHANGED'); switchAfterRpc = false; uid = 'device-a';
   local = { ...ctx, generation: 'gen-2' }; assert.equal((await gateway().send(ctx, command)).code, 'SECURE_SESSION_REQUIRED'); local = { ...ctx };
 });
 await check('complete shared-plan refresh uses one operation-scoped capability RPC, one read, and local UID fences', async () => {
   const fastIdentity = { ...identity, async currentUid() { return uid; } };
   const channel = new SecureSharedPlanGateway(fastIdentity, cloud, cipher, store, () => enabled);
   const persistence = { async current() { return true; }, async list() { return []; },
     async apply() { return true; }, async enqueue() {}, async pending() { return []; }, async finish() {} };
   const localCheck = { nowMin: () => 500, newId: () => 'new', async canArrange() { return true; }, async recompute() {} };
   const use = new SharedPlanUseCase(channel, persistence, localCheck);
   const before = rpc.length, authBefore = identityCalls;
   assert.equal(await use.refresh(), 'OK');
   assert.deepEqual(rpc.slice(before).map(r => r.method), ['capabilities', 'read']);
   assert.equal(identityCalls - authBefore, 2);
   const localBefore = rpc.length;
   assert.equal(await channel.current(ctx), true);
   uid = 'another-device'; assert.equal(await channel.current(ctx), false); uid = 'device-a';
   local = { ...ctx, generation: 'changed' }; assert.equal(await channel.current(ctx), false); local = { ...ctx };
   enabled = false; assert.equal(await channel.current(ctx), false); enabled = true;
   assert.equal(rpc.length, localBefore); assert.equal(identityCalls - authBefore, 2);
 });
 await check('local UID fence never authorizes an unverified context or signs in after logout', async () => {
   const fastIdentity = { ...identity, async currentUid() { return uid; } };
   const channel = new SecureSharedPlanGateway(fastIdentity, cloud, cipher, store, () => enabled);
   assert.equal(await channel.current(ctx), false);
   authUser = user('device-a'); const n = forceRefresh.length;
   assert.equal(await AnonymousIdentity.currentUid(), 'device-a');
   authUser = null; assert.equal(await AnonymousIdentity.currentUid(), '');
   authUser = user('signed', false); assert.equal(await AnonymousIdentity.currentUid(), '');
   assert.equal(forceRefresh.length, n);
 });
 await check('binding proof is reference-scoped, consumed once, and fresh on every following operation', async () => {
   const channel = new SecureSharedPlanGateway({ ...identity, async currentUid() { return uid; } }, cloud, cipher, store, () => enabled);
   const before = rpc.length;
   const prepared = await channel.context(); assert.ok(prepared);
   assert.equal((await channel.read(prepared)).code, 'OK');
   assert.deepEqual(rpc.slice(before).map(r => r.method), ['capabilities', 'read']);
   const repeated = rpc.length; assert.equal((await channel.read(prepared)).code, 'OK');
   assert.deepEqual(rpc.slice(repeated).map(r => r.method), ['capabilities', 'read']);
   const fresh = await channel.context(); const copied = rpc.length;
   assert.equal((await channel.read({ ...fresh })).code, 'OK');
   assert.deepEqual(rpc.slice(copied).map(r => r.method), ['capabilities', 'read']);
 });
 await check('prepared binding cannot survive logout, generation change or feature disable before send', async () => {
   const channel = new SecureSharedPlanGateway({ ...identity, async currentUid() { return uid; } }, cloud, cipher, store, () => enabled);
   const first = await channel.context(); const before = rpc.length; uid = '';
   assert.equal((await channel.read(first)).code, 'SECURE_SESSION_REQUIRED'); assert.equal(rpc.length, before); uid = 'device-a';
   const next = await channel.context(); local = { ...ctx, generation: 'changed' };
   assert.equal((await channel.read(next)).code, 'SECURE_SESSION_REQUIRED'); local = { ...ctx };
   const last = await channel.context(); enabled = false;
   assert.equal((await channel.read(last)).code, 'SECURE_SESSION_REQUIRED'); enabled = true;
 });
 await check('optimized send/read reject UID change during cloud response and local generation change during UID lookup', async () => {
   const fastIdentity = { ...identity, async currentUid() { return uid; } };
   const channel = new SecureSharedPlanGateway(fastIdentity, cloud, cipher, store, () => enabled);
   assert.deepEqual(JSON.parse(JSON.stringify(await channel.context())), ctx);
   switchAfterRpc = true;
   assert.equal((await channel.read(ctx)).code, 'SESSION_CHANGED'); uid = 'device-a';
   assert.equal((await channel.send(ctx, command)).code, 'SESSION_CHANGED');
   switchAfterRpc = false; uid = 'device-a';
   const lateIdentity = { ...identity, async currentUid() { local = { ...ctx, generation: 'changed' }; return uid; } };
   const lateChannel = new SecureSharedPlanGateway(lateIdentity, cloud, cipher, store, () => enabled);
   assert.equal(await lateChannel.context(), null); local = { ...ctx };
 });
 await check('complete propose retains durable-before-send ordering with one capability RPC', async () => {
   const fastIdentity = { ...identity, async currentUid() { return uid; } };
   const channel = new SecureSharedPlanGateway(fastIdentity, cloud, cipher, store, () => enabled);
   let nextId = 0, enqueued = false, finished = false;
   const persistence = { async current() { return true; }, async list() { return []; },
     async apply() { assert.ok(enqueued); return true; },
     async enqueue(c, draft) { enqueued = true; drafts.set(draft.requestId, JSON.stringify(draft)); },
     async pending() { return []; }, async finish() { finished = true; } };
   const checkLocal = { nowMin: () => 500, newId: () => nextId++ === 0 ? 'p1' : 'req-fast-propose',
     async canArrange() { return true; }, async recompute() {} };
   const use = new SharedPlanUseCase(channel, persistence, checkLocal);
   const before = rpc.length, authBefore = identityCalls;
   assert.equal(await use.propose(content), 'OK'); assert.ok(finished);
   assert.deepEqual(rpc.slice(before).map(r => r.method), ['capabilities', 'mutate']);
   assert.equal(identityCalls - authBefore, 2);
   assert.equal(rpc.at(-1).args[0], wires.get('req-fast-propose'));
 });
 await check('no secret is printed by production diagnostics', async () => {
   assert.ok(!JSON.stringify(logs).includes('token-device')); assert.ok(!JSON.stringify(logs).includes(content.title));
 });
 console.log(`shared-plan-secure: ${count} passed, 0 failed (Node adapters; NOT device HUKS/Auth/AGC)`);
}
main().catch(error => { console.error(error.stack); process.exitCode = 1; });
