/** Independent local protocol storage; never infer cloud membership from the old pairId. */
export const SHARED_PLAN_DDL: string[] = [
  `CREATE TABLE IF NOT EXISTS shared_plan_cursor (
    pair_id TEXT NOT NULL, actor_id TEXT NOT NULL, generation TEXT NOT NULL, cursor INTEGER NOT NULL DEFAULT 0,
    PRIMARY KEY(pair_id,actor_id,generation))`,
  `CREATE TABLE IF NOT EXISTS shared_plan_archive_vote (
    pair_id TEXT NOT NULL, actor_id TEXT NOT NULL, generation TEXT NOT NULL, plan_id TEXT NOT NULL, state_version INTEGER NOT NULL,
    PRIMARY KEY(pair_id,actor_id,generation,plan_id))`,
  `CREATE TABLE IF NOT EXISTS shared_plan_session (
    id INTEGER PRIMARY KEY CHECK(id=1), pair_id TEXT NOT NULL, actor_id TEXT NOT NULL, generation TEXT NOT NULL)`,
  `CREATE TABLE IF NOT EXISTS shared_plan_cache (
    pair_id TEXT NOT NULL, plan_id TEXT NOT NULL, state_version INTEGER NOT NULL,
    record_json TEXT NOT NULL, terminal INTEGER NOT NULL DEFAULT 0,
    PRIMARY KEY(pair_id, plan_id))`,
  `CREATE TABLE IF NOT EXISTS shared_plan_outgoing (
    pair_id TEXT NOT NULL, actor_id TEXT NOT NULL, generation TEXT NOT NULL,
    request_id TEXT NOT NULL, command_json TEXT NOT NULL, created_at INTEGER NOT NULL,
    PRIMARY KEY(pair_id, actor_id, request_id))`,
  `CREATE TABLE IF NOT EXISTS shared_plan_source (
    local_id TEXT PRIMARY KEY, pair_id TEXT NOT NULL, plan_id TEXT NOT NULL,
    actor_id TEXT NOT NULL, content_revision INTEGER NOT NULL,
    UNIQUE(pair_id, plan_id))`,
  `CREATE TABLE IF NOT EXISTS shared_plan_wire (
    pair_id TEXT NOT NULL, actor_id TEXT NOT NULL, generation TEXT NOT NULL,
    request_id TEXT NOT NULL, draft_json TEXT NOT NULL, wire_json TEXT NOT NULL,
    PRIMARY KEY(pair_id, actor_id, generation, request_id))`,
  `CREATE TABLE IF NOT EXISTS shared_pairing_setup (
    id INTEGER PRIMARY KEY CHECK(id=1), flow_id TEXT NOT NULL, data_json TEXT NOT NULL)`,
  `CREATE TABLE IF NOT EXISTS shared_pairing_cleanup (
    flow_id TEXT PRIMARY KEY, auth_uid TEXT NOT NULL, pair_id TEXT NOT NULL, status TEXT NOT NULL)`
];

/** Restored authentication/device keys are not live proof; keep calendar handles for the normal cleanup. */
export const SHARED_RESTORE_SQL: string[] = [
  `UPDATE plan SET status='CANCELLED' WHERE id IN (SELECT local_id FROM shared_plan_source)`,
  `INSERT OR IGNORE INTO shared_pairing_cleanup(flow_id,auth_uid,pair_id,status)
    SELECT setup.flow_id,'',COALESCE(session.pair_id,''),'RESTORED' FROM shared_pairing_setup setup
    LEFT JOIN shared_plan_session session ON session.id=1`,
  `DELETE FROM shared_plan_session`,
  `DELETE FROM shared_plan_cache`,
  `DELETE FROM shared_plan_outgoing`,
  `DELETE FROM shared_plan_wire`,
  `DELETE FROM shared_plan_cursor`,
  `DELETE FROM shared_plan_archive_vote`,
  `DELETE FROM shared_pairing_setup`,
  `UPDATE shared_pairing_cleanup SET status='RESTORED'`
];
