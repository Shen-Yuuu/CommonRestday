import { describe, it, expect } from '@ohos/hypium';
import { MigrationDb, MigrationRunner, SCHEMA_VERSION, SCHEMA_VERSION_KEY } from 'data';

/**
 * 迁移契约测试：新装、v1 升级、重复启动、中断回滚四类场景。
 * 用纯内存替身实现 MigrationDb，不依赖 @kit，因此事务与探测语义可被完整断言。
 */

/** 已提交的列（'table.column'）。 */
function key(table: string, column: string): string {
  return table + '.' + column;
}

/**
 * MigrationDb 内存替身：
 * - execute 的 ALTER 只在事务内挂起，commit 才落地、rollback 丢弃；
 * - canSelect 按 'SELECT <col> FROM <table> LIMIT 0' 解析后查表；
 * - failPattern 命中时 execute 抛出，用于模拟迁移中途失败。
 */
class FakeMigrationDb implements MigrationDb {
  columns: string[] = [];
  metaKeys: string[] = [];
  metaVals: string[] = [];
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
    this.alters.push(sql);
    const parts: string[] = sql.split(' ');
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
  });
}
