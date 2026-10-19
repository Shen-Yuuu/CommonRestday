/** 装载生产 Db 适配器，覆盖延后错误及 WAL 读写连接隔离；不连接用户数据库。 */
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const os = require('node:os');
const vm = require('node:vm');
const { DatabaseSync } = require('node:sqlite');
const migration = require('./out/data/main/ets/db/MigrationRunner.js');
const tscPath = process.argv[2] || process.env.CRD_TSC
  || 'D:/local/DevEcoStudio/tools/hvigor/hvigor/node_modules/typescript/bin/tsc';
const ts = require(path.resolve(path.dirname(tscPath), '../lib/typescript.js'));
const repo = path.resolve(__dirname, '../..');
const source = fs.readFileSync(path.join(repo, 'data/src/main/ets/db/Db.ets'), 'utf8');
const compiled = ts.transpileModule(source, {
  compilerOptions: { target: ts.ScriptTarget.ES2021, module: ts.ModuleKind.CommonJS }
}).outputText + '\nexports.RdbMigration = RdbMigration;';

class DeferredResultSet {
  constructor(store, sql, args) {
    this.store = store;
    this.sql = sql;
    this.args = args;
    this.closed = false;
    this.rows = null;
    this.index = -1;
    this.statement = null;
  }
  prepare() {
    assert.equal(this.closed, false);
    if (this.store.failReadAfterCommit && this.store.commits > 0
      && this.sql === 'SELECT weekdays_mask FROM cycle_template LIMIT 0') {
      throw new Error('injected post-commit read failure');
    }
    if (!this.statement) this.statement = this.store.reader.prepare(this.sql);
    return this.statement;
  }
  get columnCount() { return this.prepare().columns().length; }
  getColumnIndex(name) { return this.prepare().columns().findIndex(c => c.name === name); }
  goToNextRow() {
    if (!this.rows) this.rows = this.prepare().all(...this.args);
    return ++this.index < this.rows.length;
  }
  value(index) {
    const cols = this.prepare().columns();
    if (index < 0 || index >= cols.length || !this.rows || !this.rows[this.index]) {
      throw new Error('Resultset is empty or column index is out of bounds.');
    }
    return this.rows[this.index][cols[index].name];
  }
  getString(index) { return String(this.value(index)); }
  isColumnNull(index) { return this.value(index) == null; }
  close() { this.closed = true; }
}

class MemoryRdbStore {
  constructor(pooled = false) {
    this.fixtureDir = pooled ? fs.mkdtempSync(path.join(os.tmpdir(), 'fortwo-rdb-regression-')) : null;
    this.fixturePath = this.fixtureDir ? path.join(this.fixtureDir, 'fixture.db') : null;
    this.db = new DatabaseSync(this.fixturePath || ':memory:');
    if (pooled) this.db.exec('PRAGMA journal_mode=WAL');
    this.reader = pooled ? new DatabaseSync(this.fixturePath) : this.db;
    if (pooled) this.reader.exec('PRAGMA query_only=ON');
    this.results = [];
    this.statements = [];
    this.fail = '';
    this.failCommit = false;
    this.failReadAfterCommit = false;
    this.inTx = false;
    this.commits = 0;
    this.rollbacks = 0;
    this.queriesDuringTx = [];
  }
  async querySql(sql, args = []) {
    if (this.inTx) this.queriesDuringTx.push(sql);
    // 不在 querySql 抛语法错误；结果集元数据才执行 prepare。
    const rs = new DeferredResultSet(this, sql, args);
    this.results.push(rs);
    return rs;
  }
  async executeSql(sql, args = []) {
    if (this.fail && sql.includes(this.fail)) throw new Error('injected migration failure');
    this.statements.push(sql);
    this.db.prepare(sql).run(...args);
  }
  beginTransaction() { this.db.exec('BEGIN'); this.inTx = true; }
  commit() {
    if (this.failCommit) throw new Error('injected commit failure');
    this.db.exec('COMMIT'); this.inTx = false; this.commits++;
  }
  rollBack() { this.rollbacks++; this.db.exec('ROLLBACK'); this.inTx = false; }
  close() {
    if (this.reader !== this.db) this.reader.close();
    this.db.close();
    if (this.fixtureDir) {
      // 只删除 mkdtemp 创建的精确夹具文件；不递归删除任何目录。
      for (const suffix of ['', '-wal', '-shm', '-journal']) {
        const file = this.fixturePath + suffix;
        assert.equal(path.dirname(file), this.fixtureDir);
        if (fs.existsSync(file)) fs.unlinkSync(file);
      }
      fs.rmdirSync(this.fixtureDir);
    }
  }
}

