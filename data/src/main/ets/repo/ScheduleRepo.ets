import { relationalStore } from '@kit.ArkData';
import {
  Course, CycleTemplate, Interval, OWNER_ME, OWNER_PARTNER, PlanBlock, ScheduleOverride, ShiftType
} from 'domain';
import { Db } from '../db/Db';

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
  /** 关联的系统日历日程 id（Calendar Kit 写入成功后记录）；空串表示未写入日历。 */
  myEventId: string;
  /** 关联的本地提醒 id（reminderAgentManager 发布成功后记录）；-1 表示未注册提醒。 */
  reminderId: number;
}

export class ScheduleRepo {
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
       conflict_hint, my_event_id, reminder_id)
      VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`;
    await Db.get().executeSql(sql,
      [p.id, p.title, p.kind, p.start, p.end, p.status, p.createdBy, p.windowRef,
        p.conflictHint, p.myEventId, p.reminderId]);
  }

  /** 回写计划关联的系统日历日程 id（Calendar Kit 写入成功后调用）。 */
  static async updatePlanEventId(id: string, eventId: string): Promise<void> {
    const pred = new relationalStore.RdbPredicates('plan');
    pred.equalTo('id', id);
    const vb: relationalStore.ValuesBucket = { 'my_event_id': eventId };
    await Db.get().update(vb, pred);
  }

  /** 回写计划关联的本地提醒 id（reminderAgentManager 发布成功后调用；-1 表示无提醒）。 */
  static async updatePlanReminder(id: string, reminderId: number): Promise<void> {
    const pred = new relationalStore.RdbPredicates('plan');
    pred.equalTo('id', id);
    const vb: relationalStore.ValuesBucket = { 'reminder_id': reminderId };
    await Db.get().update(vb, pred);
  }

  static async updatePlanStatus(id: string, status: string): Promise<void> {
    const pred = new relationalStore.RdbPredicates('plan');
    pred.equalTo('id', id);
    const vb: relationalStore.ValuesBucket = { 'status': status };
    await Db.get().update(vb, pred);
  }

  /** 改期：更新计划起止（接受冲突替代窗口时调用；状态由重算的冲突检测复核）。 */
  static async updatePlanTime(id: string, start: number, end: number): Promise<void> {
    const pred = new relationalStore.RdbPredicates('plan');
    pred.equalTo('id', id);
    const vb: relationalStore.ValuesBucket = { 'start_min': start, 'end_min': end };
    await Db.get().update(vb, pred);
  }

  /** 冲突检测结果回写：状态 + conflict_hint（替代窗口 JSON，空串表示无冲突/无替代）。 */
  static async updatePlanConflict(id: string, status: string, conflictHint: string): Promise<void> {
    const pred = new relationalStore.RdbPredicates('plan');
    pred.equalTo('id', id);
    const vb: relationalStore.ValuesBucket = { 'status': status, 'conflict_hint': conflictHint };
    await Db.get().update(vb, pred);
  }

  /** 状态非 CANCELLED 的计划，按开始时间升序（含 conflict_hint）。 */
  static async listActivePlans(): Promise<PlanRow[]> {
    const pred = new relationalStore.RdbPredicates('plan');
    pred.notEqualTo('status', 'CANCELLED');
    pred.orderByAsc('start_min');
    const rs = await Db.get().query(pred);
    const out: PlanRow[] = [];
    while (rs.goToNextRow()) {
      const hintIdx = rs.getColumnIndex('conflict_hint');
      const evIdx = rs.getColumnIndex('my_event_id');
      const ridIdx = rs.getColumnIndex('reminder_id');
      const cbIdx = rs.getColumnIndex('created_by');
      const wrIdx = rs.getColumnIndex('window_ref');
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
        reminderId: rs.isColumnNull(ridIdx) ? -1 : rs.getLong(ridIdx)
      };
      out.push(p);
    }
    rs.close();
    return out;
  }

  // ---------- 窗口缓存 ----------

  static async replaceWindows(windows: Interval[]): Promise<void> {
    const s = Db.get();
    await s.executeSql('DELETE FROM computed_window');
    for (let i = 0; i < windows.length; i++) {
      const sql = 'INSERT OR REPLACE INTO computed_window (start_min, end_min, duration_min, tags) VALUES (?, ?, ?, ?)';
      await s.executeSql(sql, [windows[i].start, windows[i].end, windows[i].end - windows[i].start, windows[i].tag]);
    }
  }

  static async listWindows(): Promise<Interval[]> {
    const pred = new relationalStore.RdbPredicates('computed_window');
    pred.orderByAsc('start_min');
    const rs = await Db.get().query(pred);
    const out: Interval[] = [];
    while (rs.goToNextRow()) {
      const iv: Interval = {
        start: rs.getLong(rs.getColumnIndex('start_min')),
        end: rs.getLong(rs.getColumnIndex('end_min')),
        tag: rs.getString(rs.getColumnIndex('tags'))
      };
      out.push(iv);
    }
    rs.close();
    return out;
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
