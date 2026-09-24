import { describe, it, expect } from '@ohos/hypium';
import {
  MigrationDb, MigrationRunner, OWNER_KEY_CLAUSE, OWNER_SCOPED_TABLES, SCHEMA_VERSION, SCHEMA_VERSION_KEY
} from 'data';

/**
 * 迁移契约测试：新装、v1 升级、重复启动、中断回滚、主键重建（v3），以及"刚从备份恢复"的收口。
 * 用纯内存替身实现 MigrationDb，不依赖 @kit，因此事务与探测语义可被完整断言。
 *
 * 分工：这里证明"哪一版该补哪些列、恢复后该作废哪几项事实、失败时留在哪一格"这些**决策**；
 * 决策落到真实 RDB 上产生的**行效果**由 entry/src/ohosTest 的 UpgradeMigrationTest 验证。
 */

/** 已提交的列（'table.column'）。 */
function key(table: string, column: string): string {
  return table + '.' + column;
}

/**
 * MigrationDb 内存替身：
 * - execute 记账所有语句（stmts），ADD COLUMN 额外改变列集合，且事务内只挂起、commit 才落地；
 * - canSelect 按 'SELECT <col> FROM <table> LIMIT 0' 解析后查表；
 * - tableDDL 查 addTable 登记的建表原话，未登记的表返回空串；
 * - failPattern 命中时 execute 抛出，用于模拟迁移/清理中途失败。
 */
class FakeMigrationDb implements MigrationDb {
  columns: string[] = [];
  metaKeys: string[] = [];
  metaVals: string[] = [];
  private ddlKeys: string[] = [];
  private ddlVals: string[] = [];
  /** 全部已执行语句（含 UPDATE），按顺序；恢复清理的断言看这里。 */
  stmts: string[] = [];
  /** 其中改变结构的 ALTER 语句。 */
  alters: string[] = [];
  begins: number = 0;
  commits: number = 0;
  rollbacks: number = 0;
  metaWrites: number = 0;
  failPattern: string = '';
  private inTx: boolean = false;
  private pendingAlters: string[] = [];
  private pendingRenames: string[] = [];
  private pendingMetaKeys: string[] = [];
  private pendingMetaVals: string[] = [];

  hasColumn(table: string, column: string): boolean {
    return this.columns.indexOf(key(table, column)) >= 0;
  }

  /**
   * 登记一张表：cols 喂 canSelect，ddl 喂 tableDDL。
   * ddl 留空表示"sqlite_master 里没有这张表"（v1/v2 替身只管 plan 与 computed_window），重建探测会跳过。
   */
  addTable(name: string, cols: string[], ddl: string = ''): void {
    for (let i = 0; i < cols.length; i++) {
      this.columns.push(key(name, cols[i]));
    }
    this.writeDdl(name, ddl);
  }

  /** 命中重建的表名（按 stmts 里的 CREATE 语句归并，用于断言"三张表都动了、且只动一次"）。 */
  rebuiltTables(): string[] {
    const out: string[] = [];
    for (let i = 0; i < this.stmts.length; i++) {
      const m: string = this.stmts[i];
      if (m.indexOf('CREATE TABLE ') === 0 && m.indexOf('_v3 (') > 0) {
        out.push(m.slice('CREATE TABLE '.length, m.indexOf('_v3 (')));
      }
    }
    return out;
  }

  async execute(sql: string): Promise<void> {
    if (this.failPattern !== '' && sql.indexOf(this.failPattern) >= 0) {
      throw new Error('simulated sql failure: ' + sql);
    }
    this.stmts.push(sql);
    const parts: string[] = sql.split(' ');
    // 只认 ADD COLUMN：主键重建也发 ALTER（RENAME TO），但它不新增列
    if (parts[0] === 'ALTER' && parts[3] === 'ADD') {
      this.alters.push(sql);
      // ALTER TABLE <table> ADD COLUMN <column> ...
      if (this.inTx) {
        this.pendingAlters.push(parts[2] + '|' + parts[5]);
      } else {
        this.columns.push(key(parts[2], parts[5]));
      }
    }
    // 主键重建会换表名：事务外立即生效，事务内挂起到 commit（回滚就不许留下新结构）
    if (sql.indexOf('CREATE TABLE ') === 0 || sql.indexOf('DROP TABLE ') === 0
      || (parts[0] === 'ALTER' && parts[1] === 'TABLE' && parts[3] === 'RENAME')) {
      if (this.inTx) {
        this.pendingRenames.push(sql);
      } else {
        this.applyShape(sql);
      }
    }
  }

