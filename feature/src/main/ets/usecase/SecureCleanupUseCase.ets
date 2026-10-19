import { PlanCloudPort, PlanIdentityPort } from './SecureSharedPlanGateway';

export interface SecureCleanupRecord { flowId: string; authUid: string; pairId: string; status: string; }
export interface SecureCleanupStore {
  list(): Promise<SecureCleanupRecord[]>;
  current(record: SecureCleanupRecord): Promise<boolean>;
  finish(record: SecureCleanupRecord, status: string): Promise<void>;
  drop(record: SecureCleanupRecord): Promise<void>;
}
interface CleanupReply { code: string; status?: string; pairId?: string; }

/** Cleanup is not account creation, invitation recovery or a claim that NOT_FOUND means deleted. */
export class SecureCleanupUseCase {
  private identity: PlanIdentityPort;
  private cloud: PlanCloudPort;
  private store: SecureCleanupStore;
  private enabled: () => boolean;
  private busy: boolean = false;
  private cursor: number = 0;
  constructor(identity: PlanIdentityPort, cloud: PlanCloudPort, store: SecureCleanupStore, enabled: () => boolean) {
    this.identity = identity; this.cloud = cloud; this.store = store; this.enabled = enabled;
  }
  async clearLocalKeys(): Promise<void> {
    let failed = false;
    for (const row of await this.store.list()) {
      try {
        if (await this.store.current(row)) {
          await this.store.drop(row);
          if (row.status === 'LOCAL_KEYS') await this.store.finish(row, '');
        }
      } catch { failed = true; }
    }
    if (failed) throw new Error('Local cleanup remains');
  }
  async retry(): Promise<string> {
    if (!this.enabled()) return 'FEATURE_DISABLED';
    if (this.busy) return 'BUSY';
    this.busy = true;
    try {
      for (const row of await this.store.list()) {
        if (row.status === 'LOCAL_KEYS' && await this.store.current(row)) {
          await this.store.drop(row); await this.store.finish(row, '');
        }
      }
      const records = await this.store.list();
      const eligible = records.filter(row => (row.status === 'WAITING' && /^sp-[a-f0-9]{32}$/.test(row.pairId))
        || (row.status === 'UNRESOLVED_CREATE' && row.pairId === '' && /^[A-Za-z0-9_-]{1,128}$/.test(row.flowId)));
      const offset = eligible.length === 0 ? 0 : this.cursor % eligible.length;
      const waiting = eligible.slice(offset).concat(eligible.slice(0, offset)).slice(0, 2);
      this.cursor = offset + waiting.length;
      for (const row of waiting) {
        try {
          if (!this.enabled() || !await this.store.current(row)) continue;
          const identity = await this.identity.credential(false);
          if (identity.uid !== row.authUid || !this.enabled() || !await this.store.current(row)) continue;
          const unknownCreate = row.status === 'UNRESOLVED_CREATE';
          const raw = await this.cloud.invoke(unknownCreate ? 'cleanupCreate' : 'unpair', identity.accessToken,
            [unknownCreate ? row.flowId : row.pairId]);
          if (raw.length > 8192 || !await this.store.current(row)) continue;
          const result = JSON.parse(raw) as CleanupReply;
          if (result === null || typeof result.code !== 'string') continue;
          if (result.code === 'OK' && result.status === 'REVOKED') {
            if (unknownCreate && (typeof result.pairId !== 'string' || !/^sp-[a-f0-9]{32}$/.test(result.pairId))) continue;
            // Keys first: if local cleanup fails, retain the row and repeat the idempotent cloud deletion.
            await this.store.drop(row);
            await this.store.finish(row, '');
          } else if (['FORBIDDEN', 'NOT_FOUND', 'BAD_REQUEST', 'CLEANUP_REQUIRED'].includes(result.code)) {
            await this.store.finish(row, 'REVIEW');
          }
        } catch { /* Keep the exact identifiers; no automatic sign-in and no invented deletion verdict. */ }
      }
      return (await this.store.list()).length === 0 ? 'OK' : 'CLEANUP_REMAINS';
    } finally { this.busy = false; }
  }
}
