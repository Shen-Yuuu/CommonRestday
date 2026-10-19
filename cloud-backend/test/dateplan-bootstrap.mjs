import assert from 'node:assert/strict';
import { api, env, table } from './dateplan-contract.mjs';
import { createECDH } from 'node:crypto';
const key = createECDH('prime256v1').generateKeys().toString('base64');
const route = 'a'.repeat(64);
const offer = JSON.stringify({ algorithm: 'AES-256-GCM', iv: Buffer.alloc(12).toString('base64'),
  authTag: Buffer.alloc(16).toString('base64'), ciphertext: Buffer.from('opaque handoff').toString('base64') });
let passed = 0;
async function test(name, fn) { await fn(); console.log('PASS ' + name); passed++; }
const made = await api.createPair('token-A', 'bootstrap-create', key, 1, 'encrypted-partner-proof');
await test('only authenticated creator can publish an encrypted offer', async () => {
  assert.equal((await api.publishLink('invalid', made.pairId, route, offer)).code, 'AUTH_REJECTED');
  assert.equal((await api.publishLink('token-B', made.pairId, route, offer)).code, 'FORBIDDEN');
  assert.equal((await api.publishLink('token-A', made.pairId, route, offer)).code, 'OK');
  assert.equal((await api.publishLink('token-A', made.pairId, route, offer)).code, 'OK');
});
await test('discovery returns encrypted handoff, never code/proof/actor identity', async () => {
  const reply = await api.discoverLink('token-B', route);
  assert.equal(reply.code, 'OK'); assert.equal(reply.offers.length, 1);
  assert.deepEqual(Object.keys(reply.offers[0]).sort(), ['offer', 'pairId', 'publicKey']);
  assert.equal(reply.offers[0].offer, offer);
  assert.ok(!JSON.stringify(reply).includes(made.inviteCode));
  assert.ok(!JSON.stringify(reply).includes(made.confirmSecret));
  assert.equal((await api.discoverLink('invalid', route)).code, 'AUTH_REJECTED');
});
await test('route and encrypted offer are immutable, malformed payloads reject', async () => {
  assert.equal((await api.publishLink('token-A', made.pairId, 'b'.repeat(64), offer)).code, 'REQUEST_REUSED');
  assert.equal((await api.publishLink('token-A', made.pairId, route, offer.replace('opaque', 'other'))).code, 'OK');
  const other = JSON.stringify({ ...JSON.parse(offer), ciphertext: Buffer.from('other').toString('base64') });
  assert.equal((await api.publishLink('token-A', made.pairId, route, other)).code, 'REQUEST_REUSED');
  assert.equal((await api.publishLink('token-A', made.pairId, route, '123456')).code, 'BAD_REQUEST');
  assert.equal((await api.discoverLink('token-B', 'not-a-route')).code, 'BAD_REQUEST');
});
await test('confirmation clears offer and prevents rediscovery or republishing', async () => {
  await api.joinPair('token-B', made.inviteCode, key, 1, 'encrypted-peer-proof');
  assert.equal((await api.confirmPair('token-A', made.pairId, made.confirmSecret)).code, 'OK');
  assert.equal((await api.discoverLink('token-B', route)).offers.length, 0);
  assert.equal((await api.publishLink('token-A', made.pairId, route, offer)).code, 'STATE_CONFLICT');
  assert.equal(table('PairMemberBinding').get(made.pairId).row.getBootstrapOffer(), '');
});
await test('revocation clears route and cannot resurrect setup', async () => {
  assert.equal((await api.unpair('token-A', made.pairId)).code, 'OK');
  const row = table('PairMemberBinding').get(made.pairId).row;
  assert.equal(row.getBootstrapRoute(), ''); assert.equal(row.getBootstrapOffer(), '');
  assert.equal((await api.publishLink('token-A', made.pairId, route, offer)).code, 'SESSION_REVOKED');
});
await test('closed gate has no bootstrap path', async () => {
  env.FORTWO_ENABLE_SHARED_PLAN_V1 = 'false';
  assert.equal((await api.discoverLink('token-A', route)).code, 'FEATURE_DISABLED');
  env.FORTWO_ENABLE_SHARED_PLAN_V1 = 'true';
});
console.log(`dateplan bootstrap: ${passed} passed, 0 failed (offline)`);
