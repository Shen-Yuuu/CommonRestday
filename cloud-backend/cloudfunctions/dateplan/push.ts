import { request } from 'https';
import { constants, randomUUID, sign } from 'crypto';
import { client, digest, zoneName } from './identity';
import { PairMemberBinding, PairDatePlan, PairPlanOutbox, PairPushTarget, PairPlanEventArchive } from './models';
import { eventArchive, storageHead, saveHead } from './storage-v2';
import { PushAccount, readPushAccount } from './push-account';

export const PLAN_PUSH_ACTION = 'com.common.fortwo.action.PLAN';
export type { PushAccount } from './push-account';
export interface PushDelivery { send(token: string, kind: string, eventId: string): Promise<boolean>; }
export function notification(kind: string, eventId = digest(['generic-plan-notification'])): Object {
  const title = kind === 'ACCEPT' ? '共同计划已确认' : kind === 'AMEND' ? '共同计划有改期申请'
    : kind === 'PROPOSE' ? '有一个共同计划等你确认' : '共同计划状态已更新';
  return { payload: { notification: { category: 'WORK', title,
    body: '打开两人份查看最新安排。', appMessageId: eventId,
    notifyId: parseInt(eventId.slice(0, 8), 16) & 2147483647,
    clickAction: { actionType: 1, action: PLAN_PUSH_ACTION }, foregroundShow: true } },
    pushOptions: { ttl: 3600, collapseKey: 1 } };
}
export function serviceJwt(account: PushAccount, now = Math.floor(Date.now() / 1000)): string {
  if (!account || !/^[0-9]+$/.test(account.project_id) || !account.key_id || !account.sub_account
    || !account.private_key.includes('BEGIN PRIVATE KEY')) throw new Error('PUSH_CONFIG_INVALID');
  const header = Buffer.from(JSON.stringify({ alg: 'PS256', typ: 'JWT', kid: account.key_id })).toString('base64url');
  const claims = Buffer.from(JSON.stringify({ iss: account.sub_account,
    aud: 'https://oauth-login.cloud.huawei.com/oauth2/v3/token', iat: now, exp: now + 3600 })).toString('base64url');
  const body = header + '.' + claims;
  return body + '.' + sign('sha256', Buffer.from(body), { key: account.private_key,
    padding: constants.RSA_PKCS1_PSS_PADDING, saltLength: 32 }).toString('base64url');
}
class HuaweiPush implements PushDelivery {
  async send(token: string, kind: string, eventId: string): Promise<boolean> {
    // Secrets live only in the cloud runtime. No OAuth client secret, token or private key in the app.
    const account = readPushAccount();
    if (account.project_id !== process.env.FORTWO_AUTH_PROJECT_ID) throw new Error('PUSH_PROJECT_MISMATCH');
    const jwt = serviceJwt(account);
    const payload = JSON.stringify({ ...notification(kind, eventId), target: { token: [token] } });
    return new Promise<boolean>((resolve, reject) => {
      const req = request({ hostname: 'push-api.cloud.huawei.com', method: 'POST',
        path: '/v3/' + account.project_id + '/messages:send', headers: { 'Content-Type': 'application/json',
          'Content-Length': Buffer.byteLength(payload), Authorization: 'Bearer ' + jwt, 'push-type': '0' } }, res => {
        const chunks: Buffer[] = []; let size = 0;
        res.on('data', (chunk: Buffer) => { size += chunk.length; if (size > 16384) req.destroy(new Error('PUSH_RESPONSE_LIMIT'));
          else chunks.push(chunk); });
        res.on('end', () => { try { const reply = JSON.parse(Buffer.concat(chunks).toString('utf8')) as { code?: string };
          resolve(res.statusCode === 200 && reply.code === '80000000'); } catch { resolve(false); } });
      });
      const deadline = setTimeout(() => req.destroy(new Error('PUSH_TIMEOUT')), 5000);
      req.on('close', () => clearTimeout(deadline)); req.on('error', reject); req.end(payload);
    });
  }
}
interface Claim { event: PairPlanOutbox; token: string; lease: string; attempt: number; }
function dbs() {
  const db = client().database({ zoneName: zoneName() });
  return { bindings: db.collection(PairMemberBinding), plans: db.collection(PairDatePlan),
    events: db.collection(PairPlanOutbox), targets: db.collection(PairPushTarget),
    archives: db.collection(PairPlanEventArchive) };
}
function due(status: string, now: number): boolean {
  if (status === 'PENDING') return true;
  const value = /^SENDING:(\d+):[a-f0-9-]{36}(?::[1-3])?$/.exec(status);
  return value !== null && Number(value[1]) <= now;
}
/** Claim via the same binding conflict anchor as revoke/registerPush. Network is outside the transaction. */
async function claim(id: string): Promise<Claim | null> {
  const db = dbs(); let result: Claim | null = null;
  const selected = await db.events.query().equalTo('id', id).limit(2).get();
  if (selected.length !== 1) return null;
  const pairId = selected[0].getPairId(); const now = Date.now();
  const committed = await db.bindings.runTransaction({ async apply(tx) {
    const bindings = await tx.executeQuery(db.bindings.query().equalTo('id', pairId).limit(2));
    const events = await tx.executeQuery(db.events.query().equalTo('id', id).limit(2));
    const targets = await tx.executeQuery(db.targets.query().equalTo('id', digest([pairId, selected[0].getTargetUid()])).limit(2));
    const plans = await tx.executeQuery(db.plans.query().equalTo('id', digest([pairId, selected[0].getPlanId()])).limit(2));
    if (bindings.length !== 1 || events.length !== 1) return true;
    const binding = Object.assign(new PairMemberBinding(), bindings[0]);
    const head = binding.getStorageVersion() >= 2 && binding.getStatus() === 'ACTIVE' ? await storageHead(tx, pairId) : null;
    const event = Object.assign(new PairPlanOutbox(), events[0]);
    if (!due(event.getStatus(), now)) return true;
    if (binding.getStatus() !== 'ACTIVE' || Math.min(event.getExpiresAt(), event.getCreatedAt() + 3600000) <= now || plans.length !== 1
      || plans[0].getStateVersion() !== event.getStateVersion()
      || ![binding.getCreatorSubject(), binding.getRecipientSubject()].includes(event.getTargetUid())) {
      event.setStatus('SKIPPED');
    } else if (targets.length !== 1 || targets[0].getEnabled() !== true || !targets[0].getToken()) event.setStatus('SKIPPED');
    else {
      const match = /^SENDING:\d+:[a-f0-9-]{36}:([1-3])$/.exec(event.getStatus());
      const attempt = match === null ? 1 : Number(match[1]) + 1;
      if (attempt > 3) event.setStatus('FAILED');
      else {
        const lease = 'SENDING:' + (now + 120000) + ':' + randomUUID() + ':' + attempt; event.setStatus(lease);
        result = { event, token: targets[0].getToken(), lease, attempt };
      }
    }
    if (binding.getRevision() >= 2147483646) return false;
    binding.setRevision(binding.getRevision() + 1); binding.setUpdatedAt(now);
    tx.executeUpsert([binding]);
    if (head && ['SKIPPED', 'FAILED'].includes(event.getStatus())) {
      head.setEventCount(head.getEventCount() - 1);
      if (head.getEventCount() < 0) throw new Error('BAD_COUNTER');
      saveHead(tx, head); tx.executeUpsert([eventArchive(event)]); tx.executeDelete([event]);
    } else tx.executeUpsert([event]);
    return true;
  } });
  return committed ? result : null;
}
async function finish(item: Claim, status = 'SENT'): Promise<void> {
  const db = dbs();
  await db.bindings.runTransaction({ async apply(tx) {
    const bindings = await tx.executeQuery(db.bindings.query().equalTo('id', item.event.getPairId()).limit(2));
    const events = await tx.executeQuery(db.events.query().equalTo('id', item.event.getId()).limit(2));
    if (bindings.length !== 1 || events.length !== 1 || events[0].getStatus() !== item.lease) return true;
    const binding = Object.assign(new PairMemberBinding(), bindings[0]);
    const head = binding.getStorageVersion() >= 2 && binding.getStatus() === 'ACTIVE'
      ? await storageHead(tx, item.event.getPairId()) : null;
    const event = Object.assign(new PairPlanOutbox(), events[0]);
    if (binding.getRevision() >= 2147483646) return false;
    binding.setRevision(binding.getRevision() + 1); binding.setUpdatedAt(Date.now());
    event.setStatus(binding.getStatus() === 'ACTIVE' ? status : 'SKIPPED');
    tx.executeUpsert([binding]);
    if (head) {
      head.setEventCount(head.getEventCount() - 1);
      if (head.getEventCount() < 0) throw new Error('BAD_COUNTER');
      saveHead(tx, head); tx.executeUpsert([eventArchive(event)]); tx.executeDelete([event]);
    } else tx.executeUpsert([event]);
    return true;
  } });
}
/** Bounded, at-least-once delivery. Provider ACK is not evidence of delivery to a phone. */
async function deliver(item: Claim, delivery: PushDelivery): Promise<number> {
  try {
    if (await delivery.send(item.token, item.event.getKind(), item.event.getId())) { await finish(item); return 1; }
    if (item.attempt === 3) await finish(item, 'FAILED');
  } catch {
    if (item.attempt === 3) { try { await finish(item, 'FAILED'); } catch { /* Durable lease resumes in the worker. */ } }
  }
  return 0;
}
/** Foreground fallback/wake sends the committed event, never an older pair backlog instead. */
export async function dispatchEvent(eventId: string, delivery: PushDelivery = new HuaweiPush()): Promise<number> {
  if (process.env.FORTWO_ENABLE_SHARED_PLAN_V1 !== 'true' || process.env.FORTWO_ENABLE_PLAN_PUSH !== 'true'
    || !/^[a-f0-9]{64}$/.test(eventId)) return 0;
  const item = await claim(eventId);
  return item ? deliver(item, delivery) : 0;
}
export async function dispatch(pairId = '', delivery: PushDelivery = new HuaweiPush()): Promise<number> {
  if (process.env.FORTWO_ENABLE_SHARED_PLAN_V1 !== 'true' || process.env.FORTWO_ENABLE_PLAN_PUSH !== 'true') return 0;
  const db = dbs(); const now = Date.now(); let rows: PairPlanOutbox[];
  if (pairId) rows = await db.events.query().equalTo('pairId', pairId).limit(401).get();
  else {
    // Dedicated scheduled worker resumes abandoned leases as well as fresh pending events.
    const pending = await db.events.query().equalTo('status', 'PENDING').limit(16).get();
    const leases = await db.events.query().greaterThanOrEqualTo('status', 'SENDING:')
      .lessThan('status', 'SENDING;').limit(16).get();
    rows = pending.concat(leases);
  }
  let sent = 0; let attempts = 0;
  for (const event of rows.filter(row => due(row.getStatus(), now)).sort((a, b) => a.getCreatedAt() - b.getCreatedAt()).slice(0, 32)) {
    const item = await claim(event.getId()); if (!item) continue;
    sent += await deliver(item, delivery);
    if (++attempts >= (pairId ? 1 : 2)) break; // Obsolete rows do not consume provider budget.
  }
  return sent;
}
