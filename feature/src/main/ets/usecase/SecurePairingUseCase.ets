import { PlanIdentity, PlanIdentityPort, PlanCloudPort } from './SecureSharedPlanGateway';
import { PlanConnectionDiagnostic, PlanConnectionFailure, planConnectionDiagnostic, planConnectionSdkCode } from 'commons';

export interface SecurePairingIntent {
  flowId: string; role: string; authUid: string; publicKey: string; joinCode: string;
  inviteCode: string; pairId: string; actorId: string; peerId: string; peerPublicKey: string;
  phase: string; sealedProof: string; revision: number; expiresAt: number; anchor: string;
  linkEnvelope?: string;
  expectedPairId?: string; expectedPeerKey?: string; bootstrapOffer?: string;
}
export interface SecurePairingSession { pairId: string; actorId: string; generation: string; }
export interface SecurePairingResult {
  code: string; phase: string; inviteCode: string; canConfirm: boolean;
  diagnostic?: PlanConnectionDiagnostic;
}
export interface SecurePairingKeys {
  publicKey(uid: string, allowCreate: boolean): Promise<string>;
  sealProof(uid: string, flowId: string, secret: string): Promise<string>;
  openProof(uid: string, flowId: string, envelope: string): Promise<string | null>;
  agree(uid: string, pairId: string, peerPublicKey: string): Promise<void>;
  available(pairId: string): Promise<boolean>;
  dropProof(uid: string, flowId: string): Promise<void>;
  drop(pairId: string): Promise<void>;
  linkProof?(publicKey: string, flowId: string): Promise<string>;
  verifyLink?(peerPublicKey: string, envelope: string): Promise<boolean>;
}
export interface SecurePairingStore {
  load(): Promise<string>;
  hasCleanup(): Promise<boolean>;
  save(expected: string, next: string): Promise<boolean>;
  activate(expected: string, next: string, session: SecurePairingSession): Promise<boolean>;
  revoke(expected: string, next: string): Promise<boolean>;
}
export interface SecurePairingEnvironment {
  enabled(): boolean;
  cleanupEnabled(): boolean;
  anchor(): string;
  epoch(): string;
  nextId(): string;
}
interface PairReply {
  code: string; pairId: string; status: string; myUid: string; peerUid: string; peerPublicKey: string;
  protocolVersion: number; projectionVersion: number; sharedPlanReady: boolean;
  revision: number; expiresAt: number | string; inviteCode?: string; confirmSecret?: string;
  peerLink?: string;
}
class PairingFailure extends Error {
  code: string;
  constructor(code: string) { super('Secure pairing stopped'); this.code = code; }
}
function stop(code: string): never { throw new PairingFailure(code); }
function publicKeyShape(key: string): boolean { return typeof key === 'string' && /^B[A-Za-z0-9+/]{86}=$/.test(key); }
/** CloudDB Long fields arrive as decimal text; other reply fields are not coerced. */
function replyExpiry(value: number | string): number {
  let parsed = -1;
  if (typeof value === 'number') parsed = value;
  else if (typeof value === 'string' && /^(0|[1-9]\d{0,15})$/.test(value)) parsed = Number(value);
  return Number.isSafeInteger(parsed) && parsed >= 0 ? parsed : -1;
}
function intentOf(raw: string): SecurePairingIntent {
  if (raw.length > 8192) stop('STATE_INVALID');
  const state = JSON.parse(raw) as SecurePairingIntent;
  if (state !== null && ((state.expectedPairId !== undefined && !/^sp-[a-f0-9]{32}$/.test(state.expectedPairId))
    || (state.expectedPeerKey !== undefined && !publicKeyShape(state.expectedPeerKey))
    || (state.bootstrapOffer !== undefined && (typeof state.bootstrapOffer !== 'string' || state.bootstrapOffer.length > 4096)))) stop('STATE_INVALID');
  if (state === null || !/^[A-Za-z0-9_-]{1,128}$/.test(state.flowId)
    || !['CREATOR', 'JOINER'].includes(state.role) || typeof state.authUid !== 'string'
    || state.authUid.length === 0 || state.authUid.length > 256 || !publicKeyShape(state.publicKey)
    || !['CREATING', 'JOINING', 'WAITING', 'PENDING_CONFIRM', 'ACTIVE', 'REVOKED'].includes(state.phase)
    || typeof state.anchor !== 'string' || state.anchor.length > 2048 || typeof state.sealedProof !== 'string'
    || state.sealedProof.length > 2048 || typeof state.joinCode !== 'string' || typeof state.inviteCode !== 'string'
    || typeof state.pairId !== 'string' || (state.pairId !== '' && !/^sp-[a-f0-9]{32}$/.test(state.pairId))
    || typeof state.actorId !== 'string' || (state.actorId !== '' && !/^m-[a-f0-9]{64}$/.test(state.actorId))
    || typeof state.peerId !== 'string' || (state.peerId !== '' && !/^m-[a-f0-9]{64}$/.test(state.peerId))
    || typeof state.peerPublicKey !== 'string' || (state.peerPublicKey !== '' && !publicKeyShape(state.peerPublicKey))
    || !Number.isSafeInteger(state.revision) || state.revision < 0
    || !Number.isSafeInteger(state.expiresAt) || state.expiresAt < 0
    || (state.role === 'JOINER' && !/^\d{6}$/.test(state.joinCode))) stop('STATE_INVALID');
  return state;
}
function resultOf(code: string, state: SecurePairingIntent | null = null): SecurePairingResult {
  return { code, phase: state === null ? 'EMPTY' : state.phase,
    inviteCode: state !== null && state.role === 'CREATOR' && ['WAITING', 'PENDING_CONFIRM'].includes(state.phase)
      ? state.inviteCode : '',
    canConfirm: state !== null && state.role === 'CREATOR' && state.phase === 'PENDING_CONFIRM' };
}

