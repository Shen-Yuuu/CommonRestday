import { CloudDBCollection, Transaction } from '@hw-agconnect/cloud-server';
import { randomBytes, randomInt, timingSafeEqual } from 'crypto';
import { client, digest, Rejection, zoneName } from './identity';
import { PairMemberBinding, PairDatePlan, PairPlanRequest, PairPlanOutbox, PairPushTarget, PairPlanArchiveVote } from './models';
import { Command, checkEnvelope, MAX_PLANS, MAX_REQUESTS, MAX_EVENTS, PAIR_TTL, PENDING_TTL,
  planBody, transition, validId, validPublicKey } from './protocol';
import { usesStorage, initializeStorage, storageHead, appendChange, saveHead, findArchivedReceipt,
  archivedPlanExists, prepareReceiptBatch, commitReceiptBatch, changePage,
  acknowledge as archiveAcknowledgement, cleanupStorageBatch, eventArchive } from './storage-v2';

function collections() {
  const db = client().database({ zoneName: zoneName() });
  return { bindings: db.collection(PairMemberBinding), plans: db.collection(PairDatePlan),
    requests: db.collection(PairPlanRequest), outbox: db.collection(PairPlanOutbox), targets: db.collection(PairPushTarget),
    votes: db.collection(PairPlanArchiveVote) };
}
function copy<T>(row: T, Model: new () => T): T {
  return Object.assign(new Model() as Object, row) as T;
}
function touch(row: PairMemberBinding): void {
  if (row.getRevision() >= 2147483646) throw new Rejection('VERSION_LIMIT');
  row.setRevision(row.getRevision() + 1); row.setUpdatedAt(Date.now());
}
function member(row: PairMemberBinding, who: string, active = true): void {
  if (row.getCreatorSubject() !== who && row.getRecipientSubject() !== who) throw new Rejection('FORBIDDEN');
  if (row.getStatus() === 'REVOKED') throw new Rejection(row.getCleanupPending() ? 'CLEANUP_PENDING' : 'SESSION_REVOKED');
  if (active && row.getStatus() !== 'ACTIVE') throw new Rejection('PAIR_NOT_ACTIVE');
  if (row.getStatus() !== 'ACTIVE' && row.getExpiresAt() <= Date.now()) throw new Rejection('CODE_EXPIRED');
  if (row.getProtocolVersion() !== 1 || row.getProjectionVersion() !== 1) throw new Rejection('CAPABILITY_UNAVAILABLE');
}
function body(row: PairMemberBinding, who: string): Record<string, Object> {
  return { code: 'OK', pairId: row.getId(), status: row.getStatus(), myUid: who,
    peerUid: who === row.getCreatorSubject() ? row.getRecipientSubject() : row.getCreatorSubject(),
    peerPublicKey: who === row.getCreatorSubject() ? row.getRecipientKey() : row.getCreatorKey(),
    peerLink: who === row.getCreatorSubject() ? row.getRecipientLink() : row.getCreatorLink(),
    protocolVersion: 1, projectionVersion: 1, sharedPlanReady: row.getStatus() === 'ACTIVE',
    expiresAt: row.getExpiresAt(), revision: row.getRevision(), syncVersion: usesStorage(row) ? 2 : 1 };
}
async function getBinding(db: CloudDBCollection<PairMemberBinding>, pairId: string): Promise<PairMemberBinding> {
  if (!validId(pairId)) throw new Rejection('BAD_REQUEST');
  const rows = await db.query().equalTo('id', pairId).get();
  if (rows.length !== 1) throw new Rejection('NOT_FOUND');
  return rows[0];
}
async function txBinding(tx: Transaction, db: CloudDBCollection<PairMemberBinding>, pairId: string): Promise<PairMemberBinding> {
  const rows = await tx.executeQuery(db.query().equalTo('id', pairId));
  if (rows.length !== 1) throw new Rejection('NOT_FOUND');
  return copy(rows[0], PairMemberBinding);
}
function proofMatches(expected: string, proof: string): boolean {
  if (typeof proof !== 'string' || proof.length > 100 || expected.length !== 64) return false;
  return timingSafeEqual(Buffer.from(expected, 'hex'), Buffer.from(digest([proof]), 'hex'));
}

