import { Db } from '../db/Db';
import { relationalStore } from '@kit.ArkData';
import { ScheduleRepo } from './ScheduleRepo';

export interface SharedPlanSession {
  pairId: string;
  actorId: string;
  generation: string;
}

export interface SharedStoredActivity {
  id: string;
  title: string;
  kind: string;
  start: number;
  end: number;
  contentRevision: number;
}

export interface SharedStoredRow {
  pairId: string;
  planId: string;
  stateVersion: number;
  recordJson: string;
  terminal: boolean;
  activity: SharedStoredActivity | null;
}

export interface SharedOutgoingRequest {
  requestId: string;
  commandJson: string;
}

const FENCE = `EXISTS (SELECT 1 FROM shared_plan_session WHERE id=1
  AND pair_id=? AND actor_id=? AND generation=?)`;
const CANCEL_SOURCE = `UPDATE plan SET status='CANCELLED',
  calendar_state=CASE WHEN COALESCE(my_event_id,'')<>'' OR reminder_id>=0
    THEN 'CLEANUP_PENDING' ELSE calendar_state END
  WHERE id IN (SELECT local_id FROM shared_plan_source)`;

function validId(value: string): boolean {
  return /^[A-Za-z0-9_-]{1,128}$/.test(value);
}

function validSession(session: SharedPlanSession): boolean {
  return validId(session.pairId) && validId(session.actorId) && validId(session.generation);
}

function fenceValues(session: SharedPlanSession): string[] {
  return [session.pairId, session.actorId, session.generation];
}

/** SQL fences every write. No reads through a pooled connection inside a write transaction. */
export class SharedPlanRepo {
  static async localActivityId(session: SharedPlanSession, planId: string): Promise<string> {
    try {
    if (!validSession(session) || !validId(planId)) return '';
    const rs = await Db.get().querySql(`SELECT local_id FROM shared_plan_source
      WHERE pair_id=? AND actor_id=? AND plan_id=? AND ` + FENCE,
      [session.pairId, session.actorId, planId].concat(fenceValues(session)));
    try {
      const id = rs.goToNextRow() ? rs.getString(rs.getColumnIndex('local_id')) : '';
      return id === 'shared:' + session.pairId + ':' + planId ? id : '';
    } finally { SharedPlanRepo.close(rs); }
    } catch (error) { throw error as Error; }
  }
  private static close(rs: relationalStore.ResultSet): void {
    try { rs.close(); } catch (e) { throw e as Error; }
  }
  /** Called only AFTER a verified secure binding, NEVER by the legacy pairing flow. */
  static async activate(session: SharedPlanSession): Promise<void> {
    if (!validSession(session)) throw new Error('Invalid secure session');
    await ScheduleRepo.runInTransaction(async () => {
      await Db.get().executeSql(CANCEL_SOURCE + ` AND id IN
        (SELECT local_id FROM shared_plan_source WHERE pair_id<>? OR actor_id<>?)`,
        [session.pairId, session.actorId]);
      await Db.get().executeSql(`DELETE FROM shared_plan_cache WHERE pair_id<>? OR NOT EXISTS
        (SELECT 1 FROM shared_plan_session WHERE actor_id=?)`, [session.pairId, session.actorId]);
      await Db.get().executeSql(`INSERT OR REPLACE INTO shared_plan_session
        (id,pair_id,actor_id,generation) VALUES(1,?,?,?)`, fenceValues(session));
      await Db.get().executeSql(`DELETE FROM shared_plan_outgoing WHERE pair_id<>?
        OR actor_id<>? OR generation<>?`, fenceValues(session));
      await Db.get().executeSql(`DELETE FROM shared_plan_wire WHERE pair_id<>?
        OR actor_id<>? OR generation<>?`, fenceValues(session));
      await Db.get().executeSql('DELETE FROM shared_plan_cache WHERE pair_id<>?', [session.pairId]);
      for (const table of ['shared_plan_cursor', 'shared_plan_archive_vote']) {
        await Db.get().executeSql('DELETE FROM ' + table + ' WHERE pair_id<>? OR actor_id<>? OR generation<>?', fenceValues(session));
      }
    });
  }

  static async isCurrent(session: SharedPlanSession): Promise<boolean> {
    if (!validSession(session)) return false;
    try {
      const rs = await Db.get().querySql('SELECT 1 AS alive WHERE ' + FENCE, fenceValues(session));
      try { return rs.goToNextRow(); } finally { SharedPlanRepo.close(rs); }
    } catch (e) { throw e as Error; }
  }