function production(store) {
  const module = { exports: {} };
  vm.runInNewContext(compiled, {
    module, exports: module.exports,
    require(name) {
      if (name === '@kit.ArkData') return {
        relationalStore: { SecurityLevel: { S1: 1 }, getRdbStore: async () => store }
      };
      if (name === './MigrationRunner') return migration;
      if (name === './SharedPlanSchema') return require('./out/data/main/ets/db/SharedPlanSchema.js');
      if (name === 'commons') return { Logger: { info() {}, warn() {}, error() {} } };
      throw new Error('Unexpected platform import: ' + name);
    }
  }, { filename: 'Db.production.js' });
  return module.exports;
}

function legacy(version, hasDays = false, pooled = false) {
  const store = new MemoryRdbStore(pooled);
  store.db.exec('CREATE TABLE sync_meta(k TEXT PRIMARY KEY,v TEXT);'
    + 'CREATE TABLE plan(id TEXT PRIMARY KEY); CREATE TABLE computed_window(start_min INTEGER)');
  if (version >= 3) for (const c of migration.V2_ADDITIONS) store.db.exec(c.ddl);
  for (const t of migration.OWNER_SCOPED_TABLES) {
    const columns = version < 3 ? t.columns.replace('id TEXT NOT NULL', 'id TEXT PRIMARY KEY') : t.columns;
    store.db.exec('CREATE TABLE ' + t.table + ' (' + columns
      + (t.table === 'cycle_template' && hasDays ? ', weekdays_mask INTEGER NOT NULL DEFAULT 127' : '')
      + (version >= 3 ? ', ' + migration.OWNER_KEY_CLAUSE : '') + ')');
  }
  for (const [id, owner, name, seq, anchor] of [
    ['main', 'ME', '我的旧模板', 'A,,B', 20724],
    ['peer', 'PARTNER', 'TA旧模板', 'X,Y', 20725]
  ]) store.db.prepare('INSERT INTO cycle_template(id,owner,name,seq,anchor_day) VALUES(?,?,?,?,?)')
    .run(id, owner, name, seq, anchor);
  if (hasDays) store.db.exec("UPDATE cycle_template SET weekdays_mask=31 WHERE owner='ME';"
    + "UPDATE cycle_template SET weekdays_mask=96 WHERE owner='PARTNER'");
  store.db.prepare('INSERT INTO sync_meta(k,v) VALUES(?,?)').run('schema_version', String(version));
  return store;
}

function assertRows(store, mine = 127, peer = 127) {
  const rows = store.db.prepare('SELECT owner,name,seq,anchor_day,weekdays_mask FROM cycle_template ORDER BY owner').all();
  assert.deepEqual(rows.map(r => ({ ...r })), [
    { owner: 'ME', name: '我的旧模板', seq: 'A,,B', anchor_day: 20724, weekdays_mask: mine },
    { owner: 'PARTNER', name: 'TA旧模板', seq: 'X,Y', anchor_day: 20725, weekdays_mask: peer }
  ]);
  assert.equal(store.results.every(rs => rs.closed), true, '全部探测和读取结果集必须关闭');
}

async function main() {
  const visibility = legacy(3, false, true);
  try {
    const { RdbMigration } = production(visibility);
    const adapter = new RdbMigration(visibility);
    visibility.beginTransaction();
    await visibility.executeSql('ALTER TABLE cycle_template ADD COLUMN weekdays_mask INTEGER NOT NULL DEFAULT 127');
    assert.equal(visibility.db.prepare('SELECT weekdays_mask FROM cycle_template').get().weekdays_mask, 127);
    assert.equal(await adapter.canSelect('SELECT weekdays_mask FROM cycle_template LIMIT 0'), false,
      '独立读连接看不到写事务尚未提交的补列，不能在这里断言迁移失败');
    visibility.commit();
    assert.equal(await adapter.canSelect('SELECT weekdays_mask FROM cycle_template LIMIT 0'), true);
  } finally { visibility.close(); }

  const probeStore = new MemoryRdbStore();
  try {
    probeStore.db.exec('CREATE TABLE empty_table(id INTEGER)');
    const { RdbMigration } = production(probeStore);
    const adapter = new RdbMigration(probeStore);
    assert.equal(await adapter.canSelect('SELECT missing FROM empty_table LIMIT 0'), false,
      '结果集对象不等于查询成功：缺列必须返回 false');
    assert.equal(await adapter.canSelect('SELECT id FROM missing_table LIMIT 0'), false);
    assert.equal(await adapter.canSelect('SELECT id FROM empty_table LIMIT 0'), true,
      '合法空表不能按没有行误判为没有字段');
    assert.equal(probeStore.results.every(rs => rs.closed), true);
  } finally { probeStore.close(); }

  for (const pooled of [true, false]) await checkInitializations(pooled);
  console.log('rdb-adapter-regression: PASS（生产Db适配器/延后错误/WAL双连接/旧库及错误v4补列/提交后校验/回滚重试）');
}