/** A create retry rotates the creator-only proof; lost replies do not orphan an unconfirmed pair. */
export async function createPair(who: string, requestId: string, publicKey: string, projectionVersion: number, link = '') {
  if (typeof link !== 'string' || link.length > 4096) throw new Rejection('BAD_REQUEST');
  if (!validId(requestId) || !validPublicKey(publicKey) || projectionVersion !== 1) throw new Rejection('BAD_REQUEST');
  const db = collections();
  const id = 'sp-' + digest([who, requestId]).slice(0, 32);
  const createDigest = link === '' ? digest([publicKey, projectionVersion]) : digest([publicKey, projectionVersion, link]);
  let rows = await db.bindings.query().equalTo('id', id).get();
  if (rows.length === 0) {
    const row = new PairMemberBinding(); const now = Date.now();
    row.setId(id); row.setCreatorSubject(who); row.setCreatorKey(publicKey); row.setCreateDigest(createDigest);
    row.setCreatorLink(link);
    row.setStatus('WAITING'); row.setRevision(1); row.setProtocolVersion(1); row.setProjectionVersion(1);
    row.setCreatedAt(now); row.setUpdatedAt(now); row.setExpiresAt(now + PAIR_TTL);
    let free = false;
    for (let i = 0; i < 5; i++) {
      row.setInviteCode(String(randomInt(0, 1000000)).padStart(6, '0'));
      if ((await db.bindings.query().equalTo('inviteCode', row.getInviteCode()).limit(2).get()).length === 0) { free = true; break; }
    }
    if (!free) throw new Rejection('CODE_SPACE_BUSY');
    // insert, NOT upsert, protects simultaneous creation of the deterministic request key.
    try { await db.bindings.insert(row); } catch {
      rows = await db.bindings.query().equalTo('id', id).get();
      if (rows.length !== 1) throw new Rejection('RESULT_UNKNOWN');
    }
  }
  let result: Record<string, Object> = {};
  const proof = randomBytes(24).toString('base64url');
  const committed = await db.bindings.runTransaction({ async apply(tx) {
    const row = await txBinding(tx, db.bindings, id);
    if (row.getCreatorSubject() !== who || row.getCreateDigest() !== createDigest) throw new Rejection('REQUEST_REUSED');
    member(row, who, false);
    result = body(row, who);
    if (row.getStatus() === 'ACTIVE') return true;
    row.setConfirmHash(digest([proof])); touch(row);
    result = { ...body(row, who), inviteCode: row.getInviteCode(), confirmSecret: proof };
    tx.executeUpsert([row]); return true;
  } });
  if (!committed) throw new Rejection('VERSION_CONFLICT');
  return result;
}