  static async records(session: SharedPlanSession): Promise<string[]> {
    if (!validSession(session)) return [];
    const rows: string[] = [];
    try {
      const rs = await Db.get().querySql(`SELECT record_json FROM shared_plan_cache WHERE pair_id=? AND ` + FENCE,
        [session.pairId].concat(fenceValues(session)));
      try {
        while (rs.goToNextRow()) rows.push(rs.getString(rs.getColumnIndex('record_json')));
      } finally { SharedPlanRepo.close(rs); }
    } catch (e) { throw e as Error; }
    return rows;
  }

  static async cursor(session: SharedPlanSession): Promise<number> {
    try {
    if (!validSession(session)) throw new Error('Invalid cursor session');
    const rs = await Db.get().querySql('SELECT cursor FROM shared_plan_cursor WHERE pair_id=? AND actor_id=? AND generation=? AND ' + FENCE,
      fenceValues(session).concat(fenceValues(session)));
    try {
      const value = rs.goToNextRow() ? rs.getLong(rs.getColumnIndex('cursor')) : 0;
      if (!Number.isSafeInteger(value) || value < 0) throw new Error('Invalid sync cursor');
      return value;
    } finally { SharedPlanRepo.close(rs); }
    } catch (error) { throw error as Error; }
  }
  /** Called only after a validated page is durably applied; SQL fence prevents generation crossover. */
  static async saveCursor(session: SharedPlanSession, cursor: number): Promise<boolean> {
    try {
    if (!validSession(session) || !Number.isSafeInteger(cursor) || cursor < 0) return false;
    const args: (string | number)[] = fenceValues(session); args.push(cursor);
    await Db.get().executeSql(`INSERT INTO shared_plan_cursor(pair_id,actor_id,generation,cursor)
      SELECT ?,?,?,? WHERE ` + FENCE + ` ON CONFLICT(pair_id,actor_id,generation) DO UPDATE SET cursor=excluded.cursor
      WHERE excluded.cursor>=shared_plan_cursor.cursor`, args.concat(fenceValues(session)));
    return await SharedPlanRepo.isCurrent(session) && await SharedPlanRepo.cursor(session) === cursor;
    } catch (error) { throw error as Error; }
  }
  static async voted(session: SharedPlanSession): Promise<string[]> {
    try {
    const rs = await Db.get().querySql('SELECT plan_id,state_version FROM shared_plan_archive_vote WHERE pair_id=? AND actor_id=? AND generation=? AND ' + FENCE,
      fenceValues(session).concat(fenceValues(session)));
    const rows: string[] = [];
    try {
      while (rs.goToNextRow()) rows.push(rs.getString(rs.getColumnIndex('plan_id')) + ':' + rs.getLong(rs.getColumnIndex('state_version')));
      return rows;
    } finally { SharedPlanRepo.close(rs); }
    } catch (error) { throw error as Error; }
  }
  static async markVote(session: SharedPlanSession, planId: string, version: number): Promise<void> {
    try {
    if (!validSession(session) || !validId(planId) || !Number.isSafeInteger(version) || version < 1) throw new Error('Invalid archive vote');
    const args: (string | number)[] = fenceValues(session); args.push(planId, version);
    await Db.get().executeSql(`INSERT INTO shared_plan_archive_vote(pair_id,actor_id,generation,plan_id,state_version)
      SELECT ?,?,?,?,? WHERE ` + FENCE + ` ON CONFLICT(pair_id,actor_id,generation,plan_id) DO UPDATE SET state_version=excluded.state_version
      WHERE excluded.state_version>=shared_plan_archive_vote.state_version`, args.concat(fenceValues(session)));
    } catch (error) { throw error as Error; }
  }