async function checkInitializations(pooled) {
  for (const version of [1, 3, 4]) {
    const store = legacy(version, false, pooled);
    try {
      const { Db } = production(store);
      await Db.init({});
      assert.equal(Db.version(), migration.SCHEMA_VERSION);
      assertRows(store);
      assert.deepEqual(store.queriesDuringTx, [], '迁移查询只能在写事务外执行');
      const writes = store.statements.length;
      await Db.init({});
      assert.equal(store.statements.length, writes);
    } finally { store.close(); }
  }

  const valid = legacy(4, true, pooled);
  try {
    const { Db } = production(valid);
    await Db.init({});
    assertRows(valid, 31, 96);
    assert.equal(valid.statements.some(sql => /ALTER|DROP/.test(sql)), false);
    assert.equal(Db.version(), migration.SCHEMA_VERSION);
  } finally { valid.close(); }

  for (const version of [3, 4]) {
    for (const failure of ['ADD COLUMN weekdays_mask', 'INSERT OR REPLACE INTO sync_meta', 'COMMIT']) {
      const store = legacy(version, false, pooled);
      try {
        const { Db } = production(store);
        store.fail = failure === 'COMMIT' ? '' : failure;
        store.failCommit = failure === 'COMMIT';
        await assert.rejects(() => Db.init({}), /injected .* failure/);
        assert.throws(() => Db.get(), /not initialized/);
        assert.equal(store.db.prepare("SELECT v FROM sync_meta WHERE k='schema_version'").get().v, String(version));
        assert.equal(store.db.prepare('SELECT COUNT(*) AS n FROM cycle_template').get().n, 2);
        assert.equal(store.commits, 0);
        assert.equal(store.rollbacks, 1);
        assert.equal(store.reader.prepare('PRAGMA table_info(cycle_template)').all()
          .some(c => c.name === 'weekdays_mask'), false, '任一写步骤失败，补列与版本必须一起回滚');
        store.fail = '';
        store.failCommit = false;
        await Db.init({});
        assertRows(store);
      } finally { store.close(); }
    }
  }

  const postCommit = legacy(3, false, pooled);
  try {
    const { Db } = production(postCommit);
    postCommit.failReadAfterCommit = true;
    await assert.rejects(() => Db.init({}), /not readable after committed migration/);
    assert.throws(() => Db.get(), /not initialized/);
    assert.equal(postCommit.commits, 1);
    assert.equal(postCommit.rollbacks, 0, '提交后读失败不能回滚已经提交的事务');
    assert.equal(postCommit.db.prepare("SELECT v FROM sync_meta WHERE k='schema_version'").get().v, String(migration.SCHEMA_VERSION));
    assert.deepEqual(postCommit.queriesDuringTx, []);
    assertRows(postCommit);
    const alters = postCommit.statements.filter(sql => sql.includes('ADD COLUMN weekdays_mask')).length;
    postCommit.failReadAfterCommit = false;
    await Db.init({});
    assertRows(postCommit);
    assert.equal(postCommit.statements.filter(sql => sql.includes('ADD COLUMN weekdays_mask')).length, alters);
  } finally { postCommit.close(); }

  const fresh = new MemoryRdbStore(pooled);
  try {
    const { Db } = production(fresh);
    await Db.init({});
    assert.equal(Db.version(), migration.SCHEMA_VERSION);
    fresh.db.prepare('INSERT INTO cycle_template(id,owner,name,seq,anchor_day) VALUES(?,?,?,?,?)')
      .run('main', 'ME', '新装', 'A', 20724);
    assert.equal(fresh.db.prepare('SELECT weekdays_mask FROM cycle_template').get().weekdays_mask, 127);
  } finally { fresh.close(); }
}
main().catch(error => { console.error(error.stack); process.exitCode = 1; });
