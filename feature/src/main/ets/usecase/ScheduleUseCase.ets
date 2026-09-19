import {
  CommonFreeEngine, CommonFreeResult, ConflictOutcome, EngineInput, EngineParams, Interval,
  MIN_PER_DAY, MySchedule, OWNER_ME, OWNER_PARTNER, PartnerSchedule, PlanBlock, PlanLite,
  ScheduleOverride, SectionTime, ShiftType, SnapshotBuilder, SnapshotCodec, Window,
  buildAvailability, defaultParams, detectConflicts, mergeIntervals, mkIv, todayEpochDay, unionIntervals
} from 'domain';
import { PAIRED, PartnerProfile, ScheduleRepo, SettingsStore } from 'data';
import { AgcSnapshotSync, SnapshotCrypto, partnerIntervalsFromSnapshot } from 'cloud';
import { notificationManager } from '@kit.NotificationKit';
import { reminderAgentManager } from '@kit.BackgroundTasksKit';
import { AppConst, Logger } from 'commons';

/** 学期配置。 */
export interface TermConfig {
  termStart: number;
  sectionTimes: SectionTime[];
}

/** 伴侣忙区间装配结果：忙碌集合 + 数据来源与隐私等级（供 UI 按来源/等级差异化渲染）。 */
export interface PartnerBusyResult {
  busy: Interval[];
  /** "不含睡眠"的不可用（忙碌块+收整，已合并）：完整同休日/旅行判定专用。 */
  tripBusy: Interval[];
  /** 'LOCAL' = 本机代录（全量细节）；'SNAPSHOT' = 云端加密快照（按对方 shareLevel 降维）。 */
  source: string;
  /** 对方数据隐私等级（1/2/3）；本机代录恒为 3。 */
  shareLevel: number;
}

/** 日视图数据（DayDetailSheet）：当日窗口 + 双方忙碌时间轴。 */
export interface DayViewData {
  epochDay: number;
  /** 与当日有交叠的共同窗口（来自重算缓存）。 */
  windows: Interval[];
  /** 我的不可用时间轴（真忙 + 睡眠/缓冲，与伴侣 notAvailable 同构）。 */
  myBusy: Interval[];
  /** 对方不可用时间轴；单人模式为 null。 */
  partnerBusy: Interval[] | null;
  /** 'LOCAL' | 'SNAPSHOT'；无伴侣时为 'NONE'。 */
  partnerSource: string;
  /** 对方隐私等级（LOCAL 恒 3）；无伴侣时为 0。 */
  partnerShareLevel: number;
}

/** 重算计数广播键（UI 页面 @Monitor/AppStorage 订阅刷新）。 */
export const RECOMPUTE_COUNT_KEY = 'recomputeCount';

/** 班表用例层：仓库 → 领域引擎 的装配与编排。 */
export class ScheduleUseCase {
  /** 首次使用时写入内置班次类型（按 owner 维度各自种子一份，双侧体验一致）。 */
  static async ensureSeeded(owner: string = OWNER_ME): Promise<void> {
    const existing = await ScheduleRepo.listShiftTypes(owner);
    if (existing.length > 0) {
      return;
    }
    const seeds: ShiftType[] = [
      ScheduleUseCase.mkType('day', '白班', '#E8833A', 540, 1080, false, 30, 30, 0),
      ScheduleUseCase.mkType('early', '早班', '#3AA6E8', 420, 900, false, 30, 30, 0),
      ScheduleUseCase.mkType('mid', '中班', '#8A63D2', 660, 1140, false, 20, 20, 0),
      ScheduleUseCase.mkType('late', '晚班', '#D24A7E', 900, 1380, false, 20, 30, 0),
      ScheduleUseCase.mkType('night', '夜班', '#2B4C9B', 1350, 480, true, 20, 40, 360),
      ScheduleUseCase.mkType('train', '培训', '#4E9A63', 540, 720, false, 20, 20, 0)
    ];
    for (let i = 0; i < seeds.length; i++) {
      // owner 必须透传：否则伴侣侧首次进入会把种子写入 ME 侧，反复覆写"我"的同 id 班次类型
      await ScheduleRepo.upsertShiftType(seeds[i], owner);
    }
    Logger.info('ScheduleUseCase', 'seeded default shift types');
  }

