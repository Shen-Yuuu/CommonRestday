/** 在内存 SQLite 执行编译后的生产迁移；不连接设备、不读写用户数据库。 */
const assert = require('node:assert/strict');
const { DatabaseSync } = require('node:sqlite');
const { MigrationRunner, OWNER_SCOPED_TABLES, OWNER_KEY_CLAUSE, SCHEMA_VERSION,
  V2_ADDITIONS, ownerScopedDdlList } = require('./out/data/main/ets/db/MigrationRunner.js');

class SqlMigrationDb {
  constructor() {
    this.db = new DatabaseSync(':memory:');
    this.fail = '';
    this.statements = [];
    this.db.exec('CREATE TABLE sync_meta(k TEXT PRIMARY KEY, v TEXT)');
  }
  async execute(sql) {
    if (this.fail && sql.includes(this.fail)) throw new Error('injected migration failure');
    this.statements.push(sql);
    this.db.exec(sql);
  }
  async canSelect(sql) { try { this.db.prepare(sql).all(); return true; } catch { return false; } }
  async tableDDL(name) {
    return this.db.prepare('SELECT sql FROM sqlite_master WHERE type=? AND name=?').get('table', name)?.sql ?? '';
  }
  async getMeta(key) { return this.db.prepare('SELECT v FROM sync_meta WHERE k=?').get(key)?.v ?? ''; }
  async setMeta(key, val) { this.db.prepare('INSERT OR REPLACE INTO sync_meta(k,v) VALUES(?,?)').run(key, val); }
  begin() { this.db.exec('BEGIN'); }
  commit() { this.db.exec('COMMIT'); }
  rollback() { this.db.exec('ROLLBACK'); }
  close() { this.db.close(); }
}

function legacy(version) {
  const db = new SqlMigrationDb();
  db.db.exec('CREATE TABLE plan(id TEXT PRIMARY KEY); CREATE TABLE computed_window(start_min INTEGER)');
  if (version >= 3) {
    for (const col of V2_ADDITIONS) db.db.exec(col.ddl);
  }
  for (const t of OWNER_SCOPED_TABLES) {
    const columns = version < 3 ? t.columns.replace('id TEXT NOT NULL', 'id TEXT PRIMARY KEY') : t.columns;
    db.db.exec('CREATE TABLE ' + t.table + ' (' + columns
      + (version >= 3 ? ', ' + OWNER_KEY_CLAUSE : '') + ')');
  }
  db.db.prepare('INSERT INTO cycle_template(id,owner,name,seq,anchor_day) VALUES(?,?,?,?,?)')
    .run('main', 'ME', '旧循环', 'A,,B', 20724);
  db.db.prepare('INSERT INTO cycle_template(id,owner,name,seq,anchor_day) VALUES(?,?,?,?,?)')
    .run('peer-main', 'PARTNER', 'TA旧循环', 'X', 20725);
  db.db.prepare('INSERT INTO sync_meta(k,v) VALUES(?,?)').run('schema_version', String(version));
  return db;
}

async function main() {
  for (const version of [1, 3]) {
    const db = legacy(version);
    try {
      await MigrationRunner.upgrade(db);
      const rows = db.db.prepare('SELECT owner,name,seq,anchor_day,weekdays_mask FROM cycle_template ORDER BY owner').all();
      assert.equal(rows.length, 2);
      assert.deepEqual({ ...rows[0] }, { owner: 'ME', name: '旧循环', seq: 'A,,B', anchor_day: 20724, weekdays_mask: 127 });
      assert.deepEqual({ ...rows[1] }, { owner: 'PARTNER', name: 'TA旧循环', seq: 'X', anchor_day: 20725, weekdays_mask: 127 });
      assert.equal(await db.getMeta('schema_version'), String(SCHEMA_VERSION));
      const count = db.statements.length;
      await MigrationRunner.upgrade(db);
      assert.equal(db.statements.length, count);
    } finally { db.close(); }
  }
  const interrupted = legacy(1);
  try {
    interrupted.fail = 'ADD COLUMN weekdays_mask';
    await assert.rejects(() => MigrationRunner.upgrade(interrupted));
    assert.equal(await interrupted.getMeta('schema_version'), '1');
    assert.equal(await interrupted.canSelect('SELECT calendar_state FROM plan LIMIT 0'), false);
    assert.equal(interrupted.db.prepare('SELECT name FROM cycle_template WHERE owner=?').get('ME').name, '旧循环');
    interrupted.fail = '';
    await MigrationRunner.upgrade(interrupted);
    assert.equal(await interrupted.canSelect('SELECT weekdays_mask FROM cycle_template LIMIT 0'), true);
  } finally { interrupted.close(); }
  const fresh = new SqlMigrationDb();
  try {
    for (const sql of ownerScopedDdlList()) fresh.db.exec(sql);
    fresh.db.prepare('INSERT INTO cycle_template(id,owner,name,seq,anchor_day) VALUES(?,?,?,?,?)')
      .run('main', 'ME', '默认模板', 'A', 20724);
    assert.equal(fresh.db.prepare('SELECT weekdays_mask FROM cycle_template').get().weekdays_mask, 127);
  } finally { fresh.close(); }
  console.log('cycle-storage-sql: PASS（内存SQLite执行v1/v3→v4、保留两侧行、回滚重试、新装默认值）');
}
main().catch(error => { console.error(error.message); process.exitCode = 1; });
