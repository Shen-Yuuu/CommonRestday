import { relationalStore } from '@kit.ArkData';
import {
  Course, CycleTemplate, OWNER_ME, OWNER_PARTNER, PlanBlock, ScheduleOverride, ShiftType, Window, WindowChannel
} from 'domain';
import { Db } from '../db/Db';
import { Logger } from 'commons';

/**
 * 班表相关仓库：班次类型 / 循环模板 / 单日覆盖 / 课程 / 学期 / 共同计划 / 窗口缓存。
 * 日期一律 epochDay 整数；计划/窗口时段存 epochMin（分钟）。
 * RdbStore.query/querySql 返回 Promise，读取类方法均为 async。
 * 班表四表按 owner（'ME' | 'PARTNER'）隔离；owner 缺省为 'ME' 保持既有调用兼容。
 */

/** 计划行（含展示字段）。 */
export interface PlanRow extends PlanBlock {
  id: string;
  title: string;
  kind: string;
  status: string;
  /** 创建方（'ME'；预留伴侣侧 'PARTNER' 同步创建）。 */
  createdBy: string;
  /** 关联共同窗口起止 JSON {"s":start,"e":end}；空串表示未记录。 */
  windowRef: string;
  /** 冲突检测结果 JSON（替代窗口起止）；空串表示无冲突或无替代。 */
  conflictHint: string;
  /** 关联的系统日历日程 id：受管写入/导出的那条日程；空串表示系统日历里没有它。 */
  myEventId: string;
  /** 关联的本地提醒 id；-1 表示没有提醒。D-20 起应用不再注册系统提醒，所以生产路径恒为 -1，列留着只为兼容旧行与如实报数。 */
  reminderId: number;
  /** 最后修改时间（epoch ms）；所有 plan 写入方共同维护，供后续增量同步排序。 */
  updatedAt: number;
  /**
   * 系统日历投影状态机：NOT_REQUESTED/PENDING/MANAGED_WRITTEN/EXTERNAL_UNMANAGED/
   * CLEANUP_PENDING/LOCAL_ONLY/UNSUPPORTED/FAILED（取值与含义见 feature 的 CalendarState）。
   * 存字符串而不是枚举：data 不依赖 feature，读侧统一由 normalizeCalendarState 归一。
   */
  calendarState: string;
  /** 云同步状态机：LOCAL_ONLY/PENDING/SYNCED/ERROR；与配对状态相互独立。 */
  syncState: string;
}

/** channel 列的容错解析：迁移前的历史值一律按常规通道解释。 */
function channelOf(text: string): WindowChannel {
  const trip: string = WindowChannel.TRIP;
  return text === trip ? WindowChannel.TRIP : WindowChannel.REGULAR;
}

/** plan 表全部列：清扫类查询要带 status/calendar_state，用不上 RdbPredicates 的 OR 组合。 */
const PLAN_COLUMNS = `SELECT id, title, kind, status, created_by, window_ref, start_min, end_min,
        conflict_hint, my_event_id, reminder_id, updated_at, calendar_state, sync_state
      FROM plan`;

export class ScheduleRepo {
  /**
   * 事务包裹一批写入：要么全部落库，要么整批回滚。
   * 月历涂抹和课程导入是"一次编辑几十天/几十门"，中途失败留下半套班表比全不做更糟。
   * begin/commit 是同步接口，因此 commit 必须在 work() 的所有 await 之后调用。
   */
  static async runInTransaction(work: () => Promise<void>): Promise<void> {
    const store = Db.get();
    store.beginTransaction();
    try {
      await work();
      store.commit();
    } catch (e) {
      try {
        store.rollBack();
      } catch (rb) {
        // 回滚失败不覆盖原始错误：调用方要看到的是那条真正失败的 SQL
        Logger.warn('ScheduleRepo', 'rollback failed: ' + (rb as Error).message);
      }
      throw e as Error;
    }
  }

  // ---------- 班次类型 ----------

  static async upsertShiftType(st: ShiftType, owner: string = OWNER_ME): Promise<void> {
    const sql = `INSERT OR REPLACE INTO shift_type
      (id, owner, name, color, start_min, end_min, cross_day, commute_in_min, commute_out_min,
       recovery_min, night_mode, allow_activity, kind)
      VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`;
    await Db.get().executeSql(sql, [
      st.id, owner, st.name, st.color, st.startMin, st.endMin, st.crossDay ? 1 : 0,
      st.commuteInMin, st.commuteOutMin, st.recoveryMin, st.nightMode,
      st.allowActivity ? 1 : 0, st.kind
    ]);
  }

