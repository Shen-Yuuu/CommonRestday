import { describe, it, expect } from '@ohos/hypium';
import { MigrationDb, MigrationRunner, SCHEMA_VERSION, SCHEMA_VERSION_KEY } from 'data';

/**
 * 迁移契约测试：新装、v1 升级、重复启动、中断回滚，以及"刚从备份恢复"的收口。
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
 * - execute 记账所有语句（stmts），ALTER 额外改变列集合，且事务内只挂起、commit 才落地；
 * - canSelect 按 'SELECT <col> FROM <table> LIMIT 0' 解析后查表；
 * - failPattern 命中时 execute 抛出，用于模拟迁移/清理中途失败。
 */
class FakeMigrationDb implements MigrationDb {
  columns: string[] = [];
  metaKeys: string[] = [];
  metaVals: string[] = [];
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
  private pendingMetaKeys: string[] = [];
  private pendingMetaVals: string[] = [];

  hasColumn(table: string, column: string): boolean {
    return this.columns.indexOf(key(table, column)) >= 0;
  }

  addTable(name: string, cols: string[]): void {
    for (let i = 0; i < cols.length; i++) {
      this.columns.push(key(name, cols[i]));
    }
  }

  async execute(sql: string): Promise<void> {
    if (this.failPattern !== '' && sql.indexOf(this.failPattern) >= 0) {
      throw new Error('simulated sql failure: ' + sql);
    }
    this.stmts.push(sql);
    const parts: string[] = sql.split(' ');
    if (parts[0] !== 'ALTER') {
      // 恢复清理那类 UPDATE 不改结构，只留语句记录
      return;
    }
    this.alters.push(sql);
    // ALTER TABLE <table> ADD COLUMN <column> ...
    if (this.inTx) {
      this.pendingAlters.push(parts[2] + '|' + parts[5]);
    } else {
      this.columns.push(key(parts[2], parts[5]));
    }
  }

  async canSelect(sql: string): Promise<boolean> {
    const parts: string[] = sql.split(' ');
    // SELECT <col> FROM <table> ...
    return this.hasColumn(parts[3], parts[1]);
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
    for (let i = 0; i < this.pendingMetaKeys.length; i++) {
      this.writeMeta(this.pendingMetaKeys[i], this.pendingMetaVals[i]);
    }
    this.pendingAlters = [];
    this.pendingMetaKeys = [];
    this.pendingMetaVals = [];
    this.inTx = false;
  }

  rollback(): void {
    this.rollbacks++;
    this.pendingAlters = [];
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

/** v2 新装库：建表 DDL 已产出全部目标列（等价于 Db.ets 的 DDL 结果）。 */
function v2Db(): FakeMigrationDb {
  const db = v1Db();
  db.addTable('plan', ['updated_at', 'calendar_state', 'sync_state']);
  db.addTable('computed_window', ['computed_at', 'channel']);
  return db;
}

const PLAN_COLS: string[] = ['updated_at', 'calendar_state', 'sync_state'];
const WINDOW_COLS: string[] = ['computed_at', 'channel'];

export default function dbMigrationTest() {
  describe('dbMigrationTest', () => {
    it('fresh_install_reaches_v2_without_any_alter', 0, async () => {
      const db = v2Db();
      const version = await MigrationRunner.upgrade(db);
      expect(version).assertEqual(SCHEMA_VERSION);
      expect(db.alters.length).assertEqual(0);
      expect(await db.getMeta(SCHEMA_VERSION_KEY)).assertEqual('2');
    });

    it('v1_fixture_upgrades_to_v2', 0, async () => {
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
      expect(await db.getMeta(SCHEMA_VERSION_KEY)).assertEqual('2');
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
      await db.setMeta(SCHEMA_VERSION_KEY, '3');
      // 从更新的装机恢复/回滚安装回来：本包不懂 v3，也不能把它的 stamp 改小
      expect(await MigrationRunner.upgrade(db)).assertEqual(3);
      expect(db.stmts.length).assertEqual(0);
      expect(db.begins).assertEqual(0);
      expect(await db.getMeta(SCHEMA_VERSION_KEY)).assertEqual('3');
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
  });
}