  /** Decrypted validated authoritative rows only. This method never writes to the system calendar. */
  static async apply(session: SharedPlanSession, rows: SharedStoredRow[]): Promise<boolean> {
    if (!await SharedPlanRepo.isCurrent(session)) return false;
    if (rows.length > 50) throw new Error('Shared plan batch exceeds limit');
    for (const row of rows) {
      if (row.pairId !== session.pairId || !validId(row.planId) || !Number.isSafeInteger(row.stateVersion)
        || row.stateVersion < 1 || row.recordJson.length > 32768) throw new Error('Invalid shared plan cache row');
      const activity = row.activity;
      if (activity !== null && (activity.id !== 'shared:' + row.pairId + ':' + row.planId
        || !Number.isSafeInteger(activity.start) || !Number.isSafeInteger(activity.end)
        || activity.end - activity.start < 15 || activity.start < 0 || activity.title.length === 0
        || !Number.isSafeInteger(activity.contentRevision) || activity.contentRevision < 1)) {
        throw new Error('Invalid shared plan projection');
      }
    }
    await ScheduleRepo.runInTransaction(async () => {
      for (const row of rows) {
        const values: (string | number)[] = [row.pairId, row.planId, row.stateVersion, row.recordJson, row.terminal ? 1 : 0];
        await Db.get().executeSql(`INSERT INTO shared_plan_cache(pair_id,plan_id,state_version,record_json,terminal)
          SELECT ?,?,?,?,? WHERE ` + FENCE + ` ON CONFLICT(pair_id,plan_id) DO UPDATE SET
          state_version=excluded.state_version,record_json=excluded.record_json,terminal=excluded.terminal
          WHERE shared_plan_cache.terminal=0 AND excluded.state_version>shared_plan_cache.state_version`,
          values.concat(fenceValues(session)));
        const guard = FENCE + ` AND EXISTS (SELECT 1 FROM shared_plan_cache
          WHERE pair_id=? AND plan_id=? AND state_version=? AND record_json=?)`;
        const guards: (string | number)[] = fenceValues(session);
        guards.push(row.pairId, row.planId, row.stateVersion, row.recordJson);
        const activity = row.activity;
        if (activity === null) {
          await Db.get().executeSql(CANCEL_SOURCE + ` AND id IN
            (SELECT local_id FROM shared_plan_source WHERE pair_id=? AND plan_id=?) AND ` + guard,
            ([row.pairId, row.planId] as (string | number)[]).concat(guards));
        } else {
          const projection: (string | number)[] = [activity.id, activity.title, activity.kind, activity.start,
            activity.end, Date.now()];
          await Db.get().executeSql(`INSERT INTO plan(id,title,kind,start_min,end_min,status,created_by,
            window_ref,conflict_hint,my_event_id,reminder_id,updated_at,calendar_state,sync_state)
            SELECT ?,?,?,?,?,'OK','SHARED','','','',-1,?,'NOT_REQUESTED','SYNCED' WHERE ` + guard + `
            ON CONFLICT(id) DO UPDATE SET title=excluded.title,kind=excluded.kind,start_min=excluded.start_min,
            end_min=excluded.end_min,status='OK',updated_at=excluded.updated_at,sync_state='SYNCED',
            calendar_state=CASE WHEN (plan.start_min<>excluded.start_min OR plan.end_min<>excluded.end_min
              OR plan.title<>excluded.title) AND (COALESCE(plan.my_event_id,'')<>'' OR plan.reminder_id>=0)
              THEN 'CLEANUP_PENDING' ELSE plan.calendar_state END
            WHERE plan.start_min<>excluded.start_min OR plan.end_min<>excluded.end_min
              OR plan.title<>excluded.title OR plan.kind<>excluded.kind OR plan.status='CANCELLED'`,
            projection.concat(guards));
          const source: (string | number)[] = [activity.id, row.pairId, row.planId, session.actorId, activity.contentRevision];
          await Db.get().executeSql(`INSERT INTO shared_plan_source(local_id,pair_id,plan_id,actor_id,content_revision)
            SELECT ?,?,?,?,? WHERE ` + guard + ` ON CONFLICT(local_id) DO UPDATE SET
            content_revision=excluded.content_revision,actor_id=excluded.actor_id`, source.concat(guards));
        }
      }
    });
    return SharedPlanRepo.isCurrent(session);
  }

  static async enqueue(session: SharedPlanSession, requestId: string, commandJson: string): Promise<void> {
    if (!validSession(session) || !validId(requestId) || commandJson.length > 32768) throw new Error('Invalid shared request');
    const args: (string | number)[] = [session.pairId, session.actorId, session.generation, requestId, commandJson, Date.now()];
    try {
      await Db.get().executeSql(`INSERT OR IGNORE INTO shared_plan_outgoing
        (pair_id,actor_id,generation,request_id,command_json,created_at) SELECT ?,?,?,?,?,? WHERE ` + FENCE,
        args.concat(fenceValues(session)));
    } catch (e) { throw e as Error; }
    const saved = (await SharedPlanRepo.pending(session)).find((row: SharedOutgoingRequest) => row.requestId === requestId);
    if (saved === undefined || saved.commandJson !== commandJson) throw new Error('Shared request identity or session changed');
  }