  /** 删除指定 owner 的班次类型（id + owner 双条件，防止跨 owner 误删）。 */
  static async deleteShiftType(id: string, owner: string = OWNER_ME): Promise<void> {
    const pred = new relationalStore.RdbPredicates('shift_type');
    pred.equalTo('id', id);
    pred.equalTo('owner', owner);
    await Db.get().delete(pred);
  }

  static async listShiftTypes(owner: string = OWNER_ME): Promise<ShiftType[]> {
    const pred = new relationalStore.RdbPredicates('shift_type');
    pred.equalTo('owner', owner);
    const rs = await Db.get().query(pred);
    const out: ShiftType[] = [];
    while (rs.goToNextRow()) {
      const st: ShiftType = {
        id: rs.getString(rs.getColumnIndex('id')),
        name: rs.getString(rs.getColumnIndex('name')),
        color: rs.getString(rs.getColumnIndex('color')),
        startMin: rs.getLong(rs.getColumnIndex('start_min')),
        endMin: rs.getLong(rs.getColumnIndex('end_min')),
        crossDay: rs.getLong(rs.getColumnIndex('cross_day')) === 1,
        commuteInMin: rs.getLong(rs.getColumnIndex('commute_in_min')),
        commuteOutMin: rs.getLong(rs.getColumnIndex('commute_out_min')),
        recoveryMin: rs.getLong(rs.getColumnIndex('recovery_min')),
        nightMode: rs.getLong(rs.getColumnIndex('night_mode')),
        allowActivity: rs.getLong(rs.getColumnIndex('allow_activity')) === 1,
        kind: rs.getString(rs.getColumnIndex('kind'))
      };
      out.push(st);
    }
    rs.close();
    return out;
  }

  // ---------- 循环模板 ----------

  static async saveTemplate(tpl: CycleTemplate, owner: string = OWNER_ME): Promise<void> {
    const pred = new relationalStore.RdbPredicates('cycle_template');
    pred.equalTo('owner', owner);
    await Db.get().delete(pred);
    const sql = 'INSERT INTO cycle_template (id, owner, name, seq, anchor_day) VALUES (?, ?, ?, ?, ?)';
    await Db.get().executeSql(sql, [tpl.id, owner, tpl.name, tpl.seq.join(','), tpl.anchorEpochDay]);
  }

  static async getTemplate(owner: string = OWNER_ME): Promise<CycleTemplate | null> {
    const pred = new relationalStore.RdbPredicates('cycle_template');
    pred.equalTo('owner', owner);
    const rs = await Db.get().query(pred);
    let out: CycleTemplate | null = null;
    if (rs.goToNextRow()) {
      const seqText = rs.getString(rs.getColumnIndex('seq'));
      const seq: string[] = seqText === '' ? [] : seqText.split(',');
      const anchor = rs.getLong(rs.getColumnIndex('anchor_day'));
      out = {
        id: rs.getString(rs.getColumnIndex('id')),
        name: rs.getString(rs.getColumnIndex('name')),
        seq: seq,
        anchorEpochDay: anchor
      };
    }
    rs.close();
    return out;
  }

  /** 删除指定 owner 的循环模板（CycleEditor"清空模板"时真删 DB）。 */
  static async deleteTemplate(owner: string = OWNER_ME): Promise<void> {
    const pred = new relationalStore.RdbPredicates('cycle_template');
    pred.equalTo('owner', owner);
    await Db.get().delete(pred);
  }

  // ---------- 单日覆盖 ----------

  static async upsertOverride(o: ScheduleOverride, note: string, owner: string = OWNER_ME): Promise<void> {
    const sql = 'INSERT OR REPLACE INTO schedule_override (owner, epoch_day, shift_type_id, note) VALUES (?, ?, ?, ?)';
    await Db.get().executeSql(sql, [owner, o.epochDay, o.shiftTypeId == null ? '' : o.shiftTypeId, note]);
  }