  /** 把一条改结构的语句折算成 sqlite_master 里该有的建表原话。 */
  private applyShape(sql: string): void {
    if (sql.indexOf('CREATE TABLE ') === 0) {
      const name: string = sql.slice('CREATE TABLE '.length, sql.indexOf(' ('));
      this.writeDdl(name, sql);
      return;
    }
    if (sql.indexOf('DROP TABLE ') === 0) {
      this.writeDdl(sql.slice('DROP TABLE '.length), '');
      return;
    }
    // ALTER TABLE <staging> RENAME TO <table>：换名后建表原话里的表名也跟着换
    const parts: string[] = sql.split(' ');
    const staging: string = parts[2];
    const target: string = parts[parts.length - 1];
    const ddl: string = this.ddlOf(staging);
    if (ddl !== '') {
      this.writeDdl(target, ddl.split(staging).join(target));
    }
    this.writeDdl(staging, '');
  }

  private ddlOf(name: string): string {
    const i: number = this.ddlKeys.indexOf(name);
    return i < 0 ? '' : this.ddlVals[i];
  }

  private writeDdl(name: string, ddl: string): void {
    const i: number = this.ddlKeys.indexOf(name);
    if (i < 0) {
      this.ddlKeys.push(name);
      this.ddlVals.push(ddl);
    } else {
      this.ddlVals[i] = ddl;
    }
  }

  async canSelect(sql: string): Promise<boolean> {
    const parts: string[] = sql.split(' ');
    // SELECT <col> FROM <table> ...
    return this.hasColumn(parts[3], parts[1]);
  }

  async tableDDL(name: string): Promise<string> {
    return this.ddlOf(name);
  }

  async getMeta(k: string): Promise<string> {
    const i: number = this.metaKeys.indexOf(k);
    if (i < 0) {
      return '';
    }
    return this.metaVals[i];
  }

  async setMeta(k: string, value: string): Promise<void> {
    this.metaWrites++;
    if (this.inTx) {
      this.pendingMetaKeys.push(k);
      this.pendingMetaVals.push(value);
    } else {
      this.writeMeta(k, value);
    }
  }

  begin(): void {
    this.begins++;
    this.inTx = true;
  }

  commit(): void {
    this.commits++;
    for (let i = 0; i < this.pendingAlters.length; i++) {
      const p: string[] = this.pendingAlters[i].split('|');
      this.columns.push(key(p[0], p[1]));
    }
    for (let i = 0; i < this.pendingRenames.length; i++) {
      this.applyShape(this.pendingRenames[i]);
    }
    for (let i = 0; i < this.pendingMetaKeys.length; i++) {
      this.writeMeta(this.pendingMetaKeys[i], this.pendingMetaVals[i]);
    }
    this.pendingAlters = [];
    this.pendingRenames = [];
    this.pendingMetaKeys = [];
    this.pendingMetaVals = [];
    this.inTx = false;
  }

  rollback(): void {
    this.rollbacks++;
    this.pendingAlters = [];
    // 回滚掉的建表/换名不许改变探测结果：下次启动看到的仍是旧主键，重建会整体重来
    this.pendingRenames = [];
    this.pendingMetaKeys = [];
    this.pendingMetaVals = [];
    this.inTx = false;
  }

  private writeMeta(k: string, value: string): void {
    const i: number = this.metaKeys.indexOf(k);
    if (i < 0) {
      this.metaKeys.push(k);
      this.metaVals.push(value);
    } else {
      this.metaVals[i] = value;
    }
  }
}