export async function joinPair(who: string, code: string, publicKey: string, projectionVersion: number, link = '') {
  if (typeof link !== 'string' || link.length > 4096) throw new Rejection('BAD_REQUEST');
  if (typeof code !== 'string' || !/^\d{6}$/.test(code) || !validPublicKey(publicKey) || projectionVersion !== 1) {
    throw new Rejection('BAD_REQUEST');
  }
  const db = collections();
  const joinDigest = digest(['join-v1', who, code, publicKey, projectionVersion]);
  const recovery = await db.bindings.query().equalTo('recipientJoinDigest', joinDigest)
    .equalTo('recipientSubject', who).limit(2).get();
  if (recovery.length > 1) throw new Rejection('CODE_COLLISION');
  if (recovery.length === 1) {
    // Re-read: a concurrent revocation must not resurrect the previously queried binding.
    const row = await getBinding(db.bindings, recovery[0].getId());
    member(row, who, false);
    if (row.getRecipientSubject() !== who || row.getRecipientKey() !== publicKey ||
      row.getRecipientJoinDigest() !== joinDigest || (row.getRecipientLink() || '') !== link) throw new Rejection('CODE_EXPIRED');
    return body(row, who);
  }
  const found = await db.bindings.query().equalTo('inviteCode', code).limit(2).get();
  if (found.length === 0) throw new Rejection('CODE_EXPIRED');
  // Random code collisions fail closed; a non-unique code is never used to choose one arbitrary pair.
  if (found.length !== 1) throw new Rejection('CODE_COLLISION');
  let result: Record<string, Object> = {};
  const committed = await db.bindings.runTransaction({ async apply(tx) {
    const row = await txBinding(tx, db.bindings, found[0].getId());
    if (row.getCreatorSubject() === who) throw new Rejection('FORBIDDEN');
    if (row.getStatus() === 'REVOKED' || row.getExpiresAt() <= Date.now()) throw new Rejection('CODE_EXPIRED');
    if (row.getProtocolVersion() !== 1 || row.getProjectionVersion() !== 1) throw new Rejection('CAPABILITY_UNAVAILABLE');
    if (row.getStatus() !== 'WAITING') {
      if (row.getRecipientSubject() !== who) throw new Rejection('CODE_TAKEN');
      if (row.getRecipientKey() !== publicKey) throw new Rejection('KEY_CHANGED');
      if ((row.getRecipientLink() || '') !== link) throw new Rejection('KEY_CHANGED');
      result = body(row, who); return true;
    }
    row.setRecipientSubject(who); row.setRecipientKey(publicKey); row.setStatus('PENDING_CONFIRM');
    row.setRecipientLink(link);
    row.setRecipientJoinDigest(joinDigest);
    row.setExpiresAt(Date.now() + PAIR_TTL); touch(row);
    result = body(row, who); tx.executeUpsert([row]); return true;
  } });
  if (!committed) throw new Rejection('VERSION_CONFLICT');
  return result;
}

export async function confirmPair(who: string, pairId: string, proof: string) {
  if (!validId(pairId)) throw new Rejection('BAD_REQUEST');
  const db = collections(); let result: Record<string, Object> = {};
  const committed = await db.bindings.runTransaction({ async apply(tx) {
    const row = await txBinding(tx, db.bindings, pairId);
    if (row.getCreatorSubject() !== who) throw new Rejection('FORBIDDEN');
    member(row, who, false);
    if (row.getStatus() === 'ACTIVE') { result = body(row, who); return true; }
    if (!proofMatches(row.getConfirmHash(), proof)) throw new Rejection('FORBIDDEN');
    if (row.getStatus() !== 'PENDING_CONFIRM' || !row.getRecipientSubject()) throw new Rejection('PAIR_NOT_READY');
    row.setStatus('ACTIVE'); row.setConfirmHash(''); row.setInviteCode(''); row.setBootstrapOffer(''); row.setExpiresAt(0); touch(row);
    result = body(row, who); tx.executeUpsert([row]); return true;
  } });
  if (!committed) throw new Rejection('VERSION_CONFLICT');
  return result;
}

export async function pairStatus(who: string, pairId: string) {
  const row = await getBinding(collections().bindings, pairId); member(row, who, false); return body(row, who);
}

function receipt(row: PairPlanRequest, who: string, commandDigest: string): Record<string, Object> {
  if (row.getActorUid() !== who || row.getDigest() !== commandDigest) throw new Rejection('REQUEST_REUSED');
  return JSON.parse(row.getResponse()) as Record<string, Object>;
}

/** Read-only original receipt. Absence is not a cancellation and never creates a plan. */
export async function requestStatus(who: string, command: Command): Promise<Record<string, Object>> {
  const db = collections();
  const binding = await getBinding(db.bindings, command.pairId); member(binding, who);
  const key = digest([command.pairId, who, command.requestId]);
  const hash = digest([command.pairId, command.planId, command.action, command.expectedVersion, command.envelope]);
  const [rows, archived] = await Promise.all([db.requests.query().equalTo('id', key).limit(2).get(),
    usesStorage(binding) ? findArchivedReceipt(key) : Promise.resolve(null)]);
  if (rows.length > 1) throw new Rejection('CLEANUP_REQUIRED');
  member(await getBinding(db.bindings, command.pairId), who);
  return rows.length === 1 ? receipt(rows[0], who, hash) : archived !== null ? receipt(archived, who, hash)
    : { code: 'REQUEST_NOT_COMMITTED' };
}

