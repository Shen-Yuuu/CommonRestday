/**
 * 唯一数据库版本迁移入口（改造阶段 0）。
 *
 * 规则：
 * - schema_version 记在 sync_meta，是"是否已迁移"的唯一事实；
 * - 新装库由 Db 的建表 DDL 直接产出目标结构，迁移只负责补齐存量库缺失的列；
 * - 缺失列用一次只读探测判定（探测语句失败=列不存在），不写"ALTER 报错就忽略"的兜底；
 * - 主键换形（v3：班表三表由全局 id 改成 (owner, id)）用 sqlite_master 里的建表原话判定，
 *   重建走"临时表 + 搬数据 + 删旧表 + 换名"，与补列同在一个事务里，不留半迁移结构；
 * - 全部补齐语句在单一事务内执行，任一失败整体回滚并抛出，绝不留半迁移状态；
 * - 结构版本比本包高（从更新的装机恢复回来）时整段跳过：既不缺列可补，也绝不把别人的
 *   高版本 stamp 改写成本包版本——改了以后真到升级那一步就不会再跑。
 *
 * 除结构升级外，这里还是"刚从备份恢复"的唯一收口处：BackupExtensionAbility 只在 sync_meta
 * 置一个待清理标记，真正作废设备本地事实的语句在这里，随每次启动的 upgrade() 消费。
 * 放在这里是因为它必须晚于补列（清理要写 calendar_state/sync_state 这些新列），
 * 而恢复回调里再实现一遍同一套 UPDATE 只会让两处口径分叉。
 *
 * 本文件零 @kit 依赖：MigrationDb 是需要的最小能力，RdbStore 适配器在 Db.ets 实现，
 * 因此迁移决策可被本地单测完整覆盖。
 */

/** 目标结构版本。 */
export const SCHEMA_VERSION = 3;

/** sync_meta 中的版本键。 */
export const SCHEMA_VERSION_KEY = 'schema_version';