/** v1 存量库：plan 有 reminder_id 但无三个状态列，computed_window 无 computed_at/channel。 */
function v1Db(): FakeMigrationDb {
  const db = new FakeMigrationDb();
  db.addTable('plan', ['id', 'title', 'kind', 'start_min', 'end_min', 'status',
    'my_event_id', 'created_by', 'window_ref', 'conflict_hint', 'reminder_id']);
  db.addTable('computed_window', ['start_min', 'end_min', 'duration_min', 'tags']);
  db.addTable('sync_meta', ['k', 'v']);
  return db;
}

/** v2 目标结构齐备的库：建表 DDL 已产出全部目标列与 (owner, id) 主键（等价于 Db.ets 的 DDL 结果）。 */
function v2Db(): FakeMigrationDb {
  const db = v1Db();
  db.addTable('plan', ['updated_at', 'calendar_state', 'sync_state']);
  db.addTable('computed_window', ['computed_at', 'channel']);
  addOwnerScopedTables(db, true);
  return db;
}

/** 旧主键的建表原话：id 单列 PRIMARY KEY，owner 只是普通列。 */
function legacyKeyDdl(table: string): string {
  return 'CREATE TABLE ' + table + ' (id TEXT PRIMARY KEY, owner TEXT NOT NULL DEFAULT \'ME\','
    + ' name TEXT NOT NULL, ...)';
}

/** 登记三张 owner 隔离表；target=true 给新主键，false 给旧的单列主键。 */
function addOwnerScopedTables(db: FakeMigrationDb, target: boolean): void {
  for (let i = 0; i < OWNER_SCOPED_TABLES.length; i++) {
    const t = OWNER_SCOPED_TABLES[i];
    const ddl = target ? 'CREATE TABLE ' + t.table + ' (' + t.columns + ', ' + OWNER_KEY_CLAUSE + ')'
      : legacyKeyDdl(t.table);
    db.addTable(t.table, ['id', 'owner'], ddl);
  }
}

/** v2 存量库但班表三表还是旧主键：v3 迁移要重建的就是这种库。 */
function legacyOwnerKeysDb(): FakeMigrationDb {
  const db = v2Db();
  addOwnerScopedTables(db, false);
  return db;
}

const PLAN_COLS: string[] = ['updated_at', 'calendar_state', 'sync_state'];
const WINDOW_COLS: string[] = ['computed_at', 'channel'];