/** Explicitly close only an uncommitted request. The binding CAS fences a concurrent/late mutate. */
export async function closeRequest(who: string, command: Command): Promise<Record<string, Object>> {
  const db = collections();
  const initial = await getBinding(db.bindings, command.pairId); member(initial, who);
  const v2 = usesStorage(initial);
  if (v2 && initial.getStorageVersion() < 2) await initializeStorage(command.pairId);
  const key = digest([command.pairId, who, command.requestId]);
  const hash = digest([command.pairId, command.planId, command.action, command.expectedVersion, command.envelope]);
  for (let attempt = 0; attempt < 3; attempt++) {
    let result: Record<string, Object> = {};
    const committed = await db.bindings.runTransaction({ async apply(tx) {
      const binding = await txBinding(tx, db.bindings, command.pairId); member(binding, who);
      const rows = await tx.executeQuery(db.requests.query().equalTo('id', key));
      const archived = v2 ? await findArchivedReceipt(key, tx) : null;
      if (rows.length > 1 || (rows.length !== 0 && archived !== null)) throw new Rejection('BAD_RECORD');
      // Never cancel a plan that was already committed, even when its client never saw the reply.
      if (rows.length === 1 || archived !== null) {
        result = receipt(rows.length === 1 ? rows[0] : archived!, who, hash); return true;
      }
      const head = v2 ? await storageHead(tx, command.pairId) : null;
      const batch = head !== null ? await prepareReceiptBatch(tx, head) : null;
      const requests = head === null ? await tx.executeQuery(db.requests.query().equalTo('pairId', command.pairId).limit(MAX_REQUESTS + 1)) : [];
      if ((head !== null ? head.getRequestCount() - (batch?.rows.length ?? 0) : requests.length) >= MAX_REQUESTS)
        throw new Rejection('BACKLOG_FULL');
      result = { code: 'REQUEST_CLOSED' };
      const row = new PairPlanRequest(); const now = Date.now();
      row.setId(key); row.setPairId(command.pairId); row.setActorUid(who); row.setDigest(hash);
      row.setResponse(JSON.stringify(result)); row.setCreatedAt(now); row.setExpiresAt(now + 30 * 86400000);
      // All reads precede writes. Keep the same immutable request key and digest as mutate.
      touch(binding); tx.executeUpsert([binding]); tx.executeUpsert([row]);
      if (head !== null && batch !== null) {
        commitReceiptBatch(tx, head, batch); head.setRequestCount(head.getRequestCount() + 1); saveHead(tx, head);
      }
      return true;
    } });
    if (committed) { member(await getBinding(db.bindings, command.pairId), who); return result; }
  }
  throw new Rejection('VERSION_CONFLICT');
}

/** Cancel an ambiguous CREATE by its authenticated deterministic key, never replay createPair. */
export async function cleanupCreate(who: string, flowId: string): Promise<Record<string, Object>> {
  if (!validId(flowId)) throw new Rejection('BAD_REQUEST');
  const db = collections(); const id = 'sp-' + digest([who, flowId]).slice(0, 32);
  const existing = await db.bindings.query().equalTo('id', id).get();
  if (existing.length === 0) {
    // An insert-only tombstone also fences a late in-flight create. Never report NOT_FOUND as deletion.
    const row = new PairMemberBinding(); row.setId(id); row.setCreatorSubject(who);
    row.setStatus('REVOKED'); row.setRevision(1); row.setProtocolVersion(1); row.setProjectionVersion(1);
    row.setCreatedAt(Date.now()); row.setUpdatedAt(Date.now()); row.setExpiresAt(Date.now() + 30 * 86400000);
    try { await db.bindings.insert(row); } catch { /* A racing creator is handled by unpair below. */ }
  }
  return { ...await unpair(who, id), pairId: id };
}

