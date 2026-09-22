import { relationalStore } from '@kit.ArkData';
import { common } from '@kit.AbilityKit';
import { Logger } from 'commons';
import { MigrationDb, MigrationRunner, SCHEMA_VERSION } from './MigrationRunner';

const TAG = 'CrdDb';
const DB_NAME = 'commonrestday.db';

/**
 * 建表语句：始终描述"当前目标结构"（= MigrationRunner.SCHEMA_VERSION），新装库一次建到位；
 * 存量库的差距由 MigrationRunner 补齐，禁止在此处再写"ALTER 失败就忽略"的兜底。
 * - 日期一律存 epochDay 整数（本地纪元日），避免字符串/时区往返错误；
 * - 班表四表含 owner 列（'ME' | 'PARTNER'，默认 'ME'），schedule_override 复合主键 (owner, epoch_day)；
 * - plan 含 conflict_hint（冲突结果 JSON）与 reminder_id（本地提醒 id，-1 表示未注册）；
 * - plan.calendar_state/sync_state 为日历确认与云同步状态机占位，updated_at 供增量同步排序；
 * - computed_window 主键仍是 (start_min, end_min)：常规窗口上限 930 分钟、旅行窗口下限 960 分钟，
 *   两个通道的同一几何不可能重合，故无需把 channel 纳入主键；
 * - plan 不建 peer_event_hint 列（全仓库无读写代码，对方写入结果由 sync_meta 承载）。
 */
const DDL: string[] = [
  `CREATE TABLE IF NOT EXISTS shift_type (
    id TEXT PRIMARY KEY, owner TEXT NOT NULL DEFAULT 'ME', name TEXT NOT NULL, color TEXT NOT NULL,
    start_min INTEGER NOT NULL, end_min INTEGER NOT NULL, cross_day INTEGER NOT NULL DEFAULT 0,
    commute_in_min INTEGER DEFAULT 0, commute_out_min INTEGER DEFAULT 0,
    recovery_min INTEGER DEFAULT 0, night_mode INTEGER DEFAULT 0,
    allow_activity INTEGER DEFAULT 0, kind TEXT DEFAULT 'WORK')`,
  `CREATE TABLE IF NOT EXISTS cycle_template (
    id TEXT PRIMARY KEY, owner TEXT NOT NULL DEFAULT 'ME', name TEXT NOT NULL, seq TEXT NOT NULL, anchor_day INTEGER NOT NULL)`,
  `CREATE TABLE IF NOT EXISTS schedule_override (
    owner TEXT NOT NULL DEFAULT 'ME', epoch_day INTEGER NOT NULL, shift_type_id TEXT, note TEXT,
    PRIMARY KEY(owner, epoch_day))`,
  `CREATE TABLE IF NOT EXISTS course (
    id TEXT PRIMARY KEY, owner TEXT NOT NULL DEFAULT 'ME', name TEXT NOT NULL, weekday INTEGER NOT NULL,
    section_start INTEGER NOT NULL, section_end INTEGER NOT NULL,
    week_from INTEGER NOT NULL, week_to INTEGER NOT NULL,
    parity INTEGER DEFAULT 0, place TEXT)`,
  `CREATE TABLE IF NOT EXISTS term_config (
    id INTEGER PRIMARY KEY CHECK(id=1), term_start INTEGER, section_times TEXT)`,
  `CREATE TABLE IF NOT EXISTS plan (
    id TEXT PRIMARY KEY, title TEXT NOT NULL, kind TEXT NOT NULL,
    start_min INTEGER NOT NULL, end_min INTEGER NOT NULL,
    status TEXT DEFAULT 'OK', my_event_id TEXT,
    created_by TEXT, window_ref TEXT, conflict_hint TEXT,
    reminder_id INTEGER DEFAULT -1,
    updated_at INTEGER NOT NULL DEFAULT 0,
    calendar_state TEXT NOT NULL DEFAULT 'NOT_REQUESTED',
    sync_state TEXT NOT NULL DEFAULT 'LOCAL_ONLY')`,
  `CREATE TABLE IF NOT EXISTS computed_window (
    start_min INTEGER NOT NULL, end_min INTEGER NOT NULL,
    duration_min INTEGER NOT NULL, tags TEXT NOT NULL,
    computed_at INTEGER NOT NULL DEFAULT 0, channel TEXT NOT NULL DEFAULT 'REGULAR',
    PRIMARY KEY(start_min, end_min))`,
  `CREATE TABLE IF NOT EXISTS sync_meta (k TEXT PRIMARY KEY, v TEXT)`
];

/** RdbStore → MigrationDb 适配：迁移层只见这四类能力，事务语义由 RdbStore 原生提供。 */
class RdbMigration implements MigrationDb {
  private store: relationalStore.RdbStore;

  constructor(store: relationalStore.RdbStore) {
    this.store = store;
  }

  async execute(sql: string): Promise<void> {
    await this.store.executeSql(sql);
  }

  /** 只读探测：SQLite 对不存在的表/列直接报错，此处仅把"读不了"折算成 false。 */
  async canSelect(sql: string): Promise<boolean> {
    let rs: relationalStore.ResultSet | null = null;
    try {
      rs = await this.store.querySql(sql);
      return true;
    } catch (e) {
      return false;
    } finally {
      if (rs != null) {
        rs.close();
      }
    }
  }

  async getMeta(key: string): Promise<string> {
    const rs = await this.store.querySql('SELECT v FROM sync_meta WHERE k = ?', [key]);
    let v = '';
    if (rs.goToNextRow()) {
      const idx = rs.getColumnIndex('v');
      v = rs.isColumnNull(idx) ? '' : rs.getString(idx);
    }
    rs.close();
    return v;
  }

  async setMeta(key: string, value: string): Promise<void> {
    await this.store.executeSql('INSERT OR REPLACE INTO sync_meta (k, v) VALUES (?, ?)', [key, value]);
  }

  begin(): void {
    this.store.beginTransaction();
  }

  commit(): void {
    this.store.commit();
  }

  rollback(): void {
    this.store.rollBack();
  }
}

/** RDB 单例：应用启动时 init 一次。 */
export class Db {
  private static store: relationalStore.RdbStore | null = null;
  private static schemaVersion: number = 0;

  /** 初始化 RDB（应用/卡片等任一进程入口调用一次；Context 基类以兼容 FormExtensionAbility）。 */
  static async init(context: common.Context): Promise<void> {
    if (Db.store != null) {
      return;
    }
    const cfg: relationalStore.StoreConfig = {
      name: DB_NAME,
      securityLevel: relationalStore.SecurityLevel.S1
    };
    const s = await relationalStore.getRdbStore(context, cfg);
    const db = new RdbMigration(s);
    for (let i = 0; i < DDL.length; i++) {
      await db.execute(DDL[i]);
    }
    Db.schemaVersion = await MigrationRunner.upgrade(db);
    Db.store = s;
    Logger.info(TAG, 'db ready schema=' + Db.schemaVersion + '/' + SCHEMA_VERSION);
  }

  static get(): relationalStore.RdbStore {
    if (Db.store == null) {
      throw new Error('Db not initialized; call Db.init(context) first');
    }
    return Db.store;
  }

  /** 生效中的结构版本；0 表示尚未 init。 */
  static version(): number {
    return Db.schemaVersion;
  }

  static reset(): void {
    Db.store = null;
    Db.schemaVersion = 0;
  }
}