  static mkType(id: string, name: string, color: string, startMin: number, endMin: number,
    crossDay: boolean, cin: number, cout: number, recovery: number): ShiftType {
    const st: ShiftType = {
      id: id, name: name, color: color,
      startMin: startMin, endMin: endMin, crossDay: crossDay,
      commuteInMin: cin, commuteOutMin: cout,
      recoveryMin: recovery, nightMode: 0,
      allowActivity: false, kind: 'WORK'
    };
    return st;
  }

  /**
   * 装配任意一方（owner = 'ME' | 'PARTNER'）的领域引擎输入（本机全量细节）。
   * 共同计划为双方共享，仅在 ME 侧计入占用（并集语义不变）；伴侣侧 plans 恒为空。
   */
  static async loadMySchedule(startEpochDay: number, params: EngineParams,
    owner: string = OWNER_ME): Promise<MySchedule> {
    const shiftTypes = await ScheduleRepo.listShiftTypes(owner);
    const template = await ScheduleRepo.getTemplate(owner);
    const overrides: ScheduleOverride[] =
      await ScheduleRepo.listOverrides(startEpochDay, startEpochDay + params.horizonDays - 1, owner);
    const courses = await ScheduleRepo.listCourses(owner);
    const termStart = await ScheduleRepo.getTermStart();
    // term_config.section_times 读取接线：有保存值则用保存值，否则回退默认节次模板
    const sectionTimes = ScheduleUseCase.sectionTimesFromJson(await ScheduleRepo.getSectionTimes());
    const plans: PlanBlock[] = [];
    if (owner === OWNER_ME) {
      const planRows = await ScheduleRepo.listActivePlans();
      for (let i = 0; i < planRows.length; i++) {
        plans.push({ start: planRows[i].start, end: planRows[i].end });
      }
    }
    const my: MySchedule = {
      shiftTypes: shiftTypes,
      template: template,
      overrides: overrides,
      courses: courses,
      sectionTimes: sectionTimes,
      termStartEpochDay: termStart,
      plans: plans,
      wakeMin: params.wakeMin,
      bedMin: params.bedMin,
      windDownMin: params.windDownMin
    };
    return my;
  }