function eventOf(binding: PairMemberBinding, row: PairDatePlan, who: string, kind: string, now: number): PairPlanOutbox {
  const event = new PairPlanOutbox(); event.setId(digest([row.getPairId(), row.getPlanId(), row.getStateVersion()]));
  event.setPairId(row.getPairId()); event.setPlanId(row.getPlanId());
  event.setTargetUid(who === binding.getCreatorSubject() ? binding.getRecipientSubject() : binding.getCreatorSubject());
  event.setKind(kind); event.setStateVersion(row.getStateVersion()); event.setStatus('PENDING');
  event.setCreatedAt(now); event.setExpiresAt(now + PENDING_TTL); return event;
}

/** Existing binding is the conflict anchor for absent plans and absent request receipts too. */
export async function mutate(who: string, command: Command,
  diagnostic: { stage: string } = { stage: 'mutate' }): Promise<Record<string, Object>> {
  diagnostic.stage = 'mutate.collections';
  const db = collections(); const requestKey = digest([command.pairId, who, command.requestId]);
  const commandDigest = digest([command.pairId, command.planId, command.action, command.expectedVersion, command.envelope]);
  const planKey = digest([command.pairId, command.planId]);
  diagnostic.stage = 'mutate.binding';
  const initial = await getBinding(db.bindings, command.pairId); member(initial, who);
  const v2 = usesStorage(initial);
  if (v2 && initial.getStorageVersion() < 2) await initializeStorage(command.pairId);
  diagnostic.stage = 'mutate.receipt';
  const [prior, history] = await Promise.all([db.requests.query().equalTo('id', requestKey).get(),
    v2 ? findArchivedReceipt(requestKey) : Promise.resolve(null)]);
  if (prior.length > 1 || (prior.length !== 0 && history !== null)) throw new Rejection('BAD_RECORD');
  if (history !== null) {
    const result = receipt(history, who, commandDigest);
    member(await getBinding(db.bindings, command.pairId), who); return result;
  }
  if (prior.length === 1) {
    const result = receipt(prior[0], who, commandDigest);
    member(await getBinding(db.bindings, command.pairId), who);
    return result;
  }
  for (let attempt = 0; attempt < 3; attempt++) {
    let result: Record<string, Object> = {};
    diagnostic.stage = 'mutate.transaction';
    const committed = await db.bindings.runTransaction({ async apply(tx) {
      diagnostic.stage = 'mutate.tx.binding';
      const binding = await txBinding(tx, db.bindings, command.pairId); member(binding, who);
      diagnostic.stage = 'mutate.tx.receipt';
      const existing = await tx.executeQuery(db.requests.query().equalTo('id', requestKey));
      const archivedReceipt = v2 ? await findArchivedReceipt(requestKey, tx) : null;
      if (existing.length > 1 || (existing.length !== 0 && archivedReceipt !== null)) throw new Rejection('BAD_RECORD');
      if (archivedReceipt !== null) { result = receipt(archivedReceipt, who, commandDigest); return true; }
      if (existing.length === 1) { result = receipt(existing[0], who, commandDigest); return true; }
      diagnostic.stage = 'mutate.tx.plan';
      const records = await tx.executeQuery(db.plans.query().equalTo('id', planKey));
      diagnostic.stage = 'mutate.tx.plans';
      const head = v2 ? await storageHead(tx, command.pairId) : null;
      const receiptBatch = head !== null ? await prepareReceiptBatch(tx, head) : null;
      const archivedPlan = v2 ? await archivedPlanExists(tx, planKey) : false;
      const plans = head === null ? await tx.executeQuery(db.plans.query().equalTo('pairId', command.pairId).limit(MAX_PLANS + 1)) : [];
      diagnostic.stage = 'mutate.tx.requests';
      const requests = head === null ? await tx.executeQuery(db.requests.query().equalTo('pairId', command.pairId).limit(MAX_REQUESTS + 1)) : [];
      const requestCount = head !== null ? head.getRequestCount() - (receiptBatch?.rows.length ?? 0) : requests.length;
      if (requestCount >= MAX_REQUESTS) throw new Rejection('BACKLOG_FULL');
      const now = Date.now(); let row: PairDatePlan;
      if (command.action === 'PROPOSE') {
        if (command.expectedVersion !== 0 || records.length !== 0 || archivedPlan) throw new Rejection('VERSION_CONFLICT');
        if ((head !== null ? head.getPlanCount() : plans.length) >= MAX_PLANS) throw new Rejection('BACKLOG_FULL');
        checkEnvelope(command.envelope, 1);
        row = new PairDatePlan(); row.setId(planKey); row.setPairId(command.pairId); row.setPlanId(command.planId);
        row.setProposerUid(who); row.setRecipientUid(who === binding.getCreatorSubject() ? binding.getRecipientSubject() : binding.getCreatorSubject());
        row.setState('PENDING'); row.setStateVersion(1); row.setContentRevision(1);
        row.setPendingAuthorUid(who); row.setPendingEnvelope(command.envelope);
        row.setCreatedAt(now); row.setUpdatedAt(now); row.setPendingExpiresAt(now + PENDING_TTL);
      } else {
        if (records.length !== 1) throw new Rejection('NOT_FOUND');
        diagnostic.stage = 'mutate.tx.transition';
        row = copy(records[0], PairDatePlan); transition(row, who, command, now);
      }
      result = { code: 'OK', plan: planBody(row), serverTime: now };
      const request = new PairPlanRequest(); request.setId(requestKey); request.setPairId(command.pairId);
      request.setActorUid(who); request.setDigest(commandDigest); request.setResponse(JSON.stringify(result));
      request.setCreatedAt(now); request.setExpiresAt(now + 30 * 86400000);
      const event = eventOf(binding, row, who, command.action, now);
      const oldEvents = head !== null ? await tx.executeQuery(db.outbox.query().equalTo('pairId', command.pairId)
        .equalTo('planId', command.planId).limit(MAX_EVENTS + 1)) : [];
      const staleEvents = oldEvents.filter(old => {
        const lease = /^SENDING:(\d+):/.exec(old.getStatus());
        return old.getStateVersion() < row.getStateVersion() && (lease === null || Number(lease[1]) <= now);
      });
      const obsoleteVotes = head !== null ? await tx.executeQuery(db.votes.query().equalTo('pairId', command.pairId)
        .equalTo('planId', command.planId).lessThan('stateVersion', row.getStateVersion()).limit(25)) : [];
      if (head !== null && head.getEventCount() - staleEvents.length >= MAX_EVENTS) throw new Rejection('BACKLOG_FULL');
      // Every read above precedes every write. No Push network side effect inside a transaction.
      diagnostic.stage = 'mutate.tx.write';
      touch(binding); tx.executeUpsert([binding]); tx.executeUpsert([row]);
      tx.executeUpsert([request]); tx.executeUpsert([event]);
      if (head !== null && receiptBatch !== null) {
        commitReceiptBatch(tx, head, receiptBatch);
        head.setRequestCount(head.getRequestCount() + 1); head.setEventCount(head.getEventCount() + 1 - staleEvents.length);
        if (head.getEventCount() < 0) throw new Rejection('BAD_COUNTER');
        const audit = staleEvents.map(old => { const ended = copy(old, PairPlanOutbox); ended.setStatus('SKIPPED'); return eventArchive(ended); });
        tx.executeUpsert(audit); tx.executeDelete(staleEvents);
        tx.executeDelete(obsoleteVotes); // Old-version eligibility is not an immutable request receipt.
        if (command.action === 'PROPOSE') head.setPlanCount(head.getPlanCount() + 1);
        appendChange(tx, head, row); saveHead(tx, head);
      }
      return true;
    } });
    if (committed) {
      diagnostic.stage = 'mutate.postCommit.binding';
      member(await getBinding(db.bindings, command.pairId), who);
      return result;
    }
    // Conflict is not success. Retry original request; changed version is rejected on the next read.
  }
  throw new Rejection('VERSION_CONFLICT');
}

