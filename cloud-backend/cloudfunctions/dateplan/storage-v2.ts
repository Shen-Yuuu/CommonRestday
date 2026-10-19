import { Transaction } from '@hw-agconnect/cloud-server';
import { gzipSync, gunzipSync } from 'zlib';
import { client, digest, Rejection, zoneName } from './identity';
import { PairMemberBinding, PairDatePlan, PairPlanRequest, PairPlanOutbox, PairPushTarget,
  PairPlanSyncState, PairPlanChange, PairPlanArchive, PairPlanArchiveVote,
  PairPlanReceiptArchive, PairPlanEventArchive, PairPlanWake } from './models';
import { MAX_PLANS, MAX_REQUESTS, MAX_EVENTS, planBody, validId } from './protocol';

export const CHANGE_PAGE_SIZE = 50;
export function storageEnabled(): boolean { return process.env.FORTWO_PLAN_STORAGE_V2 === 'true'; }
/** Once a pair has migrated, turning off rollout cannot discard its archive/replay protection. */
export function usesStorage(binding: PairMemberBinding): boolean {
  return storageEnabled() || binding.getStorageVersion() >= 2;
}
function dbs() {
  const db = client().database({ zoneName: zoneName() });
  return { bindings: db.collection(PairMemberBinding), plans: db.collection(PairDatePlan),
    requests: db.collection(PairPlanRequest), events: db.collection(PairPlanOutbox), targets: db.collection(PairPushTarget),
    states: db.collection(PairPlanSyncState), changes: db.collection(PairPlanChange), archives: db.collection(PairPlanArchive),
    votes: db.collection(PairPlanArchiveVote), receipts: db.collection(PairPlanReceiptArchive),
    eventArchives: db.collection(PairPlanEventArchive), wakes: db.collection(PairPlanWake) };
}
function touch(binding: PairMemberBinding): void {
  if (binding.getRevision() >= 2147483646) throw new Rejection('VERSION_LIMIT');
  binding.setRevision(binding.getRevision() + 1); binding.setUpdatedAt(Date.now());
}
function authorized(binding: PairMemberBinding, who: string): void {
  if (![binding.getCreatorSubject(), binding.getRecipientSubject()].includes(who)) throw new Rejection('FORBIDDEN');
  if (binding.getStatus() === 'REVOKED') throw new Rejection(binding.getCleanupPending() ? 'CLEANUP_PENDING' : 'SESSION_REVOKED');
  if (binding.getStatus() !== 'ACTIVE') throw new Rejection('PAIR_NOT_ACTIVE');
}
export async function storageHead(tx: Transaction, pairId: string): Promise<PairPlanSyncState> {
  const rows = await tx.executeQuery(dbs().states.query().equalTo('id', pairId).limit(2));
  if (rows.length !== 1) throw new Rejection('STORAGE_NOT_READY');
  const head = Object.assign(new PairPlanSyncState(), rows[0]);
  if (head.getId() !== pairId || head.getPairId() !== pairId) throw new Rejection('BAD_COUNTER');
  for (const value of [head.getSequence(), head.getPlanCount(), head.getRequestCount(), head.getEventCount(),
    head.getCreatorAck(), head.getRecipientAck()]) {
    if (!Number.isSafeInteger(value) || value < 0) throw new Rejection('BAD_COUNTER');
  }
  return head;
}
export function appendChange(tx: Transaction, head: PairPlanSyncState, row: PairDatePlan): void {
  if (head.getSequence() >= Number.MAX_SAFE_INTEGER - 1) throw new Rejection('VERSION_LIMIT');
  head.setSequence(head.getSequence() + 1);
  // One latest encrypted change per plan, not an ever-growing copy for every state transition.
  const change = new PairPlanChange(); change.setId(row.getId()); change.setPairId(row.getPairId());
  change.setSequence(head.getSequence()); change.setPlanId(row.getPlanId()); change.setStateVersion(row.getStateVersion());
  change.setRecordJson(JSON.stringify(planBody(row))); change.setCreatedAt(Date.now());
  tx.executeUpsert([change]);
}
export function saveHead(tx: Transaction, head: PairPlanSyncState): void { tx.executeUpsert([head]); }

