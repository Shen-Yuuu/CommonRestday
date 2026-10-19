/** Real server + real ArkTS setup/coordinator/bridge. Only SDK/auth/HUKS storage are isolated. */
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import vm from 'node:vm';
import { createRequire } from 'node:module';
import { fileURLToPath } from 'node:url';
import { createECDH, createCipheriv, createDecipheriv, randomBytes, randomUUID, createHash } from 'node:crypto';
import { api, table } from './dateplan-contract.mjs';
const require = createRequire(import.meta.url), root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '../..');
const ts = require('D:/local/DevEcoStudio/tools/hvigor/hvigor/node_modules/typescript');
function source(rel, deps = {}) {
  const mod = { exports: {} };
  vm.runInNewContext(ts.transpileModule(fs.readFileSync(path.join(root, rel), 'utf8'), {
    compilerOptions: { target: ts.ScriptTarget.ES2021, module: ts.ModuleKind.CommonJS }
  }).outputText, { module: mod, exports: mod.exports, Date, Promise, require: n => {
    if (!(n in deps)) throw Error('Unexpected dependency ' + n); return deps[n];
  } });
  return mod.exports;
}
const diagnostics = source('commons/src/main/ets/util/PlanConnectionDiagnostic.ets');
const { SecurePairingUseCase } = source('feature/src/main/ets/usecase/SecurePairingUseCase.ets', { commons: diagnostics });
const { UnifiedPairingUseCase } = source('feature/src/main/ets/usecase/UnifiedPairingUseCase.ets');
const scheduleKey = randomBytes(32);
const keys = {
  async hasPairKey() { return true; },
  async seal(_pair, aad, plain) {
    const iv = randomBytes(12), cipher = createCipheriv('aes-256-gcm', scheduleKey, iv); cipher.setAAD(Buffer.from(aad));
    return { algorithm: 'AES-256-GCM', iv: iv.toString('base64'), authTag: '',
      ciphertext: Buffer.concat([cipher.update(plain, 'utf8'), cipher.final()]).toString('base64'),
      ...{ authTag: cipher.getAuthTag().toString('base64') } };
  },
  async open(_pair, aad, value) {
    try {
      const cipher = createDecipheriv('aes-256-gcm', scheduleKey, Buffer.from(value.iv, 'base64'));
      cipher.setAAD(Buffer.from(aad)); cipher.setAuthTag(Buffer.from(value.authTag, 'base64'));
      return Buffer.concat([cipher.update(Buffer.from(value.ciphertext, 'base64')), cipher.final()]).toString('utf8');
    } catch { return null; }
  }
};
const bridgeDeps = { './PairKeyStore': { PairKeyStore: keys }, './SnapshotCrypto': {},
  './SecurePlanKeyStore': { SecurePlanKeyStore: { async pairingRoute(pair) {
    return createHash('sha256').update('FORTWO_UNIFIED_PAIRING_V1|' + pair).digest('hex'); } } } };