export async function read(who: string, pairId: string) {
  if (!validId(pairId)) throw new Rejection('BAD_REQUEST');
  const db = collections(); let result: Record<string, Object> = {}; let revision = 0;
  const initial = await getBinding(db.bindings, pairId); member(initial, who);
  if (usesStorage(initial) && initial.getStorageVersion() < 2) await initializeStorage(pairId);
  // CloudDB treats a write-free transaction as successful without checking versions.
  // Expiry writes use CAS; write-free snapshots are revalidated against the binding below.
  const committed = await db.bindings.runTransaction({ async apply(tx) {
    const binding = await txBinding(tx, db.bindings, pairId); member(binding, who);
    const head = usesStorage(binding) ? await storageHead(tx, pairId) : null;
    const rows = await tx.executeQuery(db.plans.query().equalTo('pairId', pairId).limit(MAX_PLANS + 1));
    if (rows.length > MAX_PLANS) throw new Rejection('BACKLOG_FULL');
    const now = Date.now(); const changed: PairDatePlan[] = []; const events: PairPlanOutbox[] = [];
    for (const original of rows) {
      if (!original.getPendingEnvelope() || original.getPendingExpiresAt() > now) continue;
      const row = copy(original, PairDatePlan);
      if (row.getStateVersion() >= 2147483646) throw new Rejection('VERSION_LIMIT');
      if (row.getState() === 'PENDING') row.setState('EXPIRED');
      row.setPendingEnvelope(''); row.setPendingAuthorUid(''); row.setPendingExpiresAt(0);
      row.setStateVersion(row.getStateVersion() + 1); row.setUpdatedAt(now);
      changed.push(row); events.push(eventOf(binding, row, who, 'EXPIRED', now));
    }
    if (changed.length) {
      const queued = head === null ? await tx.executeQuery(db.outbox.query().equalTo('pairId', pairId).limit(MAX_EVENTS + 1)) : [];
      if ((head !== null ? head.getEventCount() : queued.length) + changed.length > MAX_EVENTS) throw new Rejection('BACKLOG_FULL');
      touch(binding); tx.executeUpsert([binding]); tx.executeUpsert(changed); tx.executeUpsert(events);
      if (head !== null) {
        head.setEventCount(head.getEventCount() + events.length);
        for (const row of changed) appendChange(tx, head, row);
        saveHead(tx, head);
      }
    }
    revision = binding.getRevision();
    result = { ...body(binding, who), plans: rows.map(row => planBody(changed.find(item => item.getId() === row.getId()) || row)), serverTime: now };
    return true;
  } });
  if (!committed) throw new Rejection('VERSION_CONFLICT');
  const current = await getBinding(db.bindings, pairId); member(current, who);
  if (current.getRevision() !== revision) throw new Rejection('VERSION_CONFLICT');
  return result;
}