/** CAS protects absent heads too. Legacy canonical rows are retained, not reset or re-keyed. */
export async function initializeStorage(pairId: string, force: boolean = false): Promise<void> {
  if (!storageEnabled() && !force) return;
  const db = dbs();
  const known = await db.states.query().equalTo('id', pairId).limit(2).get();
  if (known.length === 1) return;
  if (known.length > 1) throw new Rejection('BAD_COUNTER');
  for (let attempt = 0; attempt < 3; attempt++) {
    const ok = await db.bindings.runTransaction({ async apply(tx) {
      const bindings = await tx.executeQuery(db.bindings.query().equalTo('id', pairId).limit(2));
      const existing = await tx.executeQuery(db.states.query().equalTo('id', pairId).limit(2));
      if (bindings.length !== 1 || bindings[0].getStatus() !== 'ACTIVE') throw new Rejection('SESSION_REVOKED');
      if (existing.length === 1) return true;
      const plans = await tx.executeQuery(db.plans.query().equalTo('pairId', pairId).limit(MAX_PLANS + 1));
      const requests = await tx.executeQuery(db.requests.query().equalTo('pairId', pairId).limit(MAX_REQUESTS + 1));
      const events = await tx.executeQuery(db.events.query().equalTo('pairId', pairId).limit(MAX_EVENTS + 1));
      if (plans.length > MAX_PLANS || requests.length > MAX_REQUESTS || events.length > MAX_EVENTS)
        throw new Rejection('BACKLOG_FULL');
      const binding = Object.assign(new PairMemberBinding(), bindings[0]);
      const head = new PairPlanSyncState(); head.setId(pairId); head.setPairId(pairId);
      head.setPlanCount(plans.length); head.setRequestCount(requests.length); head.setEventCount(events.length);
      binding.setStorageVersion(2); touch(binding); tx.executeUpsert([binding]);
      for (const row of plans) appendChange(tx, head, row);
      saveHead(tx, head); return true;
    } });
    if (ok) return;
  }
  throw new Rejection('VERSION_CONFLICT');
}
function archivedReceipt(row: PairPlanReceiptArchive): PairPlanRequest {
  const encoded = row.getResponseCompressed();
  if (!/^[A-Za-z0-9+/=]+$/.test(encoded) || encoded.length > 131072) throw new Rejection('BAD_RECORD');
  let response: string;
  try { response = gunzipSync(Buffer.from(encoded, 'base64'), { maxOutputLength: 131072 }).toString('utf8'); }
  catch { throw new Rejection('BAD_RECORD'); }
  const out = new PairPlanRequest(); out.setId(row.getId()); out.setPairId(row.getPairId());
  out.setActorUid(row.getActorUid()); out.setDigest(row.getDigest()); out.setResponse(response);
  out.setCreatedAt(row.getCreatedAt()); return out;
}
export async function findArchivedReceipt(id: string, tx?: Transaction): Promise<PairPlanRequest | null> {
  const query = dbs().receipts.query().equalTo('id', id).limit(2);
  const rows = tx ? await tx.executeQuery(query) : await query.get();
  if (rows.length > 1) throw new Rejection('BAD_RECORD');
  return rows.length === 0 ? null : archivedReceipt(rows[0]);
}
export async function archivedPlanExists(tx: Transaction, id: string): Promise<boolean> {
  const rows = await tx.executeQuery(dbs().archives.query().equalTo('id', id).limit(2));
  if (rows.length > 1) throw new Rejection('BAD_RECORD');
  return rows.length === 1;
}

