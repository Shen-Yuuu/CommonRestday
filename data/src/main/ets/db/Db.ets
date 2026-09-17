import { relationalStore } from '@kit.ArkData';
import { common } from '@kit.AbilityKit';
import { Logger } from 'commons';

const TAG = 'CrdDb';
const DB_NAME = 'commonrestday.db';

/**
 * 建表语句（与技术架构文档 4.1 v1.1 一致，有两处工程化修正）：
 * - 日期一律存 epochDay 整数（本地纪元日），避免字符串/时区往返错误；
 * - 术语：anchor_day/term_start/epoch_day 均为 INTEGER；
 * - 班表四表含 owner 列（'ME' | 'PARTNER'，默认 'ME'），schedule_override 复合主键 (owner, epoch_day)；
 * - plan 表含 conflict_hint 列（冲突检测结果 JSON，可空）与 reminder_id 列（本地提醒 id，-1 表示未注册）；
 * - plan 表不建 peer_event_hint 列（全仓库无读写代码，建而无用；对方写入结果后续由 sync_meta 承载）。
 * dev 阶段直接改建表 SQL，无存量迁移负担。
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
    reminder_id INTEGER DEFAULT -1)`,
  `CREATE TABLE IF NOT EXISTS computed_window (
    start_min INTEGER NOT NULL, end_min INTEGER NOT NULL,
    duration_min INTEGER NOT NULL, tags TEXT NOT NULL,
    PRIMARY KEY(start_min, end_min))`,
  `CREATE TABLE IF NOT EXISTS sync_meta (k TEXT PRIMARY KEY, v TEXT)`
];

/** RDB 单例：应用启动时 init 一次。 */
export class Db {
  private static store: relationalStore.RdbStore | null = null;

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
    for (let i = 0; i < DDL.length; i++) {
      await s.executeSql(DDL[i]);
    }
    // 存量升级：旧开发库 plan 表缺 reminder_id 列时补列（新装建表 DDL 已含）；
    // 列已存在时 ALTER 报错，静默忽略（与 Slice 1 "新装建表为主" 的 DDL 模式一致，此处额外兜底）
    try {
      await s.executeSql('ALTER TABLE plan ADD COLUMN reminder_id INTEGER DEFAULT -1');
    } catch (e) {
      // 列已存在，无需处理
    }
    Db.store = s;
    Logger.info(TAG, 'db ready');
  }

  static get(): relationalStore.RdbStore {
    if (Db.store == null) {
      throw new Error('Db not initialized; call Db.init(context) first');
    }
    return Db.store;
  }

  static reset(): void {
    Db.store = null;
  }
}