/** One authenticated response carries binding proof and only the latest encrypted changes. */
export async function readChanges(who: string, pairId: string, cursor: number): Promise<Record<string, Object>> {
  const db = collections(); const binding = await getBinding(db.bindings, pairId); member(binding, who);
  if (!usesStorage(binding)) throw new Rejection('FEATURE_DISABLED');
  if (binding.getStorageVersion() < 2) await initializeStorage(pairId);
  const [due, initialPage] = await Promise.all([
    db.plans.query().equalTo('pairId', pairId).greaterThan('pendingExpiresAt', 0)
      .lessThanOrEqualTo('pendingExpiresAt', Date.now()).limit(1).get(), changePage(pairId, cursor)]);
  let page = initialPage;
  if (due.length) { await read(who, pairId); page = await changePage(pairId, cursor); }
  const current = await getBinding(db.bindings, pairId); member(current, who);
  return { ...body(current, who), ...page, syncVersion: 2 };
}
export function acknowledge(who: string, pairId: string, cursor: number, candidates: string): Promise<Object> {
  return archiveAcknowledgement(who, pairId, cursor, candidates);
}

export async function registerPush(who: string, pairId: string, token: string, enabled: boolean) {
  if (!validId(pairId) || typeof enabled !== 'boolean' || typeof token !== 'string'
    || token.length > 4096 || (enabled && !token.trim())) throw new Rejection('BAD_REQUEST');
  const db = collections(); let result: Record<string, Object> = {};
  const committed = await db.bindings.runTransaction({ async apply(tx) {
    const binding = await txBinding(tx, db.bindings, pairId); member(binding, who);
    const target = new PairPushTarget(); target.setId(digest([pairId, who])); target.setPairId(pairId);
    target.setMemberUid(who); target.setToken(enabled ? token : ''); target.setEnabled(enabled); target.setUpdatedAt(Date.now());
    touch(binding); result = { code: 'OK', myUid: who, enabled };
    tx.executeUpsert([binding]); tx.executeUpsert([target]); return true;
  } });
  if (!committed) throw new Rejection('VERSION_CONFLICT');
  return result;
}