  /** 重算并落缓存；有伴侣数据时装配伴侣忙区间，无伴侣时 partner 为空（"我的空闲"语义）。 */
  static async recompute(startEpochDay: number): Promise<CommonFreeResult> {
    const params = SettingsStoreParams();
    const my = await ScheduleUseCase.loadMySchedule(startEpochDay, params, OWNER_ME);
    const partnerBusy = await ScheduleUseCase.buildPartnerBusy(startEpochDay, params);
    const partner: PartnerSchedule | null = partnerBusy != null
      ? {
        shareLevel: partnerBusy.shareLevel,
        busyIntervals: partnerBusy.busy,
        tripBusyIntervals: partnerBusy.tripBusy
      }
      : null;
    const partnerIvs = partnerBusy != null ? partnerBusy.busy : null;
    const input: EngineInput = {
      my: my,
      partner: partner,
      params: params,
      horizonStartEpochDay: startEpochDay
    };
    const result = CommonFreeEngine.compute(input);
    const ivs: Interval[] = [];
    for (let i = 0; i < result.windows.length; i++) {
      const w = result.windows[i];
      const iv: Interval = { start: w.start, end: w.end, tag: w.tags.join('|') };
      ivs.push(iv);
    }
    await ScheduleRepo.replaceWindows(ivs);
    // 冲突检测回写（排除计划自身占用的交叠判定 + 替代窗口推荐）
    await ScheduleUseCase.detectAndWriteConflicts(my, partnerIvs, params, startEpochDay, result.windows);
    Logger.info('ScheduleUseCase', 'recomputed windows=' + result.windows.length
      + ' fullDays=' + result.fullDays.length + ' partner=' + (partnerBusy != null) + ' in ' + result.computeMs + 'ms');
    return result;
  }
  /**
   * 装配伴侣忙区间（"伴侣不可用"语义，与我的 notAvailable 同构）：
   * - 云端快照路径：已配对且 pairId/密钥就绪时先拉快照解密（快照已含对方缓冲，不二次加缓冲）；
   *   AGC 未就绪/解密失败一律返回 null 静默降级，走本机代录；
   * - 本机代录路径：存在伴侣档案或 owner='PARTNER' 有任何班表数据时，
   *   用伴侣自己的班表 + 伴侣参数走与"我"完全相同的 expand → buffer 管线；
   * - 两者皆无 → 返回 null（单人模式）。
   */
  static async buildPartnerBusy(startEpochDay: number,
    myParams: EngineParams): Promise<PartnerBusyResult | null> {
    const pairState = SettingsStore.getPairState();
    if (pairState === PAIRED) {
      const fromCloud = await ScheduleUseCase.pullPartnerSnapshot();
      if (fromCloud != null) {
        Logger.info('ScheduleUseCase', 'partner busy from snapshot, level=' + fromCloud.shareLevel);
        return fromCloud;
      }
      Logger.warn('ScheduleUseCase', 'snapshot unavailable, fallback to local partner data');
    }
    const profile = SettingsStore.getPartnerProfile();
    const hasRows = await ScheduleUseCase.hasPartnerScheduleData(startEpochDay);
    if (profile == null && !hasRows) {
      return null;
    }
    const partnerParams = ScheduleUseCase.partnerParamsOf(myParams, profile);
    const partnerSched = await ScheduleUseCase.loadMySchedule(startEpochDay, partnerParams, OWNER_PARTNER);
    const days = Math.max(1, Math.min(partnerParams.horizonDays, 366));
    const avail = buildAvailability(partnerSched, partnerParams, startEpochDay, days);
    // 本机代录可拿到全量细节：从真忙+收整重建"不含睡眠"不可用（避免合并吞标签的边缘情形）
    const tripBusy = mergeIntervals(avail.trueBusy.map((iv: Interval): Interval => {
      return mkIv(iv.start, iv.end + partnerParams.windDownMin, iv.tag);
    }));
    const r: PartnerBusyResult = {
      busy: avail.notAvailable,
      tripBusy: tripBusy,
      source: 'LOCAL',
      shareLevel: 3
    };
    return r;
  }

  /**
   * 拉取并解密对方快照（AGC 就绪后生效）：
   * 未配对/密钥缺失/云端不可用/解密或解码失败一律返回 null（调用方降级本机代录），不抛异常。
   */
  static async pullPartnerSnapshot(): Promise<PartnerBusyResult | null> {
    try {
      const pairId = SettingsStore.getPairId();
      const keyHex = await SettingsStore.getPairKey();
      if (pairId === '' || keyHex === '') {
        return null;
      }
      const sync = new AgcSnapshotSync();
      const snap = await sync.pullSnapshot(pairId, SettingsStore.getPartnerSnapVer());
      if (snap == null) {
        return null;
      }
      const ivs = partnerIntervalsFromSnapshot(snap, keyHex);
      if (ivs == null) {
        Logger.warn('ScheduleUseCase', 'snapshot decrypt/decode failed');
        return null;
      }
      await SettingsStore.setPartnerSnapVer(snap.version);
      // 快照分段已含对方缓冲；剥离 SLEEP 段得到"不含睡眠"不可用
      // （L1 位图解码后标签全为 BUSY，剥离结果仍含睡眠 → 引擎侧同休日/旅行判定自然保守）
      const tripIvs = ivs.filter((iv: Interval) => iv.tag !== 'SLEEP');
      const r: PartnerBusyResult = {
        busy: ivs,
        tripBusy: tripIvs,
        source: 'SNAPSHOT',
        shareLevel: snap.shareLevel
      };
      return r;
    } catch (e) {
      // CloudApiError(1001/1002) 等：云端路径不可用，静默降级本机代录
      Logger.warn('ScheduleUseCase', 'pull snapshot degraded: ' + (e as Error).message);
      return null;
    }
  }

