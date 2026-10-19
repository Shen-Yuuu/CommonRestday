import { PairDatePlan } from './models';
import { Rejection } from './identity';
import { ECDH } from 'crypto';

export const MAX_PLANS = 50;
export const MAX_REQUESTS = 200;
export const MAX_EVENTS = MAX_REQUESTS * 2;
export const PENDING_TTL = 7 * 86400000;
export const PAIR_TTL = 86400000;

export interface Command {
  pairId: string;
  planId: string;
  requestId: string;
  action: string;
  expectedVersion: number;
  envelope: string;
}
export function validId(id: string): boolean {
  return typeof id === 'string' && /^[A-Za-z0-9_-]{1,128}$/.test(id);
}
export function parseCommand(input: string): Command {
  if (typeof input !== 'string' || input.length > 20000) throw new Rejection('BAD_REQUEST');
  let row: Command;
  try { row = JSON.parse(input) as Command; } catch { throw new Rejection('BAD_REQUEST'); }
  if (!row || Array.isArray(row) || Object.keys(row).sort().join(',') !== 'action,envelope,expectedVersion,pairId,planId,requestId'
    || !validId(row.pairId) || !validId(row.planId) || !validId(row.requestId)
    || !['PROPOSE', 'ACCEPT', 'DECLINE', 'WITHDRAW', 'CANCEL', 'AMEND'].includes(row.action)
    || !Number.isSafeInteger(row.expectedVersion) || row.expectedVersion < 0 || row.expectedVersion >= 2147483647
    || typeof row.envelope !== 'string') throw new Rejection('BAD_REQUEST');
  return row;
}

interface Envelope {
  protocolVersion: number;
  contentRevision: number;
  algorithm: string;
  iv: string;
  authTag: string;
  ciphertext: string;
}
function base64(value: string, bytes: number | null): boolean {
  if (typeof value !== 'string' || !value || !/^[A-Za-z0-9+/]+={0,2}$/.test(value)) return false;
  const decoded = Buffer.from(value, 'base64');
  return decoded.toString('base64') === value && (bytes === null ? decoded.length > 0 : decoded.length === bytes);
}
export function validPublicKey(value: string): boolean {
  if (typeof value !== 'string' || value.length > 200 || !base64(value, 65)
    || Buffer.from(value, 'base64')[0] !== 4) return false;
  try { ECDH.convertKey(Buffer.from(value, 'base64'), 'prime256v1'); return true; } catch { return false; }
}
export function checkEnvelope(input: string, revision: number): void {
  let row: Envelope;
  try { row = JSON.parse(input) as Envelope; } catch { throw new Rejection('BAD_ENVELOPE'); }
  if (!row || Array.isArray(row) || input.length > 12000
    || Object.keys(row).sort().join(',') !== 'algorithm,authTag,ciphertext,contentRevision,iv,protocolVersion'
    || row.protocolVersion !== 1 || row.contentRevision !== revision || row.algorithm !== 'AES-256-GCM'
    || !base64(row.iv, 12) || !base64(row.authTag, 16) || !base64(row.ciphertext, null)
    || row.ciphertext.length > 8192) throw new Rejection('BAD_ENVELOPE');
  // Structure only; authenticity/AAD/date/conflict checks belong to the decrypting clients.
}

export function planBody(row: PairDatePlan): Record<string, Object> {
  return { pairId: row.getPairId(), planId: row.getPlanId(), proposerUid: row.getProposerUid(),
    recipientUid: row.getRecipientUid(), state: row.getState(), stateVersion: row.getStateVersion(),
    contentRevision: row.getContentRevision(), acceptedRevision: row.getAcceptedRevision(),
    pendingAuthorUid: row.getPendingAuthorUid(), pendingEnvelope: row.getPendingEnvelope(),
    acceptedEnvelope: row.getAcceptedEnvelope(), pendingExpiresAt: row.getPendingExpiresAt(),
    updatedAt: row.getUpdatedAt(), protocolVersion: 1 };
}

export function transition(row: PairDatePlan, who: string, command: Command, now: number): string {
  if (who !== row.getProposerUid() && who !== row.getRecipientUid()) throw new Rejection('FORBIDDEN');
  if (command.expectedVersion !== row.getStateVersion()) throw new Rejection('VERSION_CONFLICT');
  if (row.getStateVersion() >= 2147483646 || row.getContentRevision() >= 2147483646) throw new Rejection('VERSION_LIMIT');
  if (command.action === 'AMEND') {
    if (row.getState() !== 'ACCEPTED' || row.getPendingEnvelope()) throw new Rejection('STATE_CONFLICT');
    checkEnvelope(command.envelope, row.getContentRevision() + 1);
    row.setContentRevision(row.getContentRevision() + 1);
    row.setPendingEnvelope(command.envelope); row.setPendingAuthorUid(who);
    row.setPendingExpiresAt(now + PENDING_TTL);
  } else {
    if (command.envelope !== '') throw new Rejection('BAD_REQUEST');
    if (command.action === 'CANCEL') {
      if (row.getState() !== 'ACCEPTED') throw new Rejection('STATE_CONFLICT');
      row.setState('CANCELLED');
    } else {
      if (!['PENDING', 'ACCEPTED'].includes(row.getState()) || !row.getPendingEnvelope()) throw new Rejection('STATE_CONFLICT');
      if (row.getPendingExpiresAt() <= now) throw new Rejection('INVITE_EXPIRED');
      const withdrawing = command.action === 'WITHDRAW';
      if ((withdrawing && row.getPendingAuthorUid() !== who) || (!withdrawing && row.getPendingAuthorUid() === who)) {
        throw new Rejection('FORBIDDEN');
      }
      if (command.action === 'ACCEPT') {
        row.setState('ACCEPTED'); row.setAcceptedRevision(row.getContentRevision());
        row.setAcceptedEnvelope(row.getPendingEnvelope());
      } else if (row.getState() === 'PENDING') row.setState(withdrawing ? 'WITHDRAWN' : 'DECLINED');
    }
    row.setPendingAuthorUid(''); row.setPendingEnvelope(''); row.setPendingExpiresAt(0);
  }
  row.setStateVersion(row.getStateVersion() + 1); row.setUpdatedAt(now);
  return command.action;
}