  static async pending(session: SharedPlanSession): Promise<SharedOutgoingRequest[]> {
    if (!validSession(session)) return [];
    const rows: SharedOutgoingRequest[] = [];
    try {
      const rs = await Db.get().querySql(`SELECT request_id,command_json FROM shared_plan_outgoing
        WHERE pair_id=? AND actor_id=? AND generation=? AND ` + FENCE + ' ORDER BY created_at,request_id',
        fenceValues(session).concat(fenceValues(session)));
      try {
        while (rs.goToNextRow()) rows.push({ requestId: rs.getString(rs.getColumnIndex('request_id')),
          commandJson: rs.getString(rs.getColumnIndex('command_json')) });
      } finally { SharedPlanRepo.close(rs); }
    } catch (e) { throw e as Error; }
    return rows;
  }

  static async finishRequest(session: SharedPlanSession, requestId: string): Promise<void> {
    await ScheduleRepo.runInTransaction(async () => {
      await Db.get().executeSql(`DELETE FROM shared_plan_outgoing WHERE pair_id=? AND actor_id=?
        AND generation=? AND request_id=? AND ` + FENCE,
        fenceValues(session).concat([requestId]).concat(fenceValues(session)));
      await Db.get().executeSql(`DELETE FROM shared_plan_wire WHERE pair_id=? AND actor_id=?
        AND generation=? AND request_id=? AND ` + FENCE,
        fenceValues(session).concat([requestId]).concat(fenceValues(session)));
    });
  }

  /** Persist the ciphertext before transmission; retries must reuse its original nonce. */
  static async wire(session: SharedPlanSession, requestId: string, draftJson: string): Promise<string> {
    if (!validSession(session) || !validId(requestId)) throw new Error('Invalid shared wire identity');
    try {
      const rs = await Db.get().querySql(`SELECT wire_json,draft_json FROM shared_plan_wire
        WHERE pair_id=? AND actor_id=? AND generation=? AND request_id=? AND ` + FENCE,
        fenceValues(session).concat([requestId]).concat(fenceValues(session)));
      try {
        if (!rs.goToNextRow()) return '';
        if (rs.getString(rs.getColumnIndex('draft_json')) !== draftJson) throw new Error('Shared wire draft changed');
        return rs.getString(rs.getColumnIndex('wire_json'));
      } finally { SharedPlanRepo.close(rs); }
    } catch (e) { throw e as Error; }
  }

  static async saveWire(session: SharedPlanSession, requestId: string, draftJson: string, wireJson: string): Promise<string> {
    if (!validSession(session) || !validId(requestId) || draftJson.length > 32768
      || wireJson.length === 0 || wireJson.length > 20000) throw new Error('Invalid shared wire request');
    const args: string[] = fenceValues(session).concat([requestId, draftJson, wireJson]);
    try {
      await Db.get().executeSql(`INSERT OR IGNORE INTO shared_plan_wire
        (pair_id,actor_id,generation,request_id,draft_json,wire_json) SELECT ?,?,?,?,?,? WHERE ` + FENCE + `
        AND EXISTS (SELECT 1 FROM shared_plan_outgoing WHERE pair_id=? AND actor_id=?
          AND generation=? AND request_id=? AND command_json=?)`,
        args.concat(fenceValues(session)).concat(fenceValues(session)).concat([requestId, draftJson]));
    } catch (e) { throw e as Error; }
    const saved = await SharedPlanRepo.wire(session, requestId, draftJson);
    if (saved === '') throw new Error('Shared wire session or original request changed');
    return saved;
  }

  static async session(): Promise<SharedPlanSession | null> {
    try {
      const rs = await Db.get().querySql('SELECT pair_id,actor_id,generation FROM shared_plan_session WHERE id=1');
      try {
        if (!rs.goToNextRow()) return null;
        const session: SharedPlanSession = { pairId: rs.getString(rs.getColumnIndex('pair_id')),
          actorId: rs.getString(rs.getColumnIndex('actor_id')), generation: rs.getString(rs.getColumnIndex('generation')) };
        return validSession(session) ? session : null;
      } finally { SharedPlanRepo.close(rs); }
    } catch (e) { throw e as Error; }
  }

  static async invalidate(): Promise<void> {
    await ScheduleRepo.runInTransaction(async () => {
      await Db.get().executeSql(CANCEL_SOURCE);
      await Db.get().executeSql('DELETE FROM shared_plan_session');
      await Db.get().executeSql('DELETE FROM shared_plan_cache');
      await Db.get().executeSql('DELETE FROM shared_plan_outgoing');
      await Db.get().executeSql('DELETE FROM shared_plan_wire');
      await Db.get().executeSql('DELETE FROM shared_plan_cursor');
      await Db.get().executeSql('DELETE FROM shared_plan_archive_vote');
    });
  }
}