  /**
   * 构建并加密推送我的快照（我的 shareLevel + 单调递增版本）。
   * 全链路 try-catch：未配对/AGC 未就绪/加密失败均静默返回 false，绝不影响本机主流程。
   */
  static async pushMySnapshot(startEpochDay: number): Promise<boolean> {
    try {
      const pairId = SettingsStore.getPairId();
      const keyHex = await SettingsStore.getPairKey();
      if (pairId === '' || keyHex === '') {
        return false;
      }
      const params = SettingsStoreParams();
      const my = await ScheduleUseCase.loadMySchedule(startEpochDay, params, OWNER_ME);
      const shareLevel = SettingsStore.getShareLevel();
      const version = await SettingsStore.nextSnapshotVersion();
      const data = SnapshotBuilder.build(my, params, startEpochDay, shareLevel, version);
      const payload = SnapshotCrypto.encryptWithKey(keyHex, SnapshotCodec.encode(data));
      const sync = new AgcSnapshotSync();
      await sync.pushSnapshot(pairId, version, shareLevel, payload);
      Logger.info('ScheduleUseCase', 'snapshot pushed v' + version + ' level=' + shareLevel);
      return true;
    } catch (e) {
      Logger.warn('ScheduleUseCase', 'push snapshot degraded: ' + (e as Error).message);
      return false;
    }
  }

  /** owner='PARTNER' 是否存在任何班表数据。 */
  static async hasPartnerScheduleData(startEpochDay: number): Promise<boolean> {
    const types = await ScheduleRepo.listShiftTypes(OWNER_PARTNER);
    if (types.length > 0) {
      return true;
    }
    const tpl = await ScheduleRepo.getTemplate(OWNER_PARTNER);
    if (tpl != null) {
      return true;
    }
    const courses = await ScheduleRepo.listCourses(OWNER_PARTNER);
    if (courses.length > 0) {
      return true;
    }
    const overrides = await ScheduleRepo.listOverrides(startEpochDay, startEpochDay + 400, OWNER_PARTNER);
    return overrides.length > 0;
  }

  /** 是否存在伴侣上下文（伴侣档案或任何 owner='PARTNER' 班表数据）——UI 共同/单人双语义切换判断。 */
  static async hasPartnerContext(): Promise<boolean> {
    let hasProfile = false;
    try {
      hasProfile = SettingsStore.getPartnerProfile() != null;
    } catch (e) {
      // SettingsStore 未初始化时仅以班表数据判断
    }
    if (hasProfile) {
      return true;
    }
    return await ScheduleUseCase.hasPartnerScheduleData(todayEpochDay());
  }

  /** 伴侣引擎参数：起床/就寝/收整来自伴侣档案（独立于我的参数），其余沿用全局参数。 */
  static partnerParamsOf(base: EngineParams, profile: PartnerProfile | null): EngineParams {
    const d = defaultParams();
    const p: EngineParams = {
      horizonDays: base.horizonDays,
      wakeMin: profile != null ? profile.wakeMin : d.wakeMin,
      bedMin: profile != null ? profile.bedMin : d.bedMin,
      windDownMin: profile != null ? profile.windDownMin : d.windDownMin,
      nightStartMin: base.nightStartMin,
      nightEndMin: base.nightEndMin,
      minSlotMin: base.minSlotMin,
      halfDayMin: base.halfDayMin,
      fullDayAvailMin: base.fullDayAvailMin,
      overnightMinMin: base.overnightMinMin,
      tripMinMin: base.tripMinMin,
      studyStartMin: base.studyStartMin,
      studyEndMin: base.studyEndMin,
      studyMinMin: base.studyMinMin
    };
    return p;
  }

  /** 返回去除计划占用后的 MySchedule 副本（冲突判定用）。 */
  static withPlans(s: MySchedule, plans: PlanBlock[]): MySchedule {
    const copy: MySchedule = {
      shiftTypes: s.shiftTypes,
      template: s.template,
      overrides: s.overrides,
      courses: s.courses,
      sectionTimes: s.sectionTimes,
      termStartEpochDay: s.termStartEpochDay,
      plans: plans,
      wakeMin: s.wakeMin,
      bedMin: s.bedMin,
      windDownMin: s.windDownMin
    };
    return copy;
  }