const { PlanPairingBridge } = source('cloud/src/main/ets/api/PlanPairingBridge.ets', bridgeDeps);
const { PlanPartnerLink } = source('cloud/src/main/ets/api/PlanPartnerLink.ets', { './PairKeyStore': { PairKeyStore: keys } });
function device(uid, peerUid, token, legacyPair) {
  const f = { raw: '', session: null, keyPair: '', consent: false, paused: false, calls: [], losePublish: false, sealed: 0 };
  const publicKey = createECDH('prime256v1').generateKeys().toString('base64');
  const env = { enabled: () => true, cleanupEnabled: () => true, epoch: () => '0',
    anchor: () => 'PAIRED|' + legacyPair, nextId: () => randomUUID() };
  const secure = new SecurePairingUseCase({ async credential() { return { uid: 'auth-' + uid, accessToken: token }; } }, {
    async invoke(method, accessToken, args) {
      f.calls.push(method); const reply = await api[method](accessToken, ...args);
      if (method === 'publishLink' && f.losePublish) { f.losePublish = false; throw Error('Lost response after commit'); }
      return JSON.stringify(reply);
    }
  }, {
    async publicKey() { return publicKey; },
    async sealProof(_uid, _flow, secret) { return JSON.stringify(await keys.seal(legacyPair, 'local-proof-' + uid, secret)); },
    async openProof(_uid, _flow, raw) { return keys.open(legacyPair, 'local-proof-' + uid, JSON.parse(raw)); },
    async agree(_uid, pair) { f.keyPair = pair; }, async available(pair) { return f.keyPair === pair; },
    async dropProof() {}, async drop() { f.keyPair = ''; },
    linkProof: (key, flow) => PlanPartnerLink.create(legacyPair, key, flow),
    verifyLink: (key, proof) => PlanPartnerLink.verify(legacyPair, key, proof)
  }, {
    async load() { return f.raw; }, async hasCleanup() { return false; },
    async save(before, next) { if (f.raw !== before) return false; f.raw = next; return true; },
    async activate(before, next, session) { if (f.raw !== before) return false; f.raw = next; f.session = session; return true; },
    async revoke(before, next) { if (f.raw !== before) return false; f.raw = next; f.session = null; return true; }
  }, env);
  const port = {
    enabled: () => true, async context() { return { pairId: legacyPair, uid, peerUid, epoch: '0' }; },
    consented: () => f.consent, paused: () => f.paused, async pause() { f.paused = true; },
    async consent() { f.consent = true; f.paused = false; },
    async state() { const result = await secure.local(); const row = f.raw ? JSON.parse(f.raw) : null;
      return { result, creator: row?.role === 'CREATOR', anchor: row?.anchor ?? '' }; },
    async ready() { return f.session !== null && f.keyPair === f.session.pairId; },
    create: () => secure.create(), resume: () => secure.resume(), confirm: () => secure.confirm(),
    join: value => secure.joinLinked(value.inviteCode, value.pairId, value.publicKey),
    async publish() {
      return secure.publishLink(await PlanPairingBridge.route(legacyPair), async state => {
        f.sealed++; return PlanPairingBridge.seal(legacyPair, uid, peerUid,
          { pairId: state.pairId, publicKey: state.publicKey, inviteCode: state.inviteCode, expiresAt: state.expiresAt });
      });
    },
    async discover() {
      const reply = await api.discoverLink(token, await PlanPairingBridge.route(legacyPair));
      if (reply.code !== 'OK') return { code: reply.code, offers: [] };
      const offers = [];
      for (const wire of reply.offers) {
        const opened = await PlanPairingBridge.open(legacyPair, peerUid, uid, wire.offer);
        if (opened && opened.pairId === wire.pairId && opened.publicKey === wire.publicKey) offers.push(opened);
      }
      return { code: 'OK', offers };
    }
  };
  f.make = () => new UnifiedPairingUseCase(port); f.uc = f.make(); f.secure = secure; return f;
}
let passed = 0;
async function test(name, fn) { await fn(); console.log('PASS ' + name); passed++; }
await test('production handshake activates same secure pair with distinct authenticated actors', async () => {
  const a = device('a', 'b', 'token-A', 'integration-one'), b = device('b', 'a', 'token-B', 'integration-one');
  assert.equal((await a.uc.advance(true)).phase, 'WAITING');
  assert.equal((await b.uc.advance(true)).phase, 'WAITING');
  assert.equal((await a.uc.advance()).phase, 'READY');
  assert.equal((await b.uc.advance()).phase, 'READY');
  assert.equal(a.session.pairId, b.session.pairId); assert.notEqual(a.session.actorId, b.session.actorId);
  assert.equal(table('PairMemberBinding').get(a.session.pairId).row.getStatus(), 'ACTIVE');
  assert.equal(table('PairMemberBinding').get(a.session.pairId).row.getBootstrapOffer(), '');
  assert.equal(a.calls.filter(v => v === 'confirmPair').length, 1);
  assert.equal(b.calls.filter(v => v === 'joinPair').length, 1);
  const count = a.calls.length; await a.uc.advance(); assert.equal(a.calls.length, count);
});
await test('committed publish with lost reply pauses and resumes original ciphertext after restart', async () => {
  const a = device('a', 'b', 'token-A', 'integration-lost'), b = device('b', 'a', 'token-B', 'integration-lost');
  a.losePublish = true;
  assert.equal((await a.uc.advance(true)).phase, 'FAILED');
  const initial = JSON.parse(a.raw), cipher = initial.bootstrapOffer;
  a.uc = a.make(); const count = a.calls.length;
  assert.equal((await a.uc.advance()).code, 'RETRY_REQUIRED'); assert.equal(a.calls.length, count);
  assert.equal((await a.uc.advance(true)).phase, 'WAITING');
  assert.equal(JSON.parse(a.raw).pairId, initial.pairId); assert.equal(JSON.parse(a.raw).bootstrapOffer, cipher);
  assert.equal(a.sealed, 1);
  await b.uc.advance(true); assert.equal((await a.uc.advance()).phase, 'READY');
  assert.equal((await b.uc.advance()).phase, 'READY');
});
console.log(`dateplan unified integration: ${passed} passed, 0 failed (isolated ports, not real HUKS/cloud deployment)`);