export async function unpair(who: string, pairId: string) {
  if (!validId(pairId)) throw new Rejection('BAD_REQUEST');
  const db = collections();
  let v2 = false; let canonicalComplete = true;
  const committed = await db.bindings.runTransaction({ async apply(tx) {
    const binding = await txBinding(tx, db.bindings, pairId);
    v2 = binding.getStorageVersion() >= 2;
    if (binding.getCreatorSubject() !== who && binding.getRecipientSubject() !== who) throw new Rejection('FORBIDDEN');
    const plans = await tx.executeQuery(db.plans.query().equalTo('pairId', pairId).limit(MAX_PLANS + 1));
    const requests = await tx.executeQuery(db.requests.query().equalTo('pairId', pairId).limit(MAX_REQUESTS + 1));
    const events = await tx.executeQuery(db.outbox.query().equalTo('pairId', pairId).limit(MAX_EVENTS + 1));
    const targets = await tx.executeQuery(db.targets.query().equalTo('pairId', pairId).limit(3));
    if (plans.length > MAX_PLANS || requests.length > MAX_REQUESTS || events.length > MAX_EVENTS || targets.length > 2) {
      throw new Rejection('CLEANUP_REQUIRED');
    }
    if (!v2 && Buffer.byteLength(JSON.stringify([plans, requests, events, targets]), 'utf8') > 1500000) {
      // Keep credentials intact; never silently truncate a deletion at the SDK's transaction limit.
      throw new Rejection('CLEANUP_REQUIRED');
    }
    let bytes = 0; let selectedCount = 0;
    function selected<T>(rows: T[]): T[] {
      if (!v2) return rows;
      const batch: T[] = [];
      for (const row of rows) {
        const size = Buffer.byteLength(JSON.stringify(row));
        if (size > 1000000) throw new Rejection('CLEANUP_REQUIRED');
        if (bytes + size > 1000000 || selectedCount >= 50) { canonicalComplete = false; break; }
        bytes += size; selectedCount++; batch.push(row);
      }
      return batch;
    }
    const deletePlans = selected(plans); const deleteRequests = selected(requests);
    const deleteEvents = selected(events); const deleteTargets = selected(targets);
    // Keep a minimal revoked binding tombstone; no keys/code/proof. Old requests cannot recreate it.
    binding.setStatus('REVOKED'); binding.setCreatorKey(''); binding.setRecipientKey('');
    binding.setCleanupPending(v2);
    binding.setConfirmHash(''); binding.setInviteCode(''); binding.setRecipientJoinDigest('');
    binding.setCreatorLink(''); binding.setRecipientLink(''); binding.setBootstrapRoute(''); binding.setBootstrapOffer('');
    binding.setExpiresAt(Date.now() + 30 * 86400000); touch(binding);
    tx.executeUpsert([binding]); tx.executeDelete(deletePlans); tx.executeDelete(deleteRequests);
    tx.executeDelete(deleteEvents); tx.executeDelete(deleteTargets); return true;
  } });
  if (!committed) throw new Rejection('VERSION_CONFLICT');
  if (v2) {
    if (!canonicalComplete) return { code: 'CLEANUP_PENDING', status: 'REVOKED' };
    for (let page = 0; page < 5; page++) {
      if (await cleanupStorageBatch(pairId)) return { code: 'OK', status: 'REVOKED' };
    }
    return { code: 'CLEANUP_PENDING', status: 'REVOKED' };
  }
  return { code: 'OK', status: 'REVOKED' };
}