export interface ReceiptBatch { rows: PairPlanRequest[]; proofs: PairPlanReceiptArchive[]; }
export async function prepareReceiptBatch(tx: Transaction, head: PairPlanSyncState): Promise<ReceiptBatch> {
  if (head.getRequestCount() < 150) return { rows: [], proofs: [] };
  const rows = await tx.executeQuery(dbs().requests.query().equalTo('pairId', head.getPairId())
    .orderByAsc('createdAt').limit(25));
  const proofs: PairPlanReceiptArchive[] = [];
  for (const row of rows) {
    if (Buffer.byteLength(row.getResponse()) > 131072) throw new Rejection('BAD_RECORD');
    const proof = new PairPlanReceiptArchive(); proof.setId(row.getId()); proof.setPairId(row.getPairId());
    proof.setActorUid(row.getActorUid()); proof.setDigest(row.getDigest()); proof.setCreatedAt(row.getCreatedAt());
    proof.setResponseCompressed(gzipSync(Buffer.from(row.getResponse())).toString('base64'));
    proof.setArchivedAt(Date.now()); proofs.push(proof);
  }
  return { rows, proofs };
}
export function commitReceiptBatch(tx: Transaction, head: PairPlanSyncState, batch: ReceiptBatch): void {
  head.setRequestCount(head.getRequestCount() - batch.rows.length);
  if (head.getRequestCount() < 0) throw new Rejection('BAD_COUNTER');
  tx.executeUpsert(batch.proofs); tx.executeDelete(batch.rows);
}