  static async deleteOverride(epochDay: number, owner: string = OWNER_ME): Promise<void> {
    const pred = new relationalStore.RdbPredicates('schedule_override');
    pred.equalTo('owner', owner);
    pred.equalTo('epoch_day', epochDay);
    await Db.get().delete(pred);
  }

  /** 查询范围 [fromDay, toDay]；shift_type_id 空串 = 该日清空为休息（shiftTypeId=null）。 */
  static async listOverrides(fromDay: number, toDay: number, owner: string = OWNER_ME): Promise<ScheduleOverride[]> {
    const pred = new relationalStore.RdbPredicates('schedule_override');
    pred.equalTo('owner', owner);
    pred.between('epoch_day', fromDay, toDay);
    const rs = await Db.get().query(pred);
    const out: ScheduleOverride[] = [];
    while (rs.goToNextRow()) {
      const idText = rs.getString(rs.getColumnIndex('shift_type_id'));
      const o: ScheduleOverride = {
        epochDay: rs.getLong(rs.getColumnIndex('epoch_day')),
        shiftTypeId: idText === '' ? null : idText
      };
      out.push(o);
    }
    rs.close();
    return out;
  }

  // ---------- 课程 ----------

  static async upsertCourse(c: Course, owner: string = OWNER_ME): Promise<void> {
    const sql = `INSERT OR REPLACE INTO course
      (id, owner, name, weekday, section_start, section_end, week_from, week_to, parity, place)
      VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`;
    await Db.get().executeSql(sql, [
      c.id, owner, c.name, c.weekday, c.sectionStart, c.sectionEnd, c.weekFrom, c.weekTo, c.parity, c.place
    ]);
  }

  /** 删除指定 owner 的课程（id + owner 双条件，防止跨 owner 误删）。 */
  static async deleteCourse(id: string, owner: string = OWNER_ME): Promise<void> {
    const pred = new relationalStore.RdbPredicates('course');
    pred.equalTo('id', id);
    pred.equalTo('owner', owner);
    await Db.get().delete(pred);
  }

  static async listCourses(owner: string = OWNER_ME): Promise<Course[]> {
    const pred = new relationalStore.RdbPredicates('course');
    pred.equalTo('owner', owner);
    const rs = await Db.get().query(pred);
    const out: Course[] = [];
    while (rs.goToNextRow()) {
      const c: Course = {
        id: rs.getString(rs.getColumnIndex('id')),
        name: rs.getString(rs.getColumnIndex('name')),
        weekday: rs.getLong(rs.getColumnIndex('weekday')),
        sectionStart: rs.getLong(rs.getColumnIndex('section_start')),
        sectionEnd: rs.getLong(rs.getColumnIndex('section_end')),
        weekFrom: rs.getLong(rs.getColumnIndex('week_from')),
        weekTo: rs.getLong(rs.getColumnIndex('week_to')),
        parity: rs.getLong(rs.getColumnIndex('parity')),
        place: rs.getString(rs.getColumnIndex('place'))
      };
      out.push(c);
    }
    rs.close();
    return out;
  }

  // ---------- 伴侣数据级联清除 ----------

  /** 删除四表中 owner='PARTNER' 的全部行（删除伴侣档案时调用，回退单人模式）。 */
  static async deletePartnerData(): Promise<void> {
    const tables: string[] = ['shift_type', 'cycle_template', 'schedule_override', 'course'];
    for (let i = 0; i < tables.length; i++) {
      const pred = new relationalStore.RdbPredicates(tables[i]);
      pred.equalTo('owner', OWNER_PARTNER);
      await Db.get().delete(pred);
    }
  }

  // ---------- 全量清空 ----------

  /** 清空全部 8 张表的所有行（"清空我的全部数据"设置项调用；设置侧配合 SettingsStore.clearAllSettings）。 */
  static async clearAllData(): Promise<void> {
    const tables: string[] = [
      'shift_type', 'cycle_template', 'schedule_override', 'course',
      'term_config', 'plan', 'computed_window', 'sync_meta'
    ];
    const s = Db.get();
    for (let i = 0; i < tables.length; i++) {
      await s.executeSql(`DELETE FROM ${tables[i]}`);
    }
  }

  // ---------- 学期配置 ----------

