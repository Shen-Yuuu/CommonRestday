/** Production server contracts with CAS/storage fixtures. No cloud deploy or live requests. */
import assert from 'node:assert/strict';
import { api, env, table, paired, proposed, mutation, envelope, models, load, sdkRead } from './dateplan-contract.mjs';
env.FORTWO_ENABLE_PLAN_PUSH = 'false';
let passed = 0;
async function test(name, work) { await work(); passed++; console.log('PASS ' + name); }
await test('storage-v2 is explicitly gated and does not change legacy reads', async () => {
  const pair = await paired('storage-closed');
  assert.equal((await api.readChanges('token-A', pair, 0)).code, 'FEATURE_DISABLED');
  assert.equal((await api.read('token-A', pair)).code, 'OK');
});
env.FORTWO_PLAN_STORAGE_V2 = 'true';
await test('actual SDK Long strings are exposed as safe numeric counters and increment 9 to 10', async () => {
  for (const name of ['PairPlanSyncState', 'PairPlanChange', 'PairPlanArchive', 'PairPlanArchiveVote',
    'PairPlanReceiptArchive', 'PairPlanEventArchive', 'PairPlanWake']) {
    const row = new models[name]();
    for (const [field, type] of row.getFieldTypeMap()) if (type === 'Long') row[field] = 11;
    const hydrated = sdkRead(row);
    for (const [field, type] of row.getFieldTypeMap()) if (type === 'Long') {
      const getter = 'get' + field[0].toUpperCase() + field.slice(1);
      assert.equal(hydrated[getter](), 11, name + '.' + getter + ' decodes the SDK string (including signed-wake timestamps)');
    }
  }
  const model = new models.PairPlanSyncState(); model.setId('fixture'); model.setPairId('fixture');
  model.setSequence(9); model.setCreatorAck(0); model.setRecipientAck(Number.MAX_SAFE_INTEGER);
  const decoded = sdkRead(model);
  assert.equal(typeof decoded.sequence, 'string', 'exercise actual SDK wire representation');
  assert.equal(decoded.getSequence(), 9); assert.equal(decoded.getCreatorAck(), 0);
  assert.equal(decoded.getRecipientAck(), Number.MAX_SAFE_INTEGER);
  for (const value of ['', ' ', '01', '1e2', '1.5', '-1', '9007199254740992', null, undefined, true, {}, -1, Infinity, NaN]) {
    const row = new models.PairPlanSyncState(); row.sequence = value;
    assert.ok(Number.isNaN(row.getSequence()), 'invalid Long cannot silently become zero or a rounded integer');
  }
  const pair = await paired('sdk-long-increment');
  for (let i = 0; i < 10; i++) await proposed(pair, 'sdk-plan-' + i, 'sdk-create-' + i);
  const page = await api.readChanges('token-B', pair, 0);
  assert.equal(page.code, 'OK'); assert.equal(page.cursor, 10); assert.equal(typeof page.cursor, 'number');
  assert.equal(table('PairPlanSyncState').get(pair).row.getSequence(), 10, 'not decimal concatenation 91');
  assert.equal(page.plans.length, 10);
});
await test('invalid counters retain rows and original request can recover after a valid typed read', async () => {
  const pair = await paired('sdk-long-recovery');
  await load('storage-v2').initializeStorage(pair);
  const head = table('PairPlanSyncState').get(pair).row;
  head.creatorAck = ''; // Genuine bad data must still fail closed, unlike canonical SDK text "0".
  const command = mutation(pair, 'recover-plan', 'recover-request', 'PROPOSE', 0, envelope());
  assert.equal((await api.mutate('token-A', command)).code, 'BAD_COUNTER');
  assert.equal([...table('PairDatePlan').values()].filter(e => e.row.pairId === pair).length, 0);
  assert.equal([...table('PairPlanRequest').values()].filter(e => e.row.pairId === pair).length, 0);
  head.creatorAck = '0'; head.recipientAck = '0'; head.sequence = '0';
  assert.equal((await api.requestStatus('token-A', command)).code, 'REQUEST_NOT_COMMITTED');
  const made = await api.mutate('token-A', command); assert.equal(made.code, 'OK');
  assert.deepEqual(await api.requestStatus('token-A', command), made);
  assert.deepEqual(await api.mutate('token-A', command), made, 'same immutable receipt, not another invitation');
  assert.equal(table('PairPlanSyncState').get(pair).row.getPlanCount(), 1);
  assert.equal(table('PairPlanSyncState').get(pair).row.getRequestCount(), 1);
});
await test('change pages are ordered, scoped, authenticated and bounded', async () => {
  const pair = await paired('changes-v2');
  await proposed(pair, 'delta-one', 'delta-create');
  const page = await api.readChanges('token-B', pair, 0);
  assert.equal(page.code, 'OK'); assert.equal(page.syncVersion, 2);
  assert.equal(page.plans.length, 1); assert.ok(page.cursor > 0);
  assert.equal(page.plans[0].planId, 'delta-one');
  const equal = await api.readChanges('token-B', pair, page.cursor);
  assert.equal(equal.code, 'OK'); assert.equal(equal.plans.length, 0); assert.equal(equal.more, false);
  assert.equal((await api.readChanges('token-C', pair, 0)).code, 'FORBIDDEN');
  assert.equal((await api.readChanges('token-B', pair, page.cursor + 100)).code, 'BAD_CURSOR');
});
await test('two members must archive the same closed version and preserve request replay', async () => {
  const pair = await paired('archive-v2');
  await proposed(pair, 'archive-one', 'archive-create');
  assert.equal((await api.mutate('token-A', mutation(pair, 'archive-one', 'archive-withdraw', 'WITHDRAW', 1))).code, 'OK');
  const page = await api.readChanges('token-A', pair, 0);
  const vote = JSON.stringify([{ planId: 'archive-one', stateVersion: 2 }]);
  assert.equal((await api.acknowledge('token-A', pair, page.cursor, vote)).code, 'OK');
  assert.ok([...table('PairDatePlan').values()].some(entry => entry.row.pairId === pair));
  assert.equal((await api.acknowledge('token-B', pair, page.cursor, vote)).code, 'OK');
  assert.equal([...table('PairDatePlan').values()].filter(entry => entry.row.pairId === pair).length, 0);
  assert.equal([...table('PairPlanArchive').values()].filter(entry => entry.row.pairId === pair).length, 1);
  assert.equal((await api.mutate('token-A', mutation(pair, 'archive-one', 'archive-recreate', 'PROPOSE', 0, envelope()))).code,
    'VERSION_CONFLICT');
  assert.equal((await api.mutate('token-A', mutation(pair, 'archive-one', 'archive-withdraw', 'WITHDRAW', 1))).code, 'OK');
});
await test('over fifty lifetime plans and two hundred receipts keep immutable idempotent proof', async () => {
  const pair = await paired('lifetime-v2');
  let first;
  for (let i = 0; i < 110; i++) {
    const plan = 'history-' + i;
    const made = await proposed(pair, plan, 'history-create-' + i);
    if (i === 0) first = made;
    assert.equal((await api.mutate('token-A', mutation(pair, plan, 'history-withdraw-' + i, 'WITHDRAW', 1))).code, 'OK');
    const page = await api.readChanges('token-A', pair, 0);
    const cursor = table('PairPlanSyncState').get(pair).row.getSequence();
    const vote = JSON.stringify([{ planId: plan, stateVersion: 2 }]);
    assert.equal((await api.acknowledge('token-A', pair, cursor, vote)).code, 'OK');
    assert.equal((await api.acknowledge('token-B', pair, cursor, vote)).code, 'OK');
    assert.ok(page.plans.length <= 50);
  }
  const head = table('PairPlanSyncState').get(pair).row;
  assert.equal(head.planCount, 0); assert.ok(head.requestCount < 200);
  assert.equal([...table('PairPlanArchive').values()].filter(e => e.row.pairId === pair).length, 110);
  assert.ok([...table('PairPlanReceiptArchive').values()].some(e => e.row.pairId === pair));
  const replay = await api.mutate('token-A', mutation(pair, 'history-0', 'history-create-0', 'PROPOSE', 0, envelope()));
  assert.deepEqual(replay, first);
  const resolved = await api.requestStatus('token-A', mutation(pair, 'history-0', 'history-create-0', 'PROPOSE', 0, envelope()));
  assert.deepEqual(resolved, first, 'explicit original-request verification must also use archived proofs');
  assert.equal(head.eventCount, 0, 'fully acknowledged closed plans release obsolete notifications too');
  let cursor = 0; const ids = []; const lengths = [];
  do {
    const page = await api.readChanges('token-B', pair, cursor); assert.equal(page.code, 'OK');
    lengths.push(page.plans.length); ids.push(...page.plans.map(row => row.planId));
    assert.ok(page.cursor > cursor); cursor = page.cursor;
    if (!page.more) break;
  } while (lengths.length < 10);
  assert.deepEqual(lengths, [50, 50, 10]); assert.equal(new Set(ids).size, 110); assert.equal(cursor, head.getSequence());
  const changed = await api.mutate('token-A', mutation(pair, 'history-0', 'history-create-0', 'PROPOSE', 0, envelope(1, 'different')));
  assert.equal(changed.code, 'REQUEST_REUSED');
});
await test('pending amendments and stale versions cannot satisfy both-member archival', async () => {
  const pair = await paired('archive-amendment'); await proposed(pair, 'amended-plan', 'amended-create');
  await api.mutate('token-B', mutation(pair, 'amended-plan', 'amended-accept', 'ACCEPT', 1));
  const page = await api.readChanges('token-A', pair, 0);
  const old = JSON.stringify([{ planId: 'amended-plan', stateVersion: 2 }]);
  await api.acknowledge('token-A', pair, page.cursor, old);
  await api.mutate('token-A', mutation(pair, 'amended-plan', 'amended-next', 'AMEND', 2, envelope(2)));
  assert.equal((await api.acknowledge('token-B', pair, page.cursor, old)).archived, 0);
  const next = await api.readChanges('token-B', pair, page.cursor);
  const pending = JSON.stringify([{ planId: 'amended-plan', stateVersion: 3 }]);
  assert.equal((await api.acknowledge('token-A', pair, next.cursor, pending)).archived, 0);
  assert.equal((await api.acknowledge('token-B', pair, next.cursor, pending)).archived, 0);
  assert.ok([...table('PairDatePlan').values()].some(e => e.row.pairId === pair));
});
await test('active provider lease survives both archive votes and late finish releases exactly one event', async () => {
  const pair = await paired('archive-lease'); await proposed(pair, 'lease-plan', 'lease-create');
  await api.mutate('token-B', mutation(pair, 'lease-plan', 'lease-accept', 'ACCEPT', 1));
  await api.registerPush('token-A', pair, 'isolated-token', true);
  const event = [...table('PairPlanOutbox').values()].find(e => e.row.pairId === pair).row;
  let release; let started; const signal = new Promise(r => { started = r; });
  env.FORTWO_ENABLE_PLAN_PUSH = 'true';
  const send = load('push').dispatchEvent(event.id, { async send() { started(); return new Promise(r => { release = r; }); } });
  await signal;
  const cursor = (await api.readChanges('token-A', pair, 0)).cursor;
  const vote = JSON.stringify([{ planId: 'lease-plan', stateVersion: 2 }]);
  await api.acknowledge('token-A', pair, cursor, vote); await api.acknowledge('token-B', pair, cursor, vote);
  assert.ok(table('PairPlanOutbox').has(event.id)); assert.equal(table('PairPlanSyncState').get(pair).row.eventCount, 1);
  release(true); await send; assert.equal(table('PairPlanSyncState').get(pair).row.eventCount, 0);
  env.FORTWO_ENABLE_PLAN_PUSH = 'false';
});
await test('large encrypted cleanup batches are byte bounded and retain incomplete verdict', async () => {
  const pair = await paired('large-cleanup'); await proposed(pair, 'large-cleanup-plan', 'large-cleanup-create');
  for (let i = 0; i < 90; i++) {
    const row = new models.PairPlanArchive(); row.setId('large-' + i); row.setPairId(pair);
    row.setRecordJson('x'.repeat(130000)); table('PairPlanArchive').set(row.id, { row, epoch: i });
  }
  let result = await api.unpair('token-A', pair); assert.equal(result.code, 'CLEANUP_PENDING');
  for (let i = 0; result.code === 'CLEANUP_PENDING' && i < 20; i++) result = await api.unpair('token-A', pair);
  assert.equal(result.code, 'OK'); assert.equal([...table('PairPlanArchive').values()].filter(e => e.row.pairId === pair).length, 0);
});
await test('large canonical receipts revoke first and finish deletion before declaring archive cleanup complete', async () => {
  const pair = await paired('canonical-cleanup'); await proposed(pair, 'canonical-plan', 'canonical-create');
  for (let i = 0; i < 30; i++) {
    const row = new models.PairPlanRequest(); row.setId('canonical-' + i); row.setPairId(pair);
    row.setResponse('x'.repeat(130000)); table('PairPlanRequest').set(row.id, { row, epoch: i });
  }
  let result = await api.unpair('token-A', pair); assert.equal(result.code, 'CLEANUP_PENDING');
  assert.equal(table('PairMemberBinding').get(pair).row.status, 'REVOKED');
  assert.ok([...table('PairPlanRequest').values()].some(e => e.row.pairId === pair));
  for (let i = 0; result.code === 'CLEANUP_PENDING' && i < 20; i++) result = await api.unpair('token-A', pair);
  assert.equal(result.code, 'OK'); assert.ok(![...table('PairPlanRequest').values()].some(e => e.row.pairId === pair));
});
await test('storage rollout cannot downgrade a migrated pair or permit resurrected IDs', async () => {
  const pair = await paired('sticky-storage');
  await proposed(pair, 'sticky-plan', 'sticky-create');
  await api.mutate('token-A', mutation(pair, 'sticky-plan', 'sticky-withdraw', 'WITHDRAW', 1));
  const page = await api.readChanges('token-A', pair, 0);
  const vote = JSON.stringify([{ planId: 'sticky-plan', stateVersion: 2 }]);
  await api.acknowledge('token-A', pair, page.cursor, vote); await api.acknowledge('token-B', pair, page.cursor, vote);
  env.FORTWO_PLAN_STORAGE_V2 = 'false';
  assert.equal((await api.readChanges('token-A', pair, page.cursor)).code, 'OK');
  assert.equal((await api.mutate('token-A', mutation(pair, 'sticky-plan', 'sticky-resurrect', 'PROPOSE', 0, envelope()))).code,
    'VERSION_CONFLICT');
  env.FORTWO_PLAN_STORAGE_V2 = 'true';
});
await test('unfinished paged deletion retains a cleanup-pending verdict until every archive is gone', async () => {
  const pair = await paired('paged-cleanup'); await proposed(pair, 'cleanup-plan', 'cleanup-create');
  for (let i = 0; i < 170; i++) {
    const row = new models.PairPlanArchive(); row.setId('cleanup-' + i); row.setPairId(pair);
    row.setRecordJson('{}'); table('PairPlanArchive').set(row.getId(), { row, epoch: i });
  }
  let result = await api.unpair('token-A', pair);
  assert.equal(result.code, 'CLEANUP_PENDING');
  assert.equal((await api.pairStatus('token-B', pair)).code, 'CLEANUP_PENDING', 'must not drop credentials prematurely');
  for (let attempts = 0; result.code === 'CLEANUP_PENDING' && attempts < 20; attempts++) result = await api.unpair('token-A', pair);
  assert.equal(result.code, 'OK');
  assert.equal([...table('PairPlanArchive').values()].filter(e => e.row.pairId === pair).length, 0);
  assert.equal((await api.pairStatus('token-B', pair)).code, 'SESSION_REVOKED');
});
await test('closed request proofs share V2 capacity accounting without adding plans, changes or events', async () => {
  const pair = await paired('closed-v2'); const cmd = mutation(pair, 'never-plan', 'never-send', 'PROPOSE', 0, envelope());
  assert.equal((await api.closeRequest('token-A', cmd)).code, 'REQUEST_CLOSED');
  const head = table('PairPlanSyncState').get(pair).row;
  assert.equal(head.getRequestCount(), 1); assert.equal(head.getPlanCount(), 0);
  assert.equal(head.getSequence(), 0); assert.equal(head.getEventCount(), 0);
  assert.equal((await api.readChanges('token-B', pair, 0)).plans.length, 0);
  // Exercise the real compactor, not a hand-constructed archive proof.
  for (let i = 0; i < 150; i++) {
    const other = mutation(pair, 'none-' + i, 'closed-' + i, 'PROPOSE', 0, envelope());
    assert.equal((await api.closeRequest('token-A', other)).code, 'REQUEST_CLOSED');
  }
  assert.ok([...table('PairPlanReceiptArchive').values()].some(e => e.row.pairId === pair));
  assert.equal((await api.requestStatus('token-A', cmd)).code, 'REQUEST_CLOSED');
  assert.equal((await api.mutate('token-A', cmd)).code, 'REQUEST_CLOSED');
  assert.equal(head.getPlanCount(), 0);
});
console.log(`dateplan storage-v2: ${passed} passed, 0 failed (isolated server/storage; NOT deployment evidence)`);
