import { Db } from '../db/Db';
import { ScheduleRepo } from './ScheduleRepo';
import { SharedPlanRepo, SharedPlanSession } from './SharedPlanRepo';

interface FlowIdentity { flowId: string; pairId: string; actorId: string; phase: string; authUid?: string; }
export interface SecureCleanupRow { flowId: string; authUid: string; pairId: string; status: string; }
const FENCE = 'EXISTS (SELECT 1 FROM shared_pairing_setup WHERE id=1 AND data_json=?)';

function flowOf(raw: string): FlowIdentity {
  if (raw.length === 0 || raw.length > 8192) throw new Error('Invalid pairing progress');
  const flow = JSON.parse(raw) as FlowIdentity;
  if (flow === null || !/^[A-Za-z0-9_-]{1,128}$/.test(flow.flowId)
    || typeof flow.pairId !== 'string' || (flow.pairId !== '' && !/^sp-[a-f0-9]{32}$/.test(flow.pairId))
    || typeof flow.actorId !== 'string' || !['CREATING', 'JOINING', 'WAITING', 'PENDING_CONFIRM', 'ACTIVE', 'REVOKED'].includes(flow.phase)) {
    throw new Error('Invalid pairing progress');
  }
  return flow;
}

/** Persistent CAS, including atomic secure-session activation. Tokens and raw proofs are never stored here. */
export class SecurePairingRepo {
  private static async track(raw: string): Promise<void> {
    const flow = flowOf(raw);
    if (flow.phase === 'REVOKED') {
      await Db.get().executeSql('UPDATE shared_pairing_cleanup SET status=\'LOCAL_KEYS\' WHERE flow_id=? AND status=\'LIVE\' AND ' + FENCE,
        [flow.flowId, raw]);
      return;
    }
    const uid = typeof flow.authUid === 'string' && flow.authUid.length <= 256 ? flow.authUid : '';
    await Db.get().executeSql(`INSERT INTO shared_pairing_cleanup(flow_id,auth_uid,pair_id,status)
      SELECT ?,?,?,'LIVE' WHERE ` + FENCE + ` ON CONFLICT(flow_id) DO UPDATE SET
      auth_uid=excluded.auth_uid,pair_id=excluded.pair_id WHERE shared_pairing_cleanup.status='LIVE'`,
      [flow.flowId, uid, flow.pairId, raw]);
  }
  static async load(): Promise<string> {
    try {
      const rs = await Db.get().querySql('SELECT data_json FROM shared_pairing_setup WHERE id=1');
      try { return rs.goToNextRow() ? rs.getString(rs.getColumnIndex('data_json')) : ''; }
      finally { try { rs.close(); } catch (error) { throw error as Error; } }
    } catch (error) { throw error as Error; }
  }
  static async save(expected: string, next: string): Promise<boolean> {
    const flow = flowOf(next);
    await ScheduleRepo.runInTransaction(async () => {
      if (expected === '') {
        await Db.get().executeSql(`INSERT OR IGNORE INTO shared_pairing_setup(id,flow_id,data_json)
          SELECT 1,?,? WHERE NOT EXISTS (SELECT 1 FROM shared_plan_session)`, [flow.flowId, next]);
      } else {
        flowOf(expected);
        await Db.get().executeSql('UPDATE shared_pairing_setup SET flow_id=?,data_json=? WHERE id=1 AND data_json=?',
          [flow.flowId, next, expected]);
      }
      await SecurePairingRepo.track(next);
    });
    return await SecurePairingRepo.load() === next;
  }
  static async activate(expected: string, next: string, session: SharedPlanSession): Promise<boolean> {
    const before = flowOf(expected); const flow = flowOf(next);
    if (before.flowId !== flow.flowId || session.generation !== flow.flowId || session.pairId !== flow.pairId
      || session.actorId !== flow.actorId || flow.phase !== 'ACTIVE' || !/^sp-[a-f0-9]{32}$/.test(session.pairId)
      || !/^m-[a-f0-9]{64}$/.test(session.actorId)) throw new Error('Invalid secure activation');
    await ScheduleRepo.runInTransaction(async () => {
      // Never replace another live secure connection, even if a corrupted intent tries to do so.
      await Db.get().executeSql(`INSERT INTO shared_plan_session(id,pair_id,actor_id,generation)
        SELECT 1,?,?,? WHERE ` + FENCE + ` ON CONFLICT(id) DO UPDATE SET
        pair_id=excluded.pair_id,actor_id=excluded.actor_id,generation=excluded.generation
        WHERE shared_plan_session.pair_id=excluded.pair_id AND shared_plan_session.actor_id=excluded.actor_id
          AND shared_plan_session.generation=excluded.generation`,
        [session.pairId, session.actorId, session.generation, expected]);
      await Db.get().executeSql(`UPDATE shared_pairing_setup SET data_json=? WHERE id=1 AND data_json=?
        AND EXISTS (SELECT 1 FROM shared_plan_session WHERE pair_id=? AND actor_id=? AND generation=?)`,
        [next, expected, session.pairId, session.actorId, session.generation]);
      await SecurePairingRepo.track(next);
    });
    return await SecurePairingRepo.load() === next && await SharedPlanRepo.isCurrent(session);
  }
  static async revoke(expected: string, next: string): Promise<boolean> {
    const before = flowOf(expected); const after = flowOf(next);
    if (after.flowId !== before.flowId || after.pairId !== before.pairId || after.actorId !== before.actorId
      || after.phase !== 'REVOKED') throw new Error('Invalid secure revocation');
    await ScheduleRepo.runInTransaction(async () => {
      await Db.get().executeSql(`UPDATE plan SET status='CANCELLED', calendar_state=CASE
        WHEN COALESCE(my_event_id,'')<>'' OR reminder_id>=0 THEN 'CLEANUP_PENDING' ELSE calendar_state END
        WHERE id IN (SELECT local_id FROM shared_plan_source WHERE pair_id=? AND actor_id=?) AND ` + FENCE,
        [before.pairId, before.actorId, expected]);
      for (const table of ['shared_plan_cache', 'shared_plan_outgoing', 'shared_plan_wire', 'shared_plan_cursor', 'shared_plan_archive_vote']) {
        await Db.get().executeSql('DELETE FROM ' + table + ' WHERE pair_id=? AND ' + FENCE, [before.pairId, expected]);
      }
      await Db.get().executeSql('DELETE FROM shared_plan_session WHERE pair_id=? AND actor_id=? AND generation=? AND ' + FENCE,
        [before.pairId, before.actorId, before.flowId, expected]);
      await Db.get().executeSql('UPDATE shared_pairing_setup SET data_json=? WHERE id=1 AND data_json=?', [next, expected]);
      await SecurePairingRepo.track(next);
    });
    return await SecurePairingRepo.load() === next;
  }
  static async cleanupRecords(): Promise<SecureCleanupRow[]> {
    try {
    const rs = await Db.get().querySql(`SELECT flow_id,auth_uid,pair_id,status FROM shared_pairing_cleanup
      WHERE status<>'LIVE' ORDER BY flow_id`);
    try {
      const rows: SecureCleanupRow[] = [];
      while (rs.goToNextRow()) rows.push({ flowId: rs.getString(rs.getColumnIndex('flow_id')),
        authUid: rs.getString(rs.getColumnIndex('auth_uid')), pairId: rs.getString(rs.getColumnIndex('pair_id')),
        status: rs.getString(rs.getColumnIndex('status')) });
      return rows;
    } finally { try { rs.close(); } catch (error) { throw error as Error; } }
    } catch (error) { throw error as Error; }
  }
  static async finishCleanup(row: SecureCleanupRow, status: string): Promise<void> {
    if (status !== '' && status !== 'REVIEW') throw new Error('Invalid cleanup verdict');
    const args: string[] = [row.flowId, row.authUid, row.pairId, row.status];
    await ScheduleRepo.runInTransaction(async () => {
      if (status === '') await Db.get().executeSql(`DELETE FROM shared_pairing_cleanup
        WHERE flow_id=? AND auth_uid=? AND pair_id=? AND status=? AND status<>'LIVE'`, args);
      else await Db.get().executeSql(`UPDATE shared_pairing_cleanup SET status=?
        WHERE flow_id=? AND auth_uid=? AND pair_id=? AND status=? AND status<>'LIVE'`, [status].concat(args));
    });
  }
}