  static async saveTermConfig(termStartEpochDay: number, sectionTimesJson: string): Promise<void> {
    const sql = 'INSERT OR REPLACE INTO term_config (id, term_start, section_times) VALUES (1, ?, ?)';
    await Db.get().executeSql(sql, [termStartEpochDay, sectionTimesJson]);
  }

  static async getTermStart(): Promise<number> {
    const rs = await Db.get().querySql('SELECT term_start FROM term_config WHERE id = 1');
    let v = -1;
    if (rs.goToNextRow()) {
      const idx = rs.getColumnIndex('term_start');
      if (!rs.isColumnNull(idx)) {
        v = rs.getLong(idx);
      }
    }
    rs.close();
    return v;
  }

  /** 节次作息模板 JSON；未保存时返回空串（调用方回退默认模板）。 */
  static async getSectionTimes(): Promise<string> {
    const rs = await Db.get().querySql('SELECT section_times FROM term_config WHERE id = 1');
    let v = '';
    if (rs.goToNextRow()) {
      const idx = rs.getColumnIndex('section_times');
      if (!rs.isColumnNull(idx)) {
        v = rs.getString(idx);
      }
    }
    rs.close();
    return v;
  }

  // ---------- 共同计划 ----------

  static async upsertPlan(p: PlanRow): Promise<void> {
    const sql = `INSERT OR REPLACE INTO plan
      (id, title, kind, start_min, end_min, status, created_by, window_ref,
       conflict_hint, my_event_id, reminder_id, updated_at, calendar_state, sync_state)
      VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`;
    await Db.get().executeSql(sql,
      [p.id, p.title, p.kind, p.start, p.end, p.status, p.createdBy, p.windowRef,
        p.conflictHint, p.myEventId, p.reminderId, p.updatedAt, p.calendarState, p.syncState]);
  }

  /**
   * 单行按 id 更新若干列。plan 的六个写入口共用这一处 RDB 调用：
   * 每个方法各写一遍 predicates 只是把同一条"改一行"的语句抄六遍。
   */
  private static async setPlanColumns(id: string, vb: relationalStore.ValuesBucket): Promise<void> {
    const pred = new relationalStore.RdbPredicates('plan');
    pred.equalTo('id', id);
    await Db.get().update(vb, pred);
  }

  /**
   * 回写日历确认结果（CalendarGateway 返回后调用）：状态 + 日程 id。
   * eventId 传空串表示系统日历里没有这条（用户取消/无权限/不可用），计划本身照常保留。
   */
  static async updatePlanCalendar(id: string, calendarState: string, eventId: string): Promise<void> {
    await ScheduleRepo.setPlanColumns(id,
      { 'calendar_state': calendarState, 'my_event_id': eventId, 'updated_at': Date.now() });
  }

  /**
   * 一次投影回写：日历状态 + 日程 id + 提醒句柄。
   *
   * 取消/改期后"还剩哪些系统侧句柄"必须由调用方一次说清（删成功的传空、删不掉的原样留着），
   * 分成两次写会出现"日程已清、提醒句柄还挂着"的半套状态，重试判据就不可信了。
   */
  static async updatePlanProjection(id: string, calendarState: string, eventId: string,
    reminderId: number): Promise<void> {
    await ScheduleRepo.setPlanColumns(id, {
      'calendar_state': calendarState, 'my_event_id': eventId, 'reminder_id': reminderId,
      'updated_at': Date.now()
    });
  }

  /** 回写计划关联的本地提醒 id（-1 表示无提醒）。自 D-20 起真机实现恒回 -1，调用方只在拿到非负句柄时回写。 */
  static async updatePlanReminder(id: string, reminderId: number): Promise<void> {
    await ScheduleRepo.setPlanColumns(id, { 'reminder_id': reminderId, 'updated_at': Date.now() });
  }

  static async updatePlanStatus(id: string, status: string): Promise<void> {
    await ScheduleRepo.setPlanColumns(id, { 'status': status, 'updated_at': Date.now() });
  }

  /** 改期：更新计划起止（接受冲突替代窗口时调用；状态由重算的冲突检测复核）。 */
  static async updatePlanTime(id: string, start: number, end: number): Promise<void> {
    await ScheduleRepo.setPlanColumns(id,
      { 'start_min': start, 'end_min': end, 'updated_at': Date.now() });
  }