  /** 冲突检测并回写 plan 状态与 conflict_hint（含替代窗口起止）。 */
  static async detectAndWriteConflicts(my: MySchedule, partnerBusy: Interval[] | null,
    params: EngineParams, startEpochDay: number, windows: Window[]): Promise<void> {
    const planRows = await ScheduleRepo.listActivePlans();
    if (planRows.length === 0) {
      return;
    }
    const days = Math.max(1, Math.min(params.horizonDays, 366));
    const myAvail = buildAvailability(ScheduleUseCase.withPlans(my, []), params, startEpochDay, days);
    let busyUnion: Interval[] = myAvail.notAvailable;
    if (partnerBusy != null) {
      busyUnion = unionIntervals(busyUnion, partnerBusy);
    }
    const planLites: PlanLite[] = [];
    for (let i = 0; i < planRows.length; i++) {
      const lite: PlanLite = { id: planRows[i].id, startMin: planRows[i].start, endMin: planRows[i].end };
      planLites.push(lite);
    }
    const outcomes = detectConflicts(planLites, busyUnion, windows);
    for (let i = 0; i < outcomes.length; i++) {
      const oc = outcomes[i];
      const newStatus = oc.conflict ? 'CONFLICT' : 'OK';
      const newHint = ScheduleUseCase.conflictHintOf(oc);
      const row = planRows[i];
      if (row.status !== newStatus || row.conflictHint !== newHint) {
        await ScheduleRepo.updatePlanConflict(oc.planId, newStatus, newHint);
      }
    }
  }

  /** conflict_hint 内容：替代窗口起止 JSON；无冲突或无替代时为空串。 */
  static conflictHintOf(oc: ConflictOutcome): string {
    if (!oc.conflict || oc.alternativeStartMin <= 0) {
      return '';
    }
    const hint: Record<string, number> = { 'altStart': oc.alternativeStartMin, 'altEnd': oc.alternativeEndMin };
    return JSON.stringify(hint);
  }

  /**
   * UI 保存动作后的统一事件入口：重算 + AppStorage 重算计数广播。
   * 页面通过 AppStorage 监听 recomputeCount 变化刷新（毫秒级同步计算，无需发布订阅）。
   * 已配对时尽力推送我的加密快照（fire-and-forget，内部全捕获不产生未处理拒绝）。
   */
  static async onScheduleChanged(): Promise<void> {
    await ScheduleUseCase.recompute(todayEpochDay());
    const cur: number = AppStorage.get<number>(RECOMPUTE_COUNT_KEY) ?? 0;
    AppStorage.setOrCreate<number>(RECOMPUTE_COUNT_KEY, cur + 1);
    if (SettingsStore.getPairState() === PAIRED) {
      ScheduleUseCase.pushMySnapshot(todayEpochDay());
    }
    ScheduleUseCase.refreshWeeklyReminder();
  }

  /**
   * 周日 20:00 周摘要提醒（ReminderRequestAlarm）：
   * - 通知未开启时静默跳过（不弹授权窗，避免打断用户）；
   * - 已注册则先取消旧提醒再重注册，reminder id 存 SettingsStore；
   * - 任何失败静默降级，不影响重算主流程。
   */
  static async refreshWeeklyReminder(): Promise<void> {
    try {
      if (!await notificationManager.isNotificationEnabled()) {
        return;
      }
      const old = await SettingsStore.getWeeklyReminderId();
      if (old >= 0) {
        try {
          await reminderAgentManager.cancelReminder(old);
        } catch (e) {
          // 旧提醒已被系统清理/过期：忽略取消失败
        }
      }
      const reminder: reminderAgentManager.ReminderRequestAlarm = {
        reminderType: reminderAgentManager.ReminderType.REMINDER_TYPE_ALARM,
        hour: 20,
        minute: 0,
        daysOfWeek: [7], // 1=周一 … 7=周日
        title: '同休日周报',
        content: '本周共同空闲已更新，打开看看这周能一起休哪天'
      };
      const id = await reminderAgentManager.publishReminder(reminder);
      await SettingsStore.setWeeklyReminderId(id);
      Logger.info('ScheduleUseCase', 'weekly reminder registered, id=' + id);
    } catch (e) {
      Logger.warn('ScheduleUseCase', 'weekly reminder degraded: ' + (e as Error).message);
    }
  }

  // ---------- 日视图（DayDetailSheet 数据源） ----------

