import { cryptoFramework } from '@kit.CryptoArchitectureKit';
import { PlanConnectionFailure } from 'commons';
import { PairKeyStore } from './PairKeyStore';
import { EncryptedPayload, SnapshotCrypto } from './SnapshotCrypto';

interface PlanEnvelope {
  protocolVersion: number; contentRevision: number; algorithm: string;
  iv: string; authTag: string; ciphertext: string;
}

// Canonical X.509 SPKI: ecPublicKey + prime256v1 + a zero-unused-bits, uncompressed point.
const P256_SPKI_PREFIX: number[] = [0x30, 0x59, 0x30, 0x13, 0x06, 0x07, 0x2a, 0x86,
  0x48, 0xce, 0x3d, 0x02, 0x01, 0x06, 0x08, 0x2a, 0x86, 0x48, 0xce, 0x3d,
  0x03, 0x01, 0x07, 0x03, 0x42, 0x00];

/** Only the supported P-256 public formats; never strip an arbitrary DER tail. */
export function planPublicPoint(bytes: Uint8Array): Uint8Array {
  if (bytes.length === 65 && bytes[0] === 4) return bytes;
  if (bytes.length === 64) {
    const point = new Uint8Array(65); point[0] = 4; point.set(bytes, 1); return point;
  }
  if (bytes.length === P256_SPKI_PREFIX.length + 65 && bytes[P256_SPKI_PREFIX.length] === 4) {
    for (let i = 0; i < P256_SPKI_PREFIX.length; i++) {
      if (bytes[i] !== P256_SPKI_PREFIX[i]) throw new Error('PLAN_PUBLIC_KEY_FORMAT');
    }
    return bytes.slice(P256_SPKI_PREFIX.length);
  }
  throw new Error('PLAN_PUBLIC_KEY_FORMAT');
}
function agreementPublicKey(own: Uint8Array, peer: Uint8Array): Uint8Array {
  planPublicPoint(own);
  if (own.length === 64) return peer.slice(1);
  if (own.length === 65) return peer;
  const der = new Uint8Array(P256_SPKI_PREFIX.length + 65);
  der.set(P256_SPKI_PREFIX); der.set(peer, P256_SPKI_PREFIX.length);
  return der;
}
async function slot(value: string): Promise<string> {
  try {
    if (typeof value !== 'string' || value.length === 0 || value.length > 320) throw new Error('PLAN_KEY_ID');
    const md = cryptoFramework.createMd('SHA256');
    await md.update({ data: SnapshotCrypto.encodeText(value) });
    const result = await md.digest();
    let out = '';
    for (const byte of result.data) out += byte.toString(16).padStart(2, '0');
    return out;
  } catch (error) { throw new PlanConnectionFailure('key.hash', error as Object, 'PLAN_KEY_ID_UNAVAILABLE'); }
}
function identityInput(uid: string): string {
  if (typeof uid !== 'string' || uid.length === 0 || uid.length > 256) throw new Error('PLAN_IDENTITY_ID');
  return 'FT_PLAN_DEVICE|' + uid;
}
function pairInput(pairId: string): string {
  if (!/^sp-[a-f0-9]{32}$/.test(pairId)) throw new Error('PLAN_PAIR_ID');
  return 'FT_PLAN_PAIR|' + pairId;
}
function canonicalB64(value: string, length: number = 0): boolean {
  if (typeof value !== 'string' || value.length === 0 || !/^[A-Za-z0-9+/]+={0,2}$/.test(value)) return false;
  try {
    const bytes = SnapshotCrypto.fromB64(value);
    return (length === 0 ? bytes.length > 0 : bytes.length === length) && SnapshotCrypto.toB64(bytes) === value;
  } catch { return false; }
}
export class SecurePlanKeyStore {
  /** Domain-separated public locator hash; does not expose or derive any key material. */
  static pairingRoute(pairId: string): Promise<string> {
    if (!/^[A-Za-z0-9_-]{1,128}$/.test(pairId)) return Promise.reject(new Error('PAIR_CONTEXT_INVALID'));
    return slot('FORTWO_UNIFIED_PAIRING_V1|' + pairId);
  }
  private static async proofScope(uid: string, flowId: string): Promise<string> {
    if (!/^[A-Za-z0-9_-]{1,128}$/.test(flowId)) throw new Error('PLAN_FLOW_ID');
    return 'FT_PLAN_CONFIRM|' + await slot(identityInput(uid)) + '|' + flowId;
  }
  static async sealProof(uid: string, flowId: string, secret: string): Promise<string> {
    if (!/^[A-Za-z0-9_-]{32}$/.test(secret)) throw new Error('PLAN_PROOF_FORMAT');
    const aad = await SecurePlanKeyStore.proofScope(uid, flowId);
    return JSON.stringify(await PairKeyStore.sealPlanProof(await slot(aad), aad, secret));
  }
  static async openProof(uid: string, flowId: string, raw: string): Promise<string | null> {
    try {
      if (typeof raw !== 'string' || raw.length > 2048) return null;
      const payload = JSON.parse(raw) as EncryptedPayload;
      if (payload === null || payload.algorithm !== 'AES-256-GCM' || !canonicalB64(payload.iv, 12)
        || !canonicalB64(payload.authTag, 16) || !canonicalB64(payload.ciphertext, 32)) return null;
      const aad = await SecurePlanKeyStore.proofScope(uid, flowId);
      const secret = await PairKeyStore.openPlanProof(await slot(aad), aad, payload);
      return secret !== null && /^[A-Za-z0-9_-]{32}$/.test(secret) ? secret : null;
    } catch { return null; }
  }
  static async dropProof(uid: string, flowId: string): Promise<void> {
    await PairKeyStore.dropPlanProof(await slot(await SecurePlanKeyStore.proofScope(uid, flowId)));
  }
  static async drop(pairId: string): Promise<void> {
    await PairKeyStore.dropPlanKey(await slot(pairInput(pairId)));
  }
  static async publicKey(uid: string, allowCreate: boolean): Promise<string> {
    const own = await PairKeyStore.planPublicKey(await slot(identityInput(uid)), allowCreate);
    let point: Uint8Array;
    try { point = planPublicPoint(own); }
    catch (error) { throw new PlanConnectionFailure('key.identity.format', error as Object, 'PLAN_PUBLIC_KEY_FORMAT'); }
    try { return SnapshotCrypto.toB64(point); }
    catch (error) { throw new PlanConnectionFailure('key.identity.encode', error as Object, 'PLAN_PUBLIC_KEY_ENCODING'); }
  }
  static async agree(uid: string, pairId: string, peerPublicKey: string): Promise<void> {
    if (!canonicalB64(peerPublicKey, 65)) throw new Error('PLAN_PEER_KEY_FORMAT');
    const peer = SnapshotCrypto.fromB64(peerPublicKey);
    if (peer[0] !== 4) throw new Error('PLAN_PEER_KEY_FORMAT');
    const identitySlot = await slot(identityInput(uid));
    const own = await PairKeyStore.planPublicKey(identitySlot, false);
    let agreementPeer: Uint8Array;
    try { agreementPeer = agreementPublicKey(own, peer); }
    catch (error) { throw new PlanConnectionFailure('key.agree.format', error as Object, 'PLAN_PUBLIC_KEY_FORMAT'); }
    // Feed back the same public representation exported by this installed HUKS implementation.
    await PairKeyStore.agreePlanKey(identitySlot, await slot(pairInput(pairId)), agreementPeer);
  }
  static async available(pairId: string): Promise<boolean> {
    try { return await PairKeyStore.hasPlanKey(await slot(pairInput(pairId))); } catch { return false; }
  }
  static async seal(pairId: string, aad: string, plain: string, revision: number): Promise<string> {
    if (!Number.isSafeInteger(revision) || revision < 1 || plain.length === 0 || plain.length > 4096) throw new Error('PLAN_CONTENT_SIZE');
    const payload = await PairKeyStore.sealPlan(await slot(pairInput(pairId)), aad, plain);
    const envelope: PlanEnvelope = { protocolVersion: 1, contentRevision: revision, algorithm: payload.algorithm,
      iv: payload.iv, authTag: payload.authTag, ciphertext: payload.ciphertext };
    return JSON.stringify(envelope);
  }
  static async open(pairId: string, aad: string, raw: string, revision: number): Promise<string | null> {
    try {
      if (typeof raw !== 'string' || raw.length > 12000) return null;
      const envelope = JSON.parse(raw) as PlanEnvelope;
      if (envelope === null || envelope.protocolVersion !== 1 || envelope.contentRevision !== revision
        || envelope.algorithm !== 'AES-256-GCM' || !canonicalB64(envelope.iv, 12)
        || !canonicalB64(envelope.authTag, 16) || !canonicalB64(envelope.ciphertext)
        || envelope.ciphertext.length > 8192) return null;
      const payload: EncryptedPayload = { algorithm: envelope.algorithm, iv: envelope.iv,
        authTag: envelope.authTag, ciphertext: envelope.ciphertext };
      const plain = await PairKeyStore.openPlan(await slot(pairInput(pairId)), aad, payload);
      return plain !== null && plain.length <= 4096 ? plain : null;
    } catch { return null; }
  }
}