export interface ArchiveCandidate { planId: string; stateVersion: number; }
/** End times stay encrypted. Both members must independently approve the exact finished version. */
export async function acknowledge(who: string, pairId: string, cursor: number, candidatesJson: string): Promise<Object> {
  if (!validId(pairId) || !Number.isSafeInteger(cursor) || cursor < 0
    || typeof candidatesJson !== 'string' || Buffer.byteLength(candidatesJson) > 4096) throw new Rejection('BAD_REQUEST');
  let candidates: ArchiveCandidate[];
  try { candidates = JSON.parse(candidatesJson) as ArchiveCandidate[]; } catch { throw new Rejection('BAD_REQUEST'); }
  if (!Array.isArray(candidates) || candidates.length > 10) throw new Rejection('BAD_REQUEST');
  const seen = new Set<string>();
  for (const item of candidates) {
    if (!item || !validId(item.planId) || !Number.isSafeInteger(item.stateVersion) || item.stateVersion < 1
      || seen.has(item.planId)) throw new Rejection('BAD_REQUEST');
    seen.add(item.planId);
  }
  const db = dbs(); let archived = 0;
  const before = await db.bindings.query().equalTo('id', pairId).limit(2).get();
  if (before.length !== 1) throw new Rejection('NOT_FOUND');
  authorized(before[0], who);
  if (!usesStorage(before[0])) throw new Rejection('FEATURE_DISABLED');
  if (before[0].getStorageVersion() < 2) await initializeStorage(pairId, true);
  const ok = await db.bindings.runTransaction({ async apply(tx) {
    const bindings = await tx.executeQuery(db.bindings.query().equalTo('id', pairId).limit(2));
    if (bindings.length !== 1) throw new Rejection('NOT_FOUND');
    const binding = Object.assign(new PairMemberBinding(), bindings[0]); authorized(binding, who);
    const head = await storageHead(tx, pairId);
    if (cursor > head.getSequence()) throw new Rejection('BAD_CURSOR');
    const rows: PairDatePlan[] = []; const votes: PairPlanArchiveVote[] = []; const archives: PairPlanArchive[] = [];
    const oldVotes: PairPlanArchiveVote[] = []; const endedEvents: PairPlanOutbox[] = [];
    const eventProofs: PairPlanEventArchive[] = [];
    for (const candidate of candidates) {
      const id = digest([pairId, candidate.planId]);
      const plans = await tx.executeQuery(db.plans.query().equalTo('id', id).limit(2));
      const existingVotes = await tx.executeQuery(db.votes.query().equalTo('pairId', pairId)
        .equalTo('planId', candidate.planId).equalTo('stateVersion', candidate.stateVersion).limit(3));
      const changes = await tx.executeQuery(db.changes.query().equalTo('id', id).limit(2));
      const notificationRows = await tx.executeQuery(db.events.query().equalTo('pairId', pairId)
        .equalTo('planId', candidate.planId).limit(MAX_EVENTS + 1));
      if (plans.length === 0) continue; // Already archived by a simultaneous member/previous acknowledgement.
      if (plans.length !== 1 || changes.length !== 1 || plans[0].getStateVersion() !== candidate.stateVersion
        || changes[0].getSequence() > cursor) continue;
      const row = plans[0];
      if (row.getPendingEnvelope() || row.getState() === 'PENDING') continue;
      const vote = new PairPlanArchiveVote(); vote.setId(digest([pairId, candidate.planId, candidate.stateVersion, who]));
      vote.setPairId(pairId); vote.setPlanId(candidate.planId); vote.setStateVersion(candidate.stateVersion);
      vote.setActorUid(who); vote.setCreatedAt(Date.now());
      const peer = who === binding.getCreatorSubject() ? binding.getRecipientSubject() : binding.getCreatorSubject();
      if (existingVotes.some(v => v.getActorUid() === peer)) {
        const archive = new PairPlanArchive(); archive.setId(id); archive.setPairId(pairId);
        archive.setPlanId(candidate.planId); archive.setStateVersion(candidate.stateVersion);
        archive.setRecordJson(JSON.stringify(row)); archive.setArchivedAt(Date.now());
        archives.push(archive); rows.push(row); oldVotes.push(...existingVotes);
        for (const notification of notificationRows) {
          // A provider call already owns this event until its lease expires; do not erase it under the sender.
          const lease = /^SENDING:(\d+):/.exec(notification.getStatus());
          if (lease !== null && Number(lease[1]) > Date.now()) continue;
          const ended = Object.assign(new PairPlanOutbox(), notification); ended.setStatus('SKIPPED');
          endedEvents.push(notification); eventProofs.push(eventArchive(ended));
        }
      } else votes.push(vote);
    }
    if (who === binding.getCreatorSubject()) head.setCreatorAck(Math.max(cursor, head.getCreatorAck()));
    else head.setRecipientAck(Math.max(cursor, head.getRecipientAck()));
    head.setPlanCount(head.getPlanCount() - rows.length);
    head.setEventCount(head.getEventCount() - endedEvents.length);
    if (head.getPlanCount() < 0 || head.getEventCount() < 0) throw new Rejection('BAD_COUNTER');
    touch(binding); tx.executeUpsert([binding]); saveHead(tx, head);
    tx.executeUpsert(votes); tx.executeUpsert(archives); tx.executeDelete(rows); tx.executeDelete(oldVotes);
    tx.executeUpsert(eventProofs); tx.executeDelete(endedEvents);
    archived = rows.length; return true;
  } });
  if (!ok) throw new Rejection('VERSION_CONFLICT');
  return { code: 'OK', archived };
}

