/**
 * 唯一数据库版本迁移入口（改造阶段 0）。
 *
 * 规则：
 * - schema_version 记在 sync_meta，是"是否已迁移"的唯一事实；
 * - 新装库由 Db 的建表 DDL 直接产出目标结构，迁移只负责补齐存量库缺失的列；
 * - 缺失列用一次只读探测判定（探测语句失败=列不存在），不写"ALTER 报错就忽略"的兜底；
 * - 全部补齐语句在单一事务内执行，任一失败整体回滚并抛出，绝不留半迁移状态。
 *
 * 本文件零 @kit 依赖：MigrationDb 是需要的最小能力，RdbStore 适配器在 Db.ets 实现，
 * 因此迁移决策可被本地单测完整覆盖。
 */

/** 目标结构版本。 */
export const SCHEMA_VERSION = 2;

/** sync_meta 中的版本键。 */
export const SCHEMA_VERSION_KEY = 'schema_version';

/** 迁移所需的最小数据库能力（RdbStore 适配器实现；测试用替身实现）。 */
export interface MigrationDb {
  /** 执行 DDL/DML。失败必须抛出。 */
  execute(sql: string): Promise<void>;
  /** 只读探测：语句可执行（表与列均存在）返回 true，否则 false。 */
  canSelect(sql: string): Promise<boolean>;
  /** 读取 sync_meta 的值；无记录返回空串。 */
  getMeta(key: string): Promise<string>;
  /** 写入 sync_meta 的值。 */
  setMeta(key: string, value: string): Promise<void>;
  begin(): void;
  commit(): void;
  rollback(): void;
}

/** 一处补列：所属表、列名与完整 ALTER 语句。 */
export interface ColumnAddition {
  table: string;
  column: string;
  ddl: string;
}

/** v1 → v2 需要补齐的列（新装 DDL 已含同名列，两处必须同步）。 */
export const V2_ADDITIONS: ColumnAddition[] = [
  { table: 'plan', column: 'updated_at', ddl: 'ALTER TABLE plan ADD COLUMN updated_at INTEGER NOT NULL DEFAULT 0' },
  { table: 'plan', column: 'calendar_state',
    ddl: 'ALTER TABLE plan ADD COLUMN calendar_state TEXT NOT NULL DEFAULT \'NOT_REQUESTED\'' },
  { table: 'plan', column: 'sync_state',
    ddl: 'ALTER TABLE plan ADD COLUMN sync_state TEXT NOT NULL DEFAULT \'LOCAL_ONLY\'' },
  { table: 'computed_window', column: 'computed_at',
    ddl: 'ALTER TABLE computed_window ADD COLUMN computed_at INTEGER NOT NULL DEFAULT 0' },
  { table: 'computed_window', column: 'channel',
    ddl: 'ALTER TABLE computed_window ADD COLUMN channel TEXT NOT NULL DEFAULT \'REGULAR\'' }
];

export class MigrationRunner {
  /**
   * 升级到 SCHEMA_VERSION，返回迁移后的版本。
   * 版本已达标时不产生任何写操作（重复启动无副作用）。
   */
  static async upgrade(db: MigrationDb): Promise<number> {
    const recorded = await MigrationRunner.readVersion(db);
    if (recorded === String(SCHEMA_VERSION)) {
      return SCHEMA_VERSION;
    }
    const missing = await MigrationRunner.missingAdditions(db);
    db.begin();
    try {
      for (let i = 0; i < missing.length; i++) {
        await db.execute(missing[i].ddl);
      }
      await db.setMeta(SCHEMA_VERSION_KEY, String(SCHEMA_VERSION));
      db.commit();
    } catch (e) {
      db.rollback();
      throw e as Error;
    }
    return SCHEMA_VERSION;
  }

  /** 探测出目标结构中缺失的列（保持 V2_ADDITIONS 的顺序，便于断言与排障）。 */
  static async missingAdditions(db: MigrationDb): Promise<ColumnAddition[]> {
    const out: ColumnAddition[] = [];
    for (let i = 0; i < V2_ADDITIONS.length; i++) {
      const a = V2_ADDITIONS[i];
      const present = await db.canSelect('SELECT ' + a.column + ' FROM ' + a.table + ' LIMIT 0');
      if (!present) {
        out.push(a);
      }
    }
    return out;
  }

  /** 读取已记录版本；无记录（存量库/新装未写入）返回空串。 */
  static async readVersion(db: MigrationDb): Promise<string> {
    const present = await db.canSelect('SELECT v FROM sync_meta LIMIT 0');
    if (!present) {
      return '';
    }
    return await db.getMeta(SCHEMA_VERSION_KEY);
  }
}