  /** 复制引擎参数并替换视界天数（getDayView 单日装配用）。 */
  static dayParamsOf(base: EngineParams, horizonDays: number): EngineParams {
    const p: EngineParams = {
      horizonDays: horizonDays,
      wakeMin: base.wakeMin,
      bedMin: base.bedMin,
      windDownMin: base.windDownMin,
      nightStartMin: base.nightStartMin,
      nightEndMin: base.nightEndMin,
      minSlotMin: base.minSlotMin,
      halfDayMin: base.halfDayMin,
      fullDayAvailMin: base.fullDayAvailMin,
      overnightMinMin: base.overnightMinMin,
      tripMinMin: base.tripMinMin,
      studyStartMin: base.studyStartMin,
      studyEndMin: base.studyEndMin,
      studyMinMin: base.studyMinMin
    };
    return p;
  }

  /**
   * 装配某一天的日视图：当日共同窗口（重算缓存中与该日有交叠的）
   * + 我的不可用时间轴 + 对方不可用时间轴（含来源与隐私等级，UI 据此差异化渲染）。
   */
  static async getDayView(epochDay: number): Promise<DayViewData> {
    const base = SettingsStoreParams();
    const dayParams = ScheduleUseCase.dayParamsOf(base, 1);
    const my = await ScheduleUseCase.loadMySchedule(epochDay, dayParams, OWNER_ME);
    const avail = buildAvailability(my, dayParams, epochDay, 1);
    const partner = await ScheduleUseCase.buildPartnerBusy(epochDay, dayParams);
    const dayStart = epochDay * MIN_PER_DAY;
    const dayEnd = dayStart + MIN_PER_DAY;
    const all = await ScheduleRepo.listWindows();
    const windows: Interval[] = [];
    for (let i = 0; i < all.length; i++) {
      if (all[i].start < dayEnd && all[i].end > dayStart) {
        windows.push(all[i]);
      }
    }
    const dv: DayViewData = {
      epochDay: epochDay,
      windows: windows,
      myBusy: avail.notAvailable,
      partnerBusy: partner != null ? partner.busy : null,
      partnerSource: partner != null ? partner.source : 'NONE',
      partnerShareLevel: partner != null ? partner.shareLevel : 0
    };
    return dv;
  }

  // ---------- 学期与节次 ----------

  /** 默认节次模板：上午 1-4 节 8:00 起、下午 5-8 节 14:00 起、晚上 9-12 节 19:00 起，每节 45+10 分钟。 */
  static defaultSectionTimes(): SectionTime[] {
    const out: SectionTime[] = [];
    const groups: number[][] = [[0, 480], [4, 840], [8, 1140]];
    for (let g = 0; g < groups.length; g++) {
      for (let i = 0; i < 4; i++) {
        const start = groups[g][1] + i * 55;
        const st: SectionTime = { startMin: start, endMin: start + 45 };
        out.push(st);
      }
    }
    return out;
  }

  /** 保存学期配置；times 缺省时写入默认节次模板（保持既有调用兼容）。 */
  static async saveTermConfig(termStart: number, times?: SectionTime[]): Promise<void> {
    const t = times == null || times.length === 0 ? ScheduleUseCase.defaultSectionTimes() : times;
    const json = ScheduleUseCase.sectionTimesToJson(t);
    await ScheduleRepo.saveTermConfig(termStart, json);
  }

  static sectionTimesToJson(times: SectionTime[]): string {
    const parts: string[] = [];
    for (let i = 0; i < times.length; i++) {
      parts.push('[' + times[i].startMin + ',' + times[i].endMin + ']');
    }
    return '[' + parts.join(',') + ']';
  }

  static sectionTimesFromJson(text: string): SectionTime[] {
    const fallback = ScheduleUseCase.defaultSectionTimes();
    if (text === '') {
      return fallback;
    }
    try {
      const arr = JSON.parse(text) as number[][];
      const out: SectionTime[] = [];
      for (let i = 0; i < arr.length; i++) {
        const st: SectionTime = { startMin: arr[i][0], endMin: arr[i][1] };
        out.push(st);
      }
      return out;
    } catch (e) {
      return fallback;
    }
  }
}

/** 引擎参数读取：真实读写 SettingsStore（用户在"我的"页保存后重算即生效）。 */
export function SettingsStoreParams(): EngineParams {
  const p = SettingsStore.getParams();
  if (p.horizonDays <= 0) {
    p.horizonDays = AppConst.HORIZON_DAYS;
  }
  return p;
}