export async function changePage(pairId: string, cursor: number): Promise<{ plans: Object[]; cursor: number; more: boolean }> {
  if (!Number.isSafeInteger(cursor) || cursor < 0) throw new Rejection('BAD_CURSOR');
  const db = dbs(); const heads = await db.states.query().equalTo('id', pairId).limit(2).get();
  if (heads.length !== 1) throw new Rejection('STORAGE_NOT_READY');
  const sequence = heads[0].getSequence();
  if (heads[0].getPairId() !== pairId || !Number.isSafeInteger(sequence) || sequence < 0) throw new Rejection('BAD_COUNTER');
  if (cursor > sequence) throw new Rejection('BAD_CURSOR');
  if (cursor === sequence) return { plans: [], cursor, more: false };
  const rows = await db.changes.query().equalTo('pairId', pairId).greaterThan('sequence', cursor)
    .lessThanOrEqualTo('sequence', sequence).orderByAsc('sequence').limit(CHANGE_PAGE_SIZE + 1).get();
  const page = rows.slice(0, CHANGE_PAGE_SIZE); let previous = cursor;
  for (const row of page) {
    if (row.getPairId() !== pairId || !Number.isSafeInteger(row.getSequence()) || row.getSequence() <= previous
      || Buffer.byteLength(row.getRecordJson()) > 131072) throw new Rejection('BAD_RECORD');
    const content = JSON.parse(row.getRecordJson()) as { pairId?: string; planId?: string; stateVersion?: number };
    if (content.pairId !== pairId || content.planId !== row.getPlanId() || content.stateVersion !== row.getStateVersion())
      throw new Rejection('BAD_RECORD');
    previous = row.getSequence();
  }
  const more = rows.length > CHANGE_PAGE_SIZE;
  return { plans: page.map(row => JSON.parse(row.getRecordJson()) as Object),
    cursor: more ? page[page.length - 1].getSequence() : sequence, more };
}

/** Explicit revocation must cover archives too; max 25 rows per table, no whole-history transaction. */
export async function cleanupStorageBatch(pairId: string): Promise<boolean> {
  const db = dbs(); let complete = false;
  const ok = await db.bindings.runTransaction({ async apply(tx) {
    const bindings = await tx.executeQuery(db.bindings.query().equalTo('id', pairId).limit(2));
    if (bindings.length !== 1 || bindings[0].getStatus() !== 'REVOKED') return false;
    const changes = await tx.executeQuery(db.changes.query().equalTo('pairId', pairId).limit(25));
    const archives = await tx.executeQuery(db.archives.query().equalTo('pairId', pairId).limit(25));
    const receipts = await tx.executeQuery(db.receipts.query().equalTo('pairId', pairId).limit(25));
    const events = await tx.executeQuery(db.eventArchives.query().equalTo('pairId', pairId).limit(25));
    const votes = await tx.executeQuery(db.votes.query().equalTo('pairId', pairId).limit(25));
    const wakes = await tx.executeQuery(db.wakes.query().equalTo('pairId', pairId).limit(25));
    const heads = await tx.executeQuery(db.states.query().equalTo('id', pairId).limit(2));
    let bytes = 0; let count = 0; let truncated = false;
    function bounded<T>(rows: T[]): T[] {
      const selected: T[] = [];
      for (const row of rows) {
        const size = Buffer.byteLength(JSON.stringify(row));
        if (size > 1000000) throw new Rejection('BAD_RECORD');
        if (bytes + size > 1000000 || count >= 50) { truncated = true; break; }
        bytes += size; count++; selected.push(row);
      }
      return selected;
    }
    const selectedChanges = bounded(changes); const selectedArchives = bounded(archives);
    const selectedReceipts = bounded(receipts); const selectedEvents = bounded(events);
    const selectedVotes = bounded(votes); const selectedWakes = bounded(wakes);
    complete = !truncated && [changes, archives, receipts, events, votes, wakes].every(rows => rows.length < 25);
    const binding = Object.assign(new PairMemberBinding(), bindings[0]);
    if (complete) binding.setCleanupPending(false);
    touch(binding);
    tx.executeUpsert([binding]); tx.executeDelete(selectedChanges); tx.executeDelete(selectedArchives); tx.executeDelete(selectedReceipts);
    tx.executeDelete(selectedEvents); tx.executeDelete(selectedVotes); tx.executeDelete(selectedWakes);
    if (complete) tx.executeDelete(heads); return true;
  } });
  return ok && complete;
}

export function eventArchive(row: PairPlanOutbox): PairPlanEventArchive {
  const archive = new PairPlanEventArchive(); archive.setId(row.getId()); archive.setPairId(row.getPairId());
  archive.setRecordJson(JSON.stringify(row)); archive.setArchivedAt(Date.now()); return archive;
}
