import { createHmac, randomUUID, timingSafeEqual } from 'crypto';
import { client, zoneName } from './identity';
import { PairMemberBinding, PairPlanOutbox, PairPlanWake } from './models';
import { dispatchEvent } from './push';
import { installPushAccountEnvironment } from './push-account';

function secret(): string {
  const value = process.env.FORTWO_PLAN_DISPATCH_SECRET ?? '';
  if (!/^[A-Za-z0-9_-]{32,128}$/.test(value)) throw new Error('WAKE_CONFIG_INVALID');
  return value;
}
function proof(row: PairPlanWake): string {
  return createHmac('sha256', secret()).update(JSON.stringify(['FORTWO_PLAN_WAKE_V1', row.getId(),
    row.getPairId(), row.getEventId(), row.getCreatedAt()])).digest('hex');
}
/** Await an actual INSERT, not transaction UPSERT (unsupported by AGC DB triggers). */
export async function enqueueWake(eventId: string): Promise<boolean> {
  if (process.env.FORTWO_PLAN_ASYNC_PUSH !== 'true' || process.env.FORTWO_ENABLE_PLAN_PUSH !== 'true') return false;
  try {
    secret();
    const db = client().database({ zoneName: zoneName() });
    const events = await db.collection(PairPlanOutbox).query().equalTo('id', eventId).limit(2).get();
    if (events.length !== 1 || events[0].getStatus() !== 'PENDING') return false;
    const row = new PairPlanWake();
    // Stable per-event identity bounds duplicate request/trigger wake rows as well as provider claims.
    row.setId(eventId.slice(0, 8) + '-' + eventId.slice(8, 12) + '-' + eventId.slice(12, 16)
      + '-' + eventId.slice(16, 20) + '-' + eventId.slice(20, 32)); row.setPairId(events[0].getPairId());
    row.setEventId(eventId); row.setCreatedAt(Date.now()); row.setProof(proof(row));
    const wakes = db.collection(PairPlanWake);
    try { await wakes.insert(row); }
    catch {
      const existing = await wakes.query().equalTo('id', row.getId()).limit(2).get();
      if (existing.length !== 1 || existing[0].getPairId() !== row.getPairId() || existing[0].getEventId() !== eventId
        || existing[0].getProof() !== proof(existing[0])) return false;
    }
    // A revoked connection cannot leave a late post-commit wake behind after cleanup.
    const bindings = await db.collection(PairMemberBinding).query().equalTo('id', row.getPairId()).limit(2).get();
    if (bindings.length !== 1 || bindings[0].getStatus() !== 'ACTIVE') { await wakes.delete(row); return false; }
    return true;
  } catch { return false; } // Original outbox is still durable; caller awaits synchronous fallback.
}
interface WorkerContext { env?: Record<string, string>; }
interface WorkerLogger { info(message: string): void; }
function ids(event: unknown): string[] {
  if (typeof event === 'string') {
    if (Buffer.byteLength(event) > 8192) throw new Error('WAKE_REJECTED');
    event = JSON.parse(event);
  }
  if (!event || typeof event !== 'object' || Array.isArray(event)) throw new Error('WAKE_REJECTED');
  const input = event as { objectTypeName?: unknown; naturalStoreName?: unknown; records?: unknown };
  if (input.objectTypeName !== 'PairPlanWake' || input.naturalStoreName !== zoneName()
    || !Array.isArray(input.records) || input.records.length < 1 || input.records.length > 8) throw new Error('WAKE_REJECTED');
  const result: string[] = [];
  for (const value of input.records) {
    const id = value?.after?.id;
    if (typeof id !== 'string' || !/^[a-f0-9-]{36}$/.test(id) || result.includes(id)) throw new Error('WAKE_REJECTED');
    result.push(id);
  }
  return result;
}
async function consume(event: unknown): Promise<number> {
  secret(); const selected = ids(event);
  const db = client().database({ zoneName: zoneName() }); const wakes = db.collection(PairPlanWake);
  let sent = 0;
  for (const id of selected) {
    // Event shape is not authorization. Only a server-signed, administrator-only persisted row is trusted.
    const rows = await wakes.query().equalTo('id', id).limit(2).get();
    if (rows.length === 0) continue; // Duplicate delivery after a successful worker.
    if (rows.length !== 1) throw new Error('WAKE_REJECTED');
    const row = rows[0]; const signature = row.getProof();
    if (!/^[a-f0-9]{64}$/.test(row.getEventId()) || !Number.isSafeInteger(row.getCreatedAt())
      || row.getCreatedAt() <= 0 || !/^[a-f0-9]{64}$/.test(signature)
      || !timingSafeEqual(Buffer.from(signature), Buffer.from(proof(row)))) throw new Error('WAKE_REJECTED');
    if (process.env.FORTWO_ENABLE_SHARED_PLAN_V1 !== 'true' || process.env.FORTWO_ENABLE_PLAN_PUSH !== 'true') continue;
    const events = await db.collection(PairPlanOutbox).query().equalTo('id', row.getEventId()).limit(2).get();
    if (events.length > 1 || (events.length === 1 && events[0].getPairId() !== row.getPairId())) throw new Error('WAKE_REJECTED');
    sent += await dispatchEvent(row.getEventId()); // Claim checks member, consent, plan version, expiry and lease again.
    await wakes.delete(row); // Retry authority remains in the original outbox, not in trigger payloads.
  }
  return sent;
}
/** DB-only entry point. Never configure an app/HTTP trigger; TIMER uses dispatch.handler, not this handler. */
export function handler(event: unknown, context: WorkerContext, callback: (result: Object) => void,
  logger?: WorkerLogger): void {
  if (context?.env) {
    installPushAccountEnvironment(context.env);
    for (const name of ['FORTWO_AUTH_PROJECT_ID', 'FORTWO_SHARED_PLAN_ZONE', 'FORTWO_ENABLE_SHARED_PLAN_V1',
      'FORTWO_ENABLE_PLAN_PUSH', 'FORTWO_PLAN_DISPATCH_SECRET', 'PROJECT_CREDENTIAL', 'AGC_CONFIG']) {
      if (typeof context.env[name] === 'string') process.env[name] = context.env[name];
    }
  }
  const started = Date.now(); const invocationId = randomUUID();
  const runtime = globalThis as typeof globalThis & { logger?: WorkerLogger };
  const sink = typeof logger?.info === 'function' ? logger : runtime.logger;
  const log = (code: string, providerAccepted: number): void => {
    const message = JSON.stringify({ tag: 'FORTWO_PLAN_WAKE', build: '2026-10-14-wake1', invocationId,
      code, providerAccepted, elapsedMs: Math.max(0, Date.now() - started) });
    try { if (sink?.info) sink.info(message); else console.info(message); } catch { /* Logger cannot change authentication. */ }
  };
  Promise.resolve().then(() => consume(event)).then(sent => {
    log('OK', sent); callback({ code: 'OK', providerAccepted: sent });
  }, error => {
    const code = error instanceof Error && error.message === 'WAKE_REJECTED' ? 'WAKE_REJECTED' : 'PUSH_DEFERRED';
    log(code, 0); callback({ code, providerAccepted: 0 });
  });
}