/** 迁移所需的最小数据库能力（RdbStore 适配器实现；测试用替身实现）。 */
export interface MigrationDb {
  /** 执行 DDL/DML。失败必须抛出。 */
  execute(sql: string): Promise<void>;
  /** 只读探测：语句可执行（表与列均存在）返回 true，否则 false。 */
  canSelect(sql: string): Promise<boolean>;
  /** 只读探测：sqlite_master 里这张表的建表语句；表不存在返回空串。 */
  tableDDL(name: string): Promise<string>;
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

/**
 * owner 隔离表的列定义（不含主键）与列名清单，按建表顺序。
 * Db.ets 建表和这里的重建语句共用同一份：两处各抄一遍，改一处就会让新装库和升级库长得不一样。
 */
export interface OwnerScopedTable {
  table: string;
  /** 列定义，顺序即 names 的顺序。 */
  columns: string;
  /** 列名清单，迁移搬数据时显式列出，不依赖 SELECT * 的隐式列序。 */
  names: string;
}

/** 目标主键的写法：存量表 DDL 里没有这一段，就说明还是"全局 id 主键"的旧结构。 */
export const OWNER_KEY_CLAUSE = 'PRIMARY KEY(owner, id)';

export const OWNER_SCOPED_TABLES: OwnerScopedTable[] = [
  {
    table: 'shift_type',
    columns: `id TEXT NOT NULL, owner TEXT NOT NULL DEFAULT 'ME', name TEXT NOT NULL, color TEXT NOT NULL,
    start_min INTEGER NOT NULL, end_min INTEGER NOT NULL, cross_day INTEGER NOT NULL DEFAULT 0,
    commute_in_min INTEGER DEFAULT 0, commute_out_min INTEGER DEFAULT 0,
    recovery_min INTEGER DEFAULT 0, night_mode INTEGER DEFAULT 0,
    allow_activity INTEGER DEFAULT 0, kind TEXT DEFAULT 'WORK'`,
    names: 'id, owner, name, color, start_min, end_min, cross_day, commute_in_min, commute_out_min,'
      + ' recovery_min, night_mode, allow_activity, kind'
  },
  {
    table: 'cycle_template',
    columns: `id TEXT NOT NULL, owner TEXT NOT NULL DEFAULT 'ME', name TEXT NOT NULL, seq TEXT NOT NULL,
    anchor_day INTEGER NOT NULL`,
    names: 'id, owner, name, seq, anchor_day'
  },
  {
    table: 'course',
    columns: `id TEXT NOT NULL, owner TEXT NOT NULL DEFAULT 'ME', name TEXT NOT NULL, weekday INTEGER NOT NULL,
    section_start INTEGER NOT NULL, section_end INTEGER NOT NULL,
    week_from INTEGER NOT NULL, week_to INTEGER NOT NULL,
    parity INTEGER DEFAULT 0, place TEXT`,
    names: 'id, owner, name, weekday, section_start, section_end, week_from, week_to, parity, place'
  }
];

/** 一张表的新旧主键切换：临时表建结构 → 搬数据 → 删旧表 → 换名。 */
export function ownerKeyRebuild(t: OwnerScopedTable): string[] {
  const staging: string = t.table + '_v3';
  const create = 'CREATE TABLE ' + staging + ' (' + t.columns + ', ' + OWNER_KEY_CLAUSE + ')';
  return [
    create,
    'INSERT INTO ' + staging + ' (' + t.names + ') SELECT ' + t.names + ' FROM ' + t.table,
    'DROP TABLE ' + t.table,
    'ALTER TABLE ' + staging + ' RENAME TO ' + t.table
  ];
}

/** 新装库这三张表的建表语句：和上面的重建目标同出一处，Db 只负责按序执行。 */
export function ownerScopedDdlList(): string[] {
  const out: string[] = [];
  for (let i = 0; i < OWNER_SCOPED_TABLES.length; i++) {
    const t = OWNER_SCOPED_TABLES[i];
    out.push('CREATE TABLE IF NOT EXISTS ' + t.table + ' (' + t.columns + ', ' + OWNER_KEY_CLAUSE + ')');
  }
  return out;
}

/** 去掉全部空白：比对 sqlite_master 里的建表语句时，换行和缩进不该算差异。 */
function squeeze(s: string): string {
  return s.split(' ').join('').split('\n').join('').split('\t').join('');
}

export class MigrationRunner {
  /** sync_meta 中的"待恢复清理"标记键；值 '1' 表示这份库刚从别的设备恢复过来。 */
  static readonly RESTORE_PENDING_KEY: string = 'restore_pending';
  static readonly RESTORE_PENDING_ON: string = '1';

  /**
   * 恢复后必须作废的设备本地事实（数组顺序即执行顺序）。
   *
   * 备份能带走"用户做过哪些计划"，带不走"这台机器上真实存在的东西"：
   * - 系统日历日程在来源设备上，恢复过来的库里 my_event_id 指向一个这里不存在的事件。
   *   留着它，卡片会宣称"已在系统日历里"，取消计划时又会去删一个不存在的事件；
   * - 提醒 id 是 ReminderAgent 当次注册的句柄，换设备后必然失效，
   *   留着它要么清不掉，要么误清掉别人复用的同一个 id；
   * - sync_state 记的是云端那份投影，而长期密钥在 HUKS 里、不参与备份——
   *   恢复后根本解不出对方快照，继续写着"已同步"就是谎报。
   * 状态取值与 feature/model/PlanFlow.ets 的 CalendarState 同一套字面量（data 层不反向依赖 feature）。
   */
  static readonly RESTORE_CLEANUP_SQL: string[] = [
    `UPDATE plan SET calendar_state = 'LOCAL_ONLY', my_event_id = ''
     WHERE calendar_state IN ('WRITTEN', 'PENDING', 'MANAGED_WRITTEN', 'EXTERNAL_UNMANAGED', 'CLEANUP_PENDING')`,
    `UPDATE plan SET reminder_id = -1 WHERE reminder_id >= 0`,
    `UPDATE plan SET sync_state = 'LOCAL_ONLY' WHERE sync_state <> 'LOCAL_ONLY'`
  ];