/** Durable, explicit setup. No polling, legacy identity adoption or plaintext proof persistence. */
export class SecurePairingUseCase {
  private busy: boolean = false;
  private operationEpoch: string = '';
  private diagnosticStage: string = 'setup';
  private identity: PlanIdentityPort;
  private cloud: PlanCloudPort;
  private keys: SecurePairingKeys;
  private store: SecurePairingStore;
  private env: SecurePairingEnvironment;
  constructor(identity: PlanIdentityPort, cloud: PlanCloudPort, keys: SecurePairingKeys,
    store: SecurePairingStore, env: SecurePairingEnvironment) {
    this.identity = identity; this.cloud = cloud; this.keys = keys; this.store = store; this.env = env;
  }

  async local(): Promise<SecurePairingResult> {
    try { const raw = await this.store.load(); return resultOf('OK', raw === '' ? null : intentOf(raw)); }
    catch (error) {
      const result = resultOf('STATE_INVALID');
      result.diagnostic = planConnectionDiagnostic('store.read', planConnectionSdkCode(error as Object));
      return result;
    }
  }
  private async exclusive(work: () => Promise<SecurePairingResult>, cleanup: boolean = false): Promise<SecurePairingResult> {
    if (!(cleanup ? this.env.cleanupEnabled() : this.env.enabled())) return resultOf('FEATURE_DISABLED');
    if (this.busy) return resultOf('BUSY');
    this.busy = true;
    this.diagnosticStage = 'store.read';
    this.operationEpoch = this.env.epoch();
    try { return await work(); }
    catch (error) {
      const code = error instanceof PairingFailure ? error.code : 'RESULT_UNKNOWN';
      const diagnostic = error instanceof PlanConnectionFailure ? error.diagnostic
        : planConnectionDiagnostic(this.diagnosticStage, planConnectionSdkCode(error as Object));
      const local = await this.local(); local.code = code; local.diagnostic = diagnostic; return local;
    } finally { this.busy = false; this.diagnosticStage = 'setup'; }
  }
  create(): Promise<SecurePairingResult> { return this.exclusive(() => this.start('CREATOR', '')); }
  /** Foreground may inspect an ACTIVE binding, but must not replay CREATE/JOIN/CONFIRM. */
  refreshActive(): Promise<SecurePairingResult> {
    return this.exclusive(async () => {
      const raw = await this.store.load(); if (raw === '') return resultOf('NO_PROGRESS');
      const state = intentOf(raw);
      if (state.phase !== 'ACTIVE') return resultOf('NO_PROGRESS', state);
      const reply = await this.invoke(raw, state, 'pairStatus', [state.pairId]);
      if (reply.code === 'SESSION_REVOKED') return this.revoked(raw, state);
      if (reply.code !== 'OK') this.rejected(reply);
      if (reply.status !== 'ACTIVE') stop('INVALID_REPLY');
      return this.accept(raw, state, reply);
    });
  }
  join(code: string): Promise<SecurePairingResult> {
    if (typeof code !== 'string' || !/^\d{6}$/.test(code.trim())) return Promise.resolve(resultOf('BAD_REQUEST'));
    return this.exclusive(() => this.start('JOINER', code.trim()));
  }
  joinLinked(code: string, pairId: string, peerKey: string): Promise<SecurePairingResult> {
    if (!/^\d{6}$/.test(code) || !/^sp-[a-f0-9]{32}$/.test(pairId) || !publicKeyShape(peerKey)) {
      return Promise.resolve(resultOf('BAD_REQUEST'));
    }
    return this.exclusive(() => this.start('JOINER', code, pairId, peerKey));
  }
  private async start(role: string, code: string, expectedPairId: string = '', expectedPeerKey: string = ''): Promise<SecurePairingResult> {
    // Rejoining an old ACTIVE binding while its deletion is queued could delete the new connection.
    this.diagnosticStage = 'store.cleanup';
    if (await this.store.hasCleanup()) stop('CLEANUP_REQUIRED');
    this.diagnosticStage = 'store.read';
    const expected = await this.store.load();
    this.diagnosticStage = 'state.check';
    if (!this.env.enabled() || this.env.epoch() !== this.operationEpoch) stop('SESSION_CHANGED');
    if (expected !== '' && intentOf(expected).phase !== 'REVOKED') stop('RESUME_REQUIRED');
    const anchor = this.env.anchor();
    this.diagnosticStage = 'auth.user';
    const credentials = await this.identity.credential(true);
    this.diagnosticStage = 'key.identity';
    const publicKey = await this.keys.publicKey(credentials.uid, true);
    const state: SecurePairingIntent = { flowId: this.env.nextId(), role, authUid: credentials.uid, publicKey,
      joinCode: code, inviteCode: '', pairId: '', actorId: '', peerId: '', peerPublicKey: '',
      phase: role === 'CREATOR' ? 'CREATING' : 'JOINING', sealedProof: '', revision: 0, expiresAt: 0, anchor };
    if (expectedPairId !== '') { state.expectedPairId = expectedPairId; state.expectedPeerKey = expectedPeerKey; }
    if (this.keys.linkProof !== undefined) {
      this.diagnosticStage = 'key.partnerProof';
      state.linkEnvelope = await this.keys.linkProof(publicKey, state.flowId);
    }
    this.diagnosticStage = 'state.check';
    const raw = JSON.stringify(state); intentOf(raw);
    if (this.env.anchor() !== anchor || this.env.epoch() !== this.operationEpoch || !this.env.enabled()) stop('SESSION_CHANGED');
    this.diagnosticStage = 'store.write';
    if (!await this.store.save(expected, raw)) stop('SESSION_CHANGED');
    return this.resumeFlow(raw, state);
  }
  private async current(raw: string, state: SecurePairingIntent, cleanup: boolean = false): Promise<PlanIdentity> {
    this.diagnosticStage = 'state.check';
    if (this.env.epoch() !== this.operationEpoch) stop('SESSION_CHANGED');
    this.diagnosticStage = 'store.read';
    if (await this.store.load() !== raw || this.env.epoch() !== this.operationEpoch
      || (!cleanup && this.env.anchor() !== state.anchor)) stop('SESSION_CHANGED');
    this.diagnosticStage = 'auth.user';
    const credentials = await this.identity.credential(false);
    this.diagnosticStage = 'state.check';
    if (credentials.uid !== state.authUid) stop('IDENTITY_CHANGED');
    // Cleanup is authorized by the original authenticated UID, even if the local key was lost.
    this.diagnosticStage = 'key.identity';
    if (!cleanup && await this.keys.publicKey(credentials.uid, false) !== state.publicKey) stop('KEY_CHANGED');
    this.diagnosticStage = 'store.read';
    if (await this.store.load() !== raw || this.env.epoch() !== this.operationEpoch
      || (!cleanup && this.env.anchor() !== state.anchor)) stop('SESSION_CHANGED');
    this.diagnosticStage = 'state.check';
    if (!(cleanup ? this.env.cleanupEnabled() : this.env.enabled())) stop('FEATURE_DISABLED');
    return credentials;
  }
  private async invoke(raw: string, state: SecurePairingIntent, method: string, params: Object[], cleanup: boolean = false): Promise<PairReply> {
    const credentials = await this.current(raw, state, cleanup);
    this.diagnosticStage = 'cloud.call';
    const reply = await this.cloud.invoke(method, credentials.accessToken, params);
    await this.current(raw, state, cleanup);
    this.diagnosticStage = 'cloud.decode';
    if (reply.length > 8192) stop('INVALID_REPLY');
    const parsed = JSON.parse(reply) as PairReply;
    if (parsed === null || typeof parsed.code !== 'string') stop('INVALID_REPLY');
    return parsed;
  }
  private rejected(reply: PairReply): void {
    this.diagnosticStage = 'cloud.reply';
    const known = ['AUTH_REJECTED', 'FEATURE_DISABLED', 'CAPABILITY_UNAVAILABLE', 'CODE_EXPIRED', 'CODE_TAKEN',
      'CODE_COLLISION', 'KEY_CHANGED', 'FORBIDDEN', 'PAIR_NOT_READY', 'REQUEST_REUSED', 'VERSION_CONFLICT',
      'BACKLOG_FULL', 'CLEANUP_REQUIRED', 'CLEANUP_PENDING', 'NOT_FOUND', 'CONFIG_MISSING', 'CODE_SPACE_BUSY', 'RESULT_UNKNOWN', 'VERSION_LIMIT'];
    stop(known.includes(reply.code) ? reply.code : 'RESULT_UNKNOWN');
  }
  private invalidReply(stage: string): never {
    this.diagnosticStage = stage; stop('INVALID_REPLY');
  }
  resume(): Promise<SecurePairingResult> {
    return this.exclusive(async () => {
      const raw = await this.store.load();
      if (raw === '') return resultOf('NO_PROGRESS');
      return this.resumeFlow(raw, intentOf(raw));
    });
  }
  private async resumeFlow(raw: string, state: SecurePairingIntent): Promise<SecurePairingResult> {
    if (state.phase === 'REVOKED') return resultOf('OK', state);
    let method = 'pairStatus'; let params: Object[] = [state.pairId];
    await this.current(raw, state);
    this.diagnosticStage = 'key.confirmProof';
    const proofMissing = state.role === 'CREATOR' && state.phase !== 'ACTIVE'
      && (state.sealedProof === '' || await this.keys.openProof(state.authUid, state.flowId, state.sealedProof) === null);
    if (state.pairId === '' || proofMissing) {
      method = state.role === 'CREATOR' ? 'createPair' : 'joinPair';
      params = [state.role === 'CREATOR' ? state.flowId : state.joinCode, state.publicKey, 1];
      if (this.keys.linkProof !== undefined) {
        if (typeof state.linkEnvelope !== 'string' || state.linkEnvelope.length === 0) stop('PARTNER_LINK_REQUIRED');
        params.push(state.linkEnvelope);
      }
    }
    return this.accept(raw, state, await this.invoke(raw, state, method, params));
  }
  confirm(): Promise<SecurePairingResult> {
    return this.exclusive(async () => {
      const raw = await this.store.load(); if (raw === '') stop('NO_PROGRESS');
      const state = intentOf(raw);
      if (state.role !== 'CREATOR' || state.phase !== 'PENDING_CONFIRM') stop('FORBIDDEN');
      await this.current(raw, state);
      this.diagnosticStage = 'key.confirmProof';
      const proof = await this.keys.openProof(state.authUid, state.flowId, state.sealedProof);
      if (proof === null) stop('PROOF_UNAVAILABLE');
      return this.accept(raw, state, await this.invoke(raw, state, 'confirmPair', [state.pairId, proof]));
    });
  }
  private async accept(raw: string, state: SecurePairingIntent, reply: PairReply): Promise<SecurePairingResult> {
    if (reply.code === 'SESSION_REVOKED') return this.revoked(raw, state);
    if (reply.code !== 'OK') this.rejected(reply);
    if (state.expectedPairId !== undefined && (reply.pairId !== state.expectedPairId
      || reply.peerPublicKey !== state.expectedPeerKey)) stop('PARTNER_LINK_REQUIRED');
    this.diagnosticStage = 'key.partnerProof';
    const pending = reply.status === 'PENDING_CONFIRM', active = reply.status === 'ACTIVE';
    if ((pending || active) && this.keys.verifyLink !== undefined
      && !await this.keys.verifyLink(reply.peerPublicKey, reply.peerLink ?? '')) stop('PARTNER_LINK_REQUIRED');
    this.diagnosticStage = 'reply.validate';
    if (!['WAITING', 'PENDING_CONFIRM', 'ACTIVE'].includes(reply.status)) this.invalidReply('reply.validate.status');
    if (!/^sp-[a-f0-9]{32}$/.test(reply.pairId) || !/^m-[a-f0-9]{64}$/.test(reply.myUid)) {
      this.invalidReply('reply.validate.identity');
    }
    if (reply.protocolVersion !== 1 || reply.projectionVersion !== 1 || reply.sharedPlanReady !== active) {
      this.invalidReply('reply.validate.capability');
    }
    if (!Number.isSafeInteger(reply.revision) || reply.revision < 1 || reply.revision < state.revision) {
      this.invalidReply('reply.validate.revision');
    }
    const expiresAt = replyExpiry(reply.expiresAt);
    if (expiresAt < 0) this.invalidReply('reply.validate.expiry');
    if ((state.pairId !== '' && state.pairId !== reply.pairId)
      || (state.actorId !== '' && state.actorId !== reply.myUid)
      || (state.peerId !== '' && state.peerId !== reply.peerUid)
      || (state.peerPublicKey !== '' && state.peerPublicKey !== reply.peerPublicKey)) {
      this.invalidReply('reply.validate.binding');
    }
    if ((state.phase === 'ACTIVE' && !active) || (state.role === 'JOINER' && reply.status === 'WAITING')) {
      this.invalidReply('reply.validate.transition');
    }
    if (((pending || active) && (!/^m-[a-f0-9]{64}$/.test(reply.peerUid)
      || reply.peerUid === reply.myUid || !publicKeyShape(reply.peerPublicKey)))
      || (reply.status === 'WAITING' && (reply.peerUid !== '' || reply.peerPublicKey !== ''))) {
      this.invalidReply('reply.validate.peer');
    }
    const next = intentOf(raw);
    next.pairId = reply.pairId; next.actorId = reply.myUid; next.peerId = reply.peerUid;
    next.peerPublicKey = reply.peerPublicKey; next.phase = reply.status;
    next.revision = reply.revision; next.expiresAt = expiresAt;
    if (reply.inviteCode !== undefined) {
      if (state.role !== 'CREATOR' || !/^\d{6}$/.test(reply.inviteCode)) this.invalidReply('reply.validate.invite');
      next.inviteCode = reply.inviteCode;
    }
    if (reply.confirmSecret !== undefined) {
      if (state.role !== 'CREATOR' || active || !/^[A-Za-z0-9_-]{32}$/.test(reply.confirmSecret)) {
        this.invalidReply('reply.validate.proof');
      }
      this.diagnosticStage = 'key.confirmProof';
      next.sealedProof = await this.keys.sealProof(state.authUid, state.flowId, reply.confirmSecret);
    }
    if (active) {
      // Persist the learned pair before deriving a key: a concurrent clear can now find its alias.
      const pinned = JSON.stringify(next);
      await this.current(raw, state);
      this.diagnosticStage = 'store.write';
      if (!await this.store.save(raw, pinned)) stop('SESSION_CHANGED');
      raw = pinned; state = intentOf(pinned);
      try {
        this.diagnosticStage = 'key.agree';
        await this.keys.agree(state.authUid, next.pairId, next.peerPublicKey);
        await this.current(raw, state);
        this.diagnosticStage = 'key.available';
        if (!await this.keys.available(next.pairId)) stop('KEY_UNAVAILABLE');
      } catch (error) {
        // A clear that ran while HUKS was deriving may have already swept the earlier alias state.
        if (this.env.epoch() !== this.operationEpoch || await this.store.load() !== raw) {
          try { await this.keys.drop(next.pairId); } catch { /* Persisted cleanup record retains the alias identity. */ }
        }
        throw error as Error;
      }
      next.inviteCode = ''; next.sealedProof = ''; next.bootstrapOffer = '';
    }
    await this.current(raw, state);
    const serialized = JSON.stringify(next);
    this.diagnosticStage = 'store.write';
    const saved = active ? await this.store.activate(raw, serialized,
      { pairId: next.pairId, actorId: next.actorId, generation: next.flowId }) : await this.store.save(raw, serialized);
    if (!saved) stop('SESSION_CHANGED');
    if (active && state.role === 'CREATOR') {
      try { await this.keys.dropProof(state.authUid, state.flowId); } catch { /* Unused local alias; no live cloud proof remains. */ }
    }
    return resultOf('OK', next);
  }
  /** Persist randomized ciphertext before publishing, so retries use exactly the same offer. */
  publishLink(route: string, seal: (state: SecurePairingIntent) => Promise<string>): Promise<SecurePairingResult> {
    return this.exclusive(async () => {
      let raw = await this.store.load(); if (raw === '') stop('NO_PROGRESS');
      let state = intentOf(raw);
      if (state.role !== 'CREATOR' || !['WAITING', 'PENDING_CONFIRM'].includes(state.phase)) stop('FORBIDDEN');
      await this.current(raw, state);
      if (!state.bootstrapOffer) {
        const next = intentOf(raw); next.bootstrapOffer = await seal(next);
        await this.current(raw, state);
        const serialized = JSON.stringify(next); intentOf(serialized);
        if (!await this.store.save(raw, serialized)) stop('SESSION_CHANGED');
        raw = serialized; state = intentOf(raw);
      }
      const reply = await this.invoke(raw, state, 'publishLink', [state.pairId, route, state.bootstrapOffer ?? '']);
      if (reply.code !== 'OK') this.rejected(reply);
      return resultOf('OK', state);
    });
  }
  disconnect(): Promise<SecurePairingResult> {
    return this.exclusive(async () => {
      const raw = await this.store.load(); if (raw === '') return resultOf('NO_PROGRESS');
      const state = intentOf(raw);
      if (state.phase === 'REVOKED') return resultOf('OK', state);
      const target = state.pairId || state.expectedPairId || '';
      if (target === '' && state.role !== 'CREATOR') stop('RECOVERY_REQUIRED');
      const reply = await this.invoke(raw, state, target === '' ? 'cleanupCreate' : 'unpair',
        [target === '' ? state.flowId : target], true);
      if (reply.code !== 'SESSION_REVOKED' && !(reply.code === 'OK' && reply.status === 'REVOKED')) this.rejected(reply);
      return this.revoked(raw, state);
    }, true);
  }
  private async revoked(raw: string, state: SecurePairingIntent): Promise<SecurePairingResult> {
    const next = intentOf(raw); next.phase = 'REVOKED'; next.inviteCode = ''; next.sealedProof = ''; next.bootstrapOffer = '';
    this.diagnosticStage = 'store.write';
    if (!await this.store.revoke(raw, JSON.stringify(next))) stop('SESSION_CHANGED');
    try { await this.keys.dropProof(state.authUid, state.flowId); } catch { /* Retry cleanup independently of cloud authorization. */ }
    if (state.pairId !== '') {
      try { await this.keys.drop(state.pairId); } catch { /* Revoked session cannot read or submit with this unused alias. */ }
    }
    return resultOf('OK', next);
  }
}