  /** 冲突检测结果回写：状态 + conflict_hint（替代窗口 JSON，空串表示无冲突/无替代）。 */
  static async updatePlanConflict(id: string, status: string, conflictHint: string): Promise<void> {
    await ScheduleRepo.setPlanColumns(id,
      { 'status': status, 'conflict_hint': conflictHint, 'updated_at': Date.now() });
  }

  /** 状态非 CANCELLED 的计划，按开始时间升序（含 conflict_hint）。 */
  static async listActivePlans(): Promise<PlanRow[]> {
    const sql = PLAN_COLUMNS + `
      WHERE status <> 'CANCELLED'
      ORDER BY start_min ASC`;
    return ScheduleRepo.queryPlans(sql);
  }

  /**
   * 需要清扫"系统侧残留"的计划（**含 CANCELLED**），按开始时间升序。
   *
   * 两类，判据各不相同：
   * - calendar_state = CLEANUP_PENDING：本机已经改完，日程/提醒删不动、句柄还留着等重试；
   * - status = CANCELLED 且带着句柄：已取消的计划本不该在日历上留东西（连这条 SQL 之前崩溃的
   *   那种"标了取消没来得及回写"也算进来）。
   *
   * 不能只看"有没有 my_event_id"——活动计划的 id 是正常投影，照那个条件清扫会把用户
   * 还要用的日程全删了。listActivePlans 也帮不上忙：它过滤掉 CANCELLED，孤儿正好藏在里面。
   */
  static async listOrphanProjectionPlans(): Promise<PlanRow[]> {
    const sql = PLAN_COLUMNS + `
      WHERE calendar_state = 'CLEANUP_PENDING'
         OR (status = 'CANCELLED'
             AND ((my_event_id IS NOT NULL AND my_event_id <> '') OR reminder_id >= 0))
      ORDER BY start_min ASC`;
    return ScheduleRepo.queryPlans(sql);
  }

  /**
   * 带着系统侧句柄（日程 id 或提醒 id）的全部计划——**含 CANCELLED、含活动计划**。
   * "清空我的全部数据"在清库之前用它把日历和提醒一起带走：那句承诺不该只管本机表。
   */
  static async listPlansCarryingHandles(): Promise<PlanRow[]> {
    const sql = PLAN_COLUMNS + `
      WHERE (my_event_id IS NOT NULL AND my_event_id <> '') OR reminder_id >= 0
      ORDER BY start_min ASC`;
    return ScheduleRepo.queryPlans(sql);
  }

  private static async queryPlans(sql: string): Promise<PlanRow[]> {
    const rs = await Db.get().querySql(sql);
    const out: PlanRow[] = [];
    while (rs.goToNextRow()) {
      out.push(ScheduleRepo.planRowOf(rs));
    }
    rs.close();
    return out;
  }

  /** 计划行读取：两处分站共用，NULL 兜底与 DDL 默认一致（迁移补列后旧行为默认值）。 */
  private static planRowOf(rs: relationalStore.ResultSet): PlanRow {
    const hintIdx = rs.getColumnIndex('conflict_hint');
    const evIdx = rs.getColumnIndex('my_event_id');
    const ridIdx = rs.getColumnIndex('reminder_id');
    const cbIdx = rs.getColumnIndex('created_by');
    const wrIdx = rs.getColumnIndex('window_ref');
    const uaIdx = rs.getColumnIndex('updated_at');
    const csIdx = rs.getColumnIndex('calendar_state');
    const ssIdx = rs.getColumnIndex('sync_state');
    const p: PlanRow = {
      id: rs.getString(rs.getColumnIndex('id')),
      title: rs.getString(rs.getColumnIndex('title')),
      kind: rs.getString(rs.getColumnIndex('kind')),
      status: rs.getString(rs.getColumnIndex('status')),
      createdBy: rs.isColumnNull(cbIdx) ? 'ME' : rs.getString(cbIdx),
      windowRef: rs.isColumnNull(wrIdx) ? '' : rs.getString(wrIdx),
      start: rs.getLong(rs.getColumnIndex('start_min')),
      end: rs.getLong(rs.getColumnIndex('end_min')),
      conflictHint: rs.isColumnNull(hintIdx) ? '' : rs.getString(hintIdx),
      myEventId: rs.isColumnNull(evIdx) ? '' : rs.getString(evIdx),
      reminderId: rs.isColumnNull(ridIdx) ? -1 : rs.getLong(ridIdx),
      updatedAt: rs.isColumnNull(uaIdx) ? 0 : rs.getLong(uaIdx),
      calendarState: rs.isColumnNull(csIdx) ? 'NOT_REQUESTED' : rs.getString(csIdx),
      syncState: rs.isColumnNull(ssIdx) ? 'LOCAL_ONLY' : rs.getString(ssIdx)
    };
    return p;
  }