  /**
   * 升级到 SCHEMA_VERSION，返回迁移后的版本（结构已比本包新时返回那个更高的版本）。
   * 版本已达标且无待清理标记时不产生任何写操作（重复启动无副作用）。
   */
  static async upgrade(db: MigrationDb): Promise<number> {
    const recorded = MigrationRunner.parseVersion(await MigrationRunner.readVersion(db));
    if (recorded > SCHEMA_VERSION) {
      return recorded;
    }
    if (recorded !== SCHEMA_VERSION) {
      const missing = await MigrationRunner.missingAdditions(db);
      const rebuilds = await MigrationRunner.pendingKeyRebuilds(db);
      db.begin();
      try {
        for (let i = 0; i < missing.length; i++) {
          await db.execute(missing[i].ddl);
        }
        for (let i = 0; i < rebuilds.length; i++) {
          const stmts: string[] = rebuilds[i];
          for (let j = 0; j < stmts.length; j++) {
            await db.execute(stmts[j]);
          }
        }
        await db.setMeta(SCHEMA_VERSION_KEY, String(SCHEMA_VERSION));
        db.commit();
      } catch (e) {
        db.rollback();
        throw e as Error;
      }
    }
    await MigrationRunner.finishRestore(db);
    return SCHEMA_VERSION;
  }

  /**
   * 消费"刚从备份恢复"标记：有标记才动手，没标记一条语句都不发。
   * 必须在结构补齐之后调用——下面这些 UPDATE 写的正是迁移补出来的列。
   */
  static async finishRestore(db: MigrationDb): Promise<void> {
    if (await db.getMeta(MigrationRunner.RESTORE_PENDING_KEY) !== MigrationRunner.RESTORE_PENDING_ON) {
      return;
    }
    await MigrationRunner.recoverAfterRestore(db);
  }

  /**
   * 恢复清理本体：单一事务，成功后才摘标记。
   * 中途失败整体回滚并抛出，标记原样留着，下次启动重来——不会把"清了一半"当成"已经清了"。
   */
  static async recoverAfterRestore(db: MigrationDb): Promise<void> {
    db.begin();
    try {
      const sql: string[] = MigrationRunner.RESTORE_CLEANUP_SQL;
      for (let i = 0; i < sql.length; i++) {
        await db.execute(sql[i]);
      }
      await db.setMeta(MigrationRunner.RESTORE_PENDING_KEY, '');
      db.commit();
    } catch (e) {
      db.rollback();
      throw e as Error;
    }
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

  /**
   * 探测出还是"全局 id 主键"的 owner 隔离表，给出各自的重建语句组。
   * 判据读的是 sqlite_master 里的原话，而不是"插一条撞主键试试"：探测必须只读，
   * 迁移跑在启动路径上，任何写试探都会在失败时留下痕迹或被事务挡住。
   * 表不存在（空串）时跳过——新装库由 DDL 直接建到位，没有旧结构要修。
   */
  static async pendingKeyRebuilds(db: MigrationDb): Promise<string[][]> {
    const out: string[][] = [];
    for (let i = 0; i < OWNER_SCOPED_TABLES.length; i++) {
      const t = OWNER_SCOPED_TABLES[i];
      const ddl = await db.tableDDL(t.table);
      if (ddl !== '' && squeeze(ddl).indexOf(squeeze(OWNER_KEY_CLAUSE)) < 0) {
        out.push(ownerKeyRebuild(t));
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

  /**
   * 版本值 → 数字；空串/非数字（历史脏值、手工改库）一律按 -1 处理，
   * 让"看不懂"落到"照常补齐并重新 stamp"这一支，而不是抛异常把启动堵死。
   */
  static parseVersion(recorded: string): number {
    const n: number = Number(recorded);
    if (recorded === '' || Number.isNaN(n)) {
      return -1;
    }
    return n;
  }
}
