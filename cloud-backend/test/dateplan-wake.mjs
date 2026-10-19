/** Actual server dispatch/wake control flow, isolated CAS storage and fake provider. No cloud requests. */
import assert from 'node:assert/strict';
import { api, env, table, paired, proposed, mutation, load, models } from './dateplan-contract.mjs';
const push = load('push'); const wake = load('wake'); let passed = 0;
async function test(name, work) { await work(); passed++; console.log('PASS ' + name); }
env.FORTWO_ENABLE_PLAN_PUSH = 'false'; env.FORTWO_PLAN_STORAGE_V2 = 'true';
env.FORTWO_PLAN_DISPATCH_SECRET = 'isolated-wake-secret-' + 'x'.repeat(40);
const eventFor = pair => [...table('PairPlanOutbox').values()].map(e => e.row).filter(e => e.pairId === pair);
const invoke = (event, logger = { info() {} }) => new Promise(resolve => wake.handler(event, {}, resolve, logger));
const input = id => ({ objectTypeName: 'PairPlanWake', naturalStoreName: 'FortwoPlanProbe', records: [{ before: null, after: { id } }] });
await test('exact committed event wins over older obsolete backlog; terminal delivery releases active capacity', async () => {
  const pair = await paired('wake-exact'); await proposed(pair, 'wake-plan', 'wake-create');
  await api.mutate('token-B', mutation(pair, 'wake-plan', 'wake-accept', 'ACCEPT', 1));
  const rows = eventFor(pair); const latest = rows.find(e => e.stateVersion === 2); const seen = [];
  env.FORTWO_ENABLE_PLAN_PUSH = 'true'; await api.registerPush('token-A', pair, 'fake-token', true);
  assert.equal(await push.dispatchEvent(latest.id, { async send(token, kind, id) { seen.push(id); return true; } }), 1);
  assert.deepEqual(seen, [latest.id]);
  assert.equal(await push.dispatchEvent(latest.id, { async send() { throw Error('duplicate send'); } }), 0);
  assert.equal(table('PairPlanSyncState').get(pair).row.eventCount, 0);
  assert.ok(table('PairPlanEventArchive').has(latest.id)); env.FORTWO_ENABLE_PLAN_PUSH = 'false';
});
await test('wake path awaits durable insert but does not await provider; worker verifies stored signature and deduplicates', async () => {
  const pair = await paired('wake-durable'); await proposed(pair, 'wake-durable-plan', 'wake-durable-create');
  const id = eventFor(pair)[0].id;
  env.FORTWO_ENABLE_PLAN_PUSH = 'true'; env.FORTWO_PLAN_ASYNC_PUSH = 'true';
  const original = push.dispatchEvent; let called = 0; let release;
  push.dispatchEvent = () => { called++; return new Promise(r => { release = r; }); };
  try {
    assert.equal(await wake.enqueueWake(id), true); assert.equal(called, 0);
    const row = [...table('PairPlanWake').values()].map(e => e.row).find(e => e.eventId === id);
    assert.ok(row); const work = invoke(input(row.id));
    for (let i = 0; i < 15 && !release; i++) await Promise.resolve();
    assert.equal(called, 1); assert.ok(table('PairPlanWake').has(row.id)); release(1);
    assert.equal((await work).providerAccepted, 1); assert.equal(table('PairPlanWake').has(row.id), false);
    assert.equal((await invoke(input(row.id))).providerAccepted, 0); assert.equal(called, 1);
  } finally { push.dispatchEvent = original; env.FORTWO_ENABLE_PLAN_PUSH = 'false'; env.FORTWO_PLAN_ASYNC_PUSH = 'false'; }
});
await test('malformed trigger, wrong model/zone, forged persisted proof and timer-shaped input never send', async () => {
  const pair = await paired('wake-forged'); const row = new models.PairPlanWake();
  row.setId('aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa'); row.setPairId(pair); row.setEventId('a'.repeat(64));
  row.setCreatedAt(Date.now()); row.setProof('0'.repeat(64)); table('PairPlanWake').set(row.id, { row, epoch: 0 });
  const original = push.dispatchEvent; let count = 0; const logs = [];
  push.dispatchEvent = async () => { count++; return 1; };
  try {
    for (const event of [input(row.id), { ...input(row.id), objectTypeName: 'PairPlanOutbox' },
      { ...input(row.id), naturalStoreName: 'Other' }, { dispatchSecret: env.FORTWO_PLAN_DISPATCH_SECRET },
      { ...input(row.id), records: Array(9).fill(input(row.id).records[0]) }]) {
      assert.equal((await invoke(event, { info(s) { logs.push(s); } })).code, 'WAKE_REJECTED');
    }
    assert.equal(count, 0); assert.ok(table('PairPlanWake').has(row.id));
    assert.ok(logs.every(s => !s.includes(row.id) && !s.includes(env.FORTWO_PLAN_DISPATCH_SECRET)));
  } finally { push.dispatchEvent = original; }
});
await test('mutation queues the exact committed event with opt-in, and a wake failure keeps committed success', async () => {
  const pair = await paired('wake-mutation'); const original = push.dispatchEvent; let calls = 0;
  push.dispatchEvent = async () => { calls++; throw new Error('private provider error'); };
  env.FORTWO_ENABLE_PLAN_PUSH = 'true'; env.FORTWO_PLAN_ASYNC_PUSH = 'true';
  try {
    const result = await proposed(pair, 'wake-new', 'wake-new-create'); assert.equal(result.code, 'OK'); assert.equal(calls, 0);
    assert.ok([...table('PairPlanWake').values()].some(e => e.row.pairId === pair));
    env.FORTWO_PLAN_DISPATCH_SECRET = 'invalid';
    assert.equal((await api.mutate('token-A', mutation(pair, 'wake-new', 'wake-new-withdraw', 'WITHDRAW', 1))).code, 'OK');
    assert.equal(calls, 1);
  } finally { push.dispatchEvent = original; env.FORTWO_ENABLE_PLAN_PUSH = 'false'; env.FORTWO_PLAN_ASYNC_PUSH = 'false'; }
});
console.log(`dateplan wake: ${passed} passed, 0 failed (NOT automatic trigger/device evidence)`);