export default function dbMigrationTest() {
  describe('dbMigrationTest', () => {
    it('fresh_install_reaches_target_without_any_alter', 0, async () => {
      const db = v2Db();
      const version = await MigrationRunner.upgrade(db);
      expect(version).assertEqual(SCHEMA_VERSION);
      expect(db.alters.length).assertEqual(0);
      // 目标结构齐备的库连主键重建的语句都不该发一条
      expect(db.stmts.length).assertEqual(0);
      expect(await db.getMeta(SCHEMA_VERSION_KEY)).assertEqual(String(SCHEMA_VERSION));
    });

    it('v1_fixture_upgrades_to_target', 0, async () => {
      const db = v1Db();
      const version = await MigrationRunner.upgrade(db);
      expect(version).assertEqual(SCHEMA_VERSION);
      expect(db.alters.length).assertEqual(5);
      for (let i = 0; i < PLAN_COLS.length; i++) {
        expect(db.hasColumn('plan', PLAN_COLS[i])).assertTrue();
      }
      for (let i = 0; i < WINDOW_COLS.length; i++) {
        expect(db.hasColumn('computed_window', WINDOW_COLS[i])).assertTrue();
      }
      expect(await db.getMeta(SCHEMA_VERSION_KEY)).assertEqual(String(SCHEMA_VERSION));
      expect(db.begins).assertEqual(1);
      expect(db.commits).assertEqual(1);
      expect(db.rollbacks).assertEqual(0);
    });

    it('partial_schema_only_adds_missing_columns', 0, async () => {
      const db = v1Db();
      // 模拟历史兜底已补过 reminder_id 之外的 computed_at 一列
      db.addTable('computed_window', ['computed_at']);
      await MigrationRunner.upgrade(db);
      expect(db.alters.length).assertEqual(4);
      expect(db.alters[0].indexOf('updated_at') >= 0).assertTrue();
      expect(db.alters[3].indexOf('channel') >= 0).assertTrue();
    });

    it('second_run_is_no_side_effect', 0, async () => {
      const db = v1Db();
      await MigrationRunner.upgrade(db);
      const alters = db.alters.length;
      const begins = db.begins;
      const writes = db.metaWrites;
      const version = await MigrationRunner.upgrade(db);
      expect(version).assertEqual(SCHEMA_VERSION);
      expect(db.alters.length).assertEqual(alters);
      expect(db.begins).assertEqual(begins);
      expect(db.metaWrites).assertEqual(writes);
    });

    it('mid_migration_failure_rolls_back_and_leaves_v1', 0, async () => {
      const db = v1Db();
      db.failPattern = 'sync_state';
      let thrown = false;
      try {
        await MigrationRunner.upgrade(db);
      } catch (e) {
        thrown = true;
      }
      expect(thrown).assertTrue();
      expect(db.rollbacks).assertEqual(1);
      expect(db.commits).assertEqual(0);
      // 事务内已发出的前几条 ALTER 一并作废，不留下半迁移结构
      expect(db.hasColumn('plan', 'updated_at')).assertFalse();
      expect(db.hasColumn('plan', 'calendar_state')).assertFalse();
      expect(db.hasColumn('computed_window', 'computed_at')).assertFalse();
      expect(await db.getMeta(SCHEMA_VERSION_KEY)).assertEqual('');
      // 下次启动重新走完整迁移
      db.failPattern = '';
      expect(await MigrationRunner.upgrade(db)).assertEqual(SCHEMA_VERSION);
      // 回滚丢弃了事务内的 2 条 ALTER，失败的第 3 条从未落地，重试补齐全部 5 列
      expect(db.alters.length).assertEqual(7);
    });

    it('missing_sync_meta_is_treated_as_unversioned', 0, async () => {
      const db = new FakeMigrationDb();
      db.addTable('plan', ['id']);
      db.addTable('computed_window', ['start_min']);
      const version = await MigrationRunner.upgrade(db);
      expect(version).assertEqual(SCHEMA_VERSION);
      expect(db.alters.length).assertEqual(5);
    });

    // ---------- 恢复收口（阶段 6 Task 6.1） ----------

    it('fresh_install_demotes_nothing', 0, async () => {
      const db = v2Db();
      expect(await MigrationRunner.upgrade(db)).assertEqual(SCHEMA_VERSION);
      // 新装首启只 stamp 版本，一条 UPDATE 都不发
      expect(db.stmts.length).assertEqual(0);
      const begins = db.begins;
      await MigrationRunner.upgrade(db);
      // 之后每次普通启动也不会去清空日历状态：没有恢复标记就没有清理
      expect(db.stmts.length).assertEqual(0);
      expect(db.begins).assertEqual(begins);
    });

    it('restore_marker_demotes_device_local_facts_once', 0, async () => {
      const db = v2Db();
      await db.setMeta(SCHEMA_VERSION_KEY, String(SCHEMA_VERSION));
      await db.setMeta(MigrationRunner.RESTORE_PENDING_KEY, MigrationRunner.RESTORE_PENDING_ON);
      expect(await MigrationRunner.upgrade(db)).assertEqual(SCHEMA_VERSION);
      expect(MigrationRunner.RESTORE_CLEANUP_SQL.length).assertEqual(3);
      expect(db.stmts.length).assertEqual(3);
      expect(db.begins).assertEqual(1);
      expect(db.commits).assertEqual(1);
      // 口径：日历投影降级并清空来源设备的事件 id；提醒句柄归 -1；云端声明回到仅本地
      expect(db.stmts[0].indexOf("calendar_state = 'LOCAL_ONLY'") >= 0).assertTrue();
      expect(db.stmts[0].indexOf("my_event_id = ''") >= 0).assertTrue();
      // 6R.1 的新状态一个都不能漏：来源设备上的 MANAGED_WRITTEN / CLEANUP_PENDING 句柄
      // 换到这台机器上全是空引用，留着只会让清扫去删别人的日历。
      expect(db.stmts[0].indexOf("calendar_state IN ('WRITTEN', 'PENDING', 'MANAGED_WRITTEN',"
        + " 'EXTERNAL_UNMANAGED', 'CLEANUP_PENDING')") >= 0).assertTrue();
      expect(db.stmts[1].indexOf('reminder_id = -1') >= 0).assertTrue();
      expect(db.stmts[2].indexOf("sync_state = 'LOCAL_ONLY'") >= 0).assertTrue();
      // 标记随事务一起提交为"已清"：下次启动不再重复降级
      expect(await db.getMeta(MigrationRunner.RESTORE_PENDING_KEY)).assertEqual('');
      const stmts = db.stmts.length;
      await MigrationRunner.upgrade(db);
      expect(db.stmts.length).assertEqual(stmts);
    });

    it('v1_restore_upgrades_schema_before_demoting', 0, async () => {
      const db = v1Db();
      await db.setMeta(MigrationRunner.RESTORE_PENDING_KEY, MigrationRunner.RESTORE_PENDING_ON);
      await MigrationRunner.upgrade(db);
      // 清理写的正是迁移补出来的列，所以顺序必须是先 5 条 ALTER 再 3 条 UPDATE
      expect(db.alters.length).assertEqual(5);
      expect(db.stmts.length).assertEqual(8);
      expect(db.stmts[4].indexOf('ALTER TABLE') === 0).assertTrue();
      expect(db.stmts[5].indexOf('UPDATE plan') === 0).assertTrue();
      expect(db.begins).assertEqual(2);
      expect(db.commits).assertEqual(2);
      expect(await db.getMeta(SCHEMA_VERSION_KEY)).assertEqual(String(SCHEMA_VERSION));
    });

    it('cleanup_failure_keeps_the_marker_for_the_next_launch', 0, async () => {
      const db = v2Db();
      await db.setMeta(SCHEMA_VERSION_KEY, String(SCHEMA_VERSION));
      await db.setMeta(MigrationRunner.RESTORE_PENDING_KEY, MigrationRunner.RESTORE_PENDING_ON);
      db.failPattern = 'sync_state';
      let thrown = false;
      try {
        await MigrationRunner.upgrade(db);
      } catch (e) {
        thrown = true;
      }
      expect(thrown).assertTrue();
      expect(db.rollbacks).assertEqual(1);
      expect(db.commits).assertEqual(0);
      // 摘标记也在事务里：回滚后仍是 1，绝不留下"看起来清过了"的库
      expect(await db.getMeta(MigrationRunner.RESTORE_PENDING_KEY))
        .assertEqual(MigrationRunner.RESTORE_PENDING_ON);
      db.failPattern = '';
      await MigrationRunner.upgrade(db);
      expect(await db.getMeta(MigrationRunner.RESTORE_PENDING_KEY)).assertEqual('');
    });

    it('schema_from_a_newer_build_is_left_untouched', 0, async () => {
      const db = v2Db();
      await db.setMeta(MigrationRunner.RESTORE_PENDING_KEY, MigrationRunner.RESTORE_PENDING_ON);
      await db.setMeta(SCHEMA_VERSION_KEY, '4');
      // 从更新的装机恢复/回滚安装回来：本包不懂 v4，也不能把它的 stamp 改小
      expect(await MigrationRunner.upgrade(db)).assertEqual(4);
      expect(db.stmts.length).assertEqual(0);
      expect(db.begins).assertEqual(0);
      expect(await db.getMeta(SCHEMA_VERSION_KEY)).assertEqual('4');
      expect(await db.getMeta(MigrationRunner.RESTORE_PENDING_KEY))
        .assertEqual(MigrationRunner.RESTORE_PENDING_ON);
    });

    it('unparsable_version_is_re_stamped_not_rejected', 0, async () => {
      const db = v2Db();
      await db.setMeta(SCHEMA_VERSION_KEY, 'draft');
      // 脏值按"看不懂=未版本化"处理：列都在，只重新 stamp，不把启动堵死
      expect(await MigrationRunner.upgrade(db)).assertEqual(SCHEMA_VERSION);
      expect(db.alters.length).assertEqual(0);
      expect(await db.getMeta(SCHEMA_VERSION_KEY)).assertEqual(String(SCHEMA_VERSION));
    });

    // ---------- v3：班表三表主键改 (owner, id)（批次 K-5） ----------

    it('legacy_owner_keys_get_rebuilt', 0, async () => {
      const db = legacyOwnerKeysDb();
      expect(await MigrationRunner.upgrade(db)).assertEqual(SCHEMA_VERSION);
      // 三张表各四条：建临时表 / 搬数据 / 删旧表 / 换名，一条不多一条不少
      expect(db.rebuiltTables().length).assertEqual(OWNER_SCOPED_TABLES.length);
      expect(db.stmts.length).assertEqual(OWNER_SCOPED_TABLES.length * 4);
      // 换名不是加列：重建不许被算进补列账上，否则补列回归就看不出变化了
      expect(db.alters.length).assertEqual(0);
      expect(db.begins).assertEqual(1);
      expect(db.commits).assertEqual(1);
    });

    it('rebuild_copies_named_columns_then_renames', 0, async () => {
      const db = legacyOwnerKeysDb();
      await MigrationRunner.upgrade(db);
      const t = OWNER_SCOPED_TABLES[1];
      const base: number = db.stmts.indexOf('CREATE TABLE ' + t.table + '_v3 (' + t.columns + ', '
        + OWNER_KEY_CLAUSE + ')');
      expect(base >= 0).assertTrue();
      // 搬数据必须点名列，不能 SELECT *：列序一变就会把 name 灌进 seq
      expect(db.stmts[base + 1]).assertEqual('INSERT INTO ' + t.table + '_v3 (' + t.names + ') SELECT '
        + t.names + ' FROM ' + t.table);
      expect(db.stmts[base + 2]).assertEqual('DROP TABLE ' + t.table);
      expect(db.stmts[base + 3]).assertEqual('ALTER TABLE ' + t.table + '_v3 RENAME TO ' + t.table);
      // 换名生效后探测读到的就是新主键，同一张表不会再重建第二次
      expect((await db.tableDDL(t.table)).indexOf(OWNER_KEY_CLAUSE) >= 0).assertTrue();
    });

    it('rebuild_is_not_repeated_on_the_next_launch', 0, async () => {
      const db = legacyOwnerKeysDb();
      await MigrationRunner.upgrade(db);
      const stmts = db.stmts.length;
      // 第二次启动版本已达标：连探测都不该再发结构语句
      expect(await MigrationRunner.upgrade(db)).assertEqual(SCHEMA_VERSION);
      expect(db.stmts.length).assertEqual(stmts);
      expect(db.commits).assertEqual(1);
    });

    it('mid_rebuild_failure_leaves_the_old_shape', 0, async () => {
      const db = legacyOwnerKeysDb();
      db.failPattern = 'DROP TABLE cycle_template';
      let thrown = false;
      try {
        await MigrationRunner.upgrade(db);
      } catch (e) {
        thrown = true;
      }
      expect(thrown).assertTrue();
      expect(db.rollbacks).assertEqual(1);
      expect(db.commits).assertEqual(0);
      // 回滚后 sqlite_master 仍是旧主键，版本也没被 stamp 上去：下次启动整体重来
      expect((await db.tableDDL('cycle_template')).indexOf(OWNER_KEY_CLAUSE) < 0).assertTrue();
      expect(await db.getMeta(SCHEMA_VERSION_KEY)).assertEqual('');
      db.failPattern = '';
      expect(await MigrationRunner.upgrade(db)).assertEqual(SCHEMA_VERSION);
      expect((await db.tableDDL('cycle_template')).indexOf(OWNER_KEY_CLAUSE) >= 0).assertTrue();
    });

    it('only_the_legacy_tables_get_rebuilt', 0, async () => {
      const db = legacyOwnerKeysDb();
      // 课程表已经是新主键：探测到就不该再动它
      db.addTable('course', ['id', 'owner'], 'CREATE TABLE course ('
        + OWNER_SCOPED_TABLES[2].columns + ', ' + OWNER_KEY_CLAUSE + ')');
      await MigrationRunner.upgrade(db);
      expect(db.rebuiltTables().length).assertEqual(2);
      expect(db.rebuiltTables().indexOf('course') < 0).assertTrue();
    });
  });
}