  // ---------- 窗口缓存 ----------

  /**
   * 全量覆盖窗口缓存：tags 以 '|' 连接入单列，channel/computedAt 各自成列。
   * channel 只透传引擎写入的值，仓储不从 tags 反推通道。
   *
   * 写入顺序是"先插新、后清旧"，整批再包在一个事务里，两件事都为同一类故障服务（D-24 现象一）：
   * 冷启动时首页的那一次读会和这一路覆盖交错进行，先 DELETE 会在两步之间留下一个"零行"的瞬间，
   * 读到的那一帧就把「今晚没有空档」当成事实念出来；且因为每行都自带本次 computed_at，
   * "缓存为空或过期"那道判据拦不住它（有几行就已经是今天的了）。
   * 主键是 (start_min, end_min)，INSERT OR REPLACE 原地覆盖，中间态只会是新旧行的并集，
   * 不会重复计数；进程在写完前被杀时事务整批回滚，留下的仍是上一版完整缓存而不是半截视界。
   */
  static async replaceWindows(windows: Window[], computedAt: number): Promise<void> {
    const s = Db.get();
    await ScheduleRepo.runInTransaction(async (): Promise<void> => {
      for (let i = 0; i < windows.length; i++) {
        const w = windows[i];
        const sql = `INSERT OR REPLACE INTO computed_window
          (start_min, end_min, duration_min, tags, computed_at, channel) VALUES (?, ?, ?, ?, ?, ?)`;
        await s.executeSql(sql,
          [w.start, w.end, w.durationMin, w.tags.join('|'), computedAt, w.channel]);
      }
      await s.executeSql('DELETE FROM computed_window WHERE computed_at < ?', [computedAt]);
    });
  }

  /** 窗口缓存，按开始时间升序；tags 还原为数组，channel 原样返回。 */
  static async listWindows(): Promise<Window[]> {
    const pred = new relationalStore.RdbPredicates('computed_window');
    pred.orderByAsc('start_min');
    const rs = await Db.get().query(pred);
    const out: Window[] = [];
    while (rs.goToNextRow()) {
      const tagsText = rs.getString(rs.getColumnIndex('tags'));
      const chIdx = rs.getColumnIndex('channel');
      const w: Window = {
        start: rs.getLong(rs.getColumnIndex('start_min')),
        end: rs.getLong(rs.getColumnIndex('end_min')),
        durationMin: rs.getLong(rs.getColumnIndex('duration_min')),
        tags: tagsText === '' ? [] : tagsText.split('|'),
        channel: channelOf(rs.isColumnNull(chIdx) ? '' : rs.getString(chIdx))
      };
      out.push(w);
    }
    rs.close();
    return out;
  }

  /**
   * 窗口缓存的生成时刻（ms）；缓存为空返回 0。
   * MAX() 在空表上仍返回一行 NULL，必须先判空列再取值。
   */
  static async windowCacheComputedAt(): Promise<number> {
    const rs = await Db.get().querySql('SELECT MAX(computed_at) AS computed_at FROM computed_window');
    let v = 0;
    if (rs.goToNextRow() && !rs.isColumnNull(0)) {
      v = rs.getLong(0);
    }
    rs.close();
    return v;
  }

  // ---------- 同步元数据 ----------

  static async setMeta(k: string, v: string): Promise<void> {
    await Db.get().executeSql('INSERT OR REPLACE INTO sync_meta (k, v) VALUES (?, ?)', [k, v]);
  }

  static async getMeta(k: string): Promise<string> {
    const rs = await Db.get().querySql('SELECT v FROM sync_meta WHERE k = ?', [k]);
    let v = '';
    if (rs.goToNextRow()) {
      v = rs.getString(rs.getColumnIndex('v'));
    }
    rs.close();
    return v;
  }
}
