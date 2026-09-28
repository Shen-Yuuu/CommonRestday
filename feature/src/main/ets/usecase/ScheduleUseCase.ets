import {
  CommonFreeResult, ConflictOutcome, ConflictSources, EngineInput,
  EngineParams, Interval, MIN_PER_DAY, MySchedule, OWNER_ME, OWNER_PARTNER, PartnerSchedule,
  PlanBlock, PlanLite, ScheduleOverride, SectionTime, ShiftType, SnapshotBuilder, SnapshotCodec,
  Window, buildAvailability, decodeConflictHint, defaultParams, detectConflicts,
  encodeConflictHint, hintFromOutcome, mergeIntervals, mkIv, todayEpochDay, unionIntervals,
  withKeepCarried
} from 'domain';
import { PAIRED, PartnerProfile, ScheduleRepo, SettingsStore } from 'data';
import {
  aadOf, AgcSnapshotSync, CloudApiError, newRequestId, PairKeyStore,
  partnerIntervalsFromSnapshot, SNAPSHOT_SCHEMA_VERSION
} from 'cloud';
import { FeatureFlags } from '../config/FeatureFlags';
import {
  decodeSyncState, encodeSyncState, outcomeOfFailure, pushBlockedToday,
  SYNC_CODE_LOCAL, SYNC_STATE_OK
} from '../model/CloudSyncRules';
import { RecomputeExecutor } from '../performance/RecomputeExecutor';
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
  /** 与当日有交叠的共同窗口（来自重算缓存，含 channel/tags 完整语义）。 */
  windows: Window[];
  /** 我的不可用时间轴（真忙 + 睡眠/缓冲，与伴侣 notAvailable 同构）。画"这段时间不能安排"用它。 */
  myBusy: Interval[];
  /** 对方不可用时间轴；单人模式为 null。 */
  partnerBusy: Interval[] | null;
  /**
   * 我的"真忙"（班次 + 课程 + 计划 + 夜班恢复），不含作息与收整。
   * 说"忙碌"的文案必须读这份：myBusy 里落在作息窗口内的块会被并进 SLEEP，
   * 读文案时按 SLEEP 跳过，一段真实的计划或班次就说成了"全天空闲"（D-03）。
   */
  myTrueBusy: Interval[];
  /** 对方与 myTrueBusy 同口径的集合；无对方数据为 null。 */
  partnerTrueBusy: Interval[] | null;
  /** 'LOCAL' | 'SNAPSHOT'；无伴侣时为 'NONE'。 */
  partnerSource: string;
  /** 对方隐私等级（LOCAL 恒 3）；无伴侣时为 0。 */
  partnerShareLevel: number;
}

/** 重算计数广播键（UI 页面 @Monitor/AppStorage 订阅刷新）。 */
export const RECOMPUTE_COUNT_KEY = 'recomputeCount';

/**
 * 钟点广播键（K-4③）：回前台与切页时自增一次，让"现在"这类钟点读数重新取值。
 * 与 recomputeCount 分开，是因为它不代表任何数据变化——订阅它的只有需要看钟的界面，
 * 挂到重算键上会把六页的 RDB 读全部触发一遍。
 */
export const CLOCK_TICK_KEY = 'crdClockTick';

/** 合并同步窗口（协议 §7）：同一窗口内的多次触发只推送一次最新版本。 */
const SYNC_MERGE_WINDOW_MS = 5000;

/** 班表用例层：仓库 → 领域引擎 的装配与编排。 */
export class ScheduleUseCase {
  /** 挂起中的合并同步定时器 id；-1 = 没有排在路上的推送。 */
  private static syncTimer: number = -1;

  /** 首次使用时写入内置班次类型（按 owner 维度各自种子一份，双侧体验一致）。 */
  static async ensureSeeded(owner: string = OWNER_ME): Promise<void> {
    const existing = await ScheduleRepo.listShiftTypes(owner);
    if (existing.length > 0) {
      return;
    }
    const seeds: ShiftType[] = [
      ScheduleUseCase.mkType('day', '白班', '#EF6F42', 540, 1080, false, 30, 30, 0),
      ScheduleUseCase.mkType('early', '早班', '#4E97DB', 420, 900, false, 30, 30, 0),
      ScheduleUseCase.mkType('mid', '中班', '#9A6BDC', 660, 1140, false, 20, 20, 0),
      ScheduleUseCase.mkType('late', '晚班', '#F0568C', 900, 1380, false, 20, 30, 0),
      ScheduleUseCase.mkType('night', '夜班', '#5B6ACF', 1350, 480, true, 20, 40, 360),
      ScheduleUseCase.mkType('train', '培训', '#3A9E6E', 540, 720, false, 20, 20, 0)
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
    // 引擎段的线程归属由实测预算决定（内联 / TaskPool），见 performance/RecomputeExecutor
    const result = await RecomputeExecutor.compute(input);
    await ScheduleRepo.replaceWindows(result.windows, Date.now());
    // 冲突检测回写（排除计划自身占用的交叠判定 + 替代窗口推荐）
    await ScheduleUseCase.detectAndWriteConflicts(my, partnerIvs, params, startEpochDay, result.windows);
    // 记录重算日（App 切前台时据此做日切重算；失败不影响主流程）
    try {
      await SettingsStore.setLastRecomputeDay(startEpochDay);
    } catch (e) {
      Logger.warn('ScheduleUseCase', 'setLastRecomputeDay failed: ' + (e as Error).message);
    }
    // engineMs 是引擎自己掐的表（走 TaskPool 时是工作线程上的耗时）；
    // 主线程这一帧实际被占了多久，看 RecomputeExecutor 打的 PERF 行。
    Logger.info('ScheduleUseCase', 'recomputed windows=' + result.windows.length
      + ' fullDays=' + result.fullDays.length + ' partner=' + (partnerBusy != null)
      + ' engineMs=' + result.computeMs);
    return result;
  }
  /**
   * 装配伴侣忙区间（"伴侣不可用"语义，与我的 notAvailable 同构）：
   * - 云端快照路径：已配对且 pairId/密钥就绪时先拉快照解密（快照已含对方缓冲，不二次加缓冲）；
   *   没有新版本/云端不可用/解密失败一律退回**本机缓存的最后一次有效快照**（协议 §2 规则 3），
   *   连缓存都没有才继续降级本机代录；
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
   * 拉取并解密对方快照：
   * 开关关闭 / 未配对 / HUKS 里没有本配对的协商密钥 / 云端不可用 / 解密或解码失败一律静默降级，
   * 降级顺序是"沿用最后一次有效快照 → 本机代录"（协议 §2 规则 3、§7 的解密失败行），不抛异常。
   *
   * "没有协商密钥"是换机与卸载后的常态，不是错误：它意味着必须重新配对，重试没有意义。
   */
  static async pullPartnerSnapshot(): Promise<PartnerBusyResult | null> {
    // 关闭态第一道：一条云请求都不发（阶段 6R.2）。档位在 source 里，编译期就翻不出来。
    if (!FeatureFlags.cloudPairing) {
      return null;
    }
    const pairId = SettingsStore.getPairId();
    try {
      if (pairId === '' || !await PairKeyStore.hasPairKey(pairId)) {
        return null;
      }
      const sync = new AgcSnapshotSync();
      const snap = await sync.getSnapshot(pairId, await SettingsStore.getOrCreateUid(),
        SettingsStore.getPartnerSnapVer());
      // 走到这里这次云往返是通的：把可能挂着的降级结论清回「已同步」。
      // "没有更新"（snap 缺席）也算通——协议 §4.8 明说那是常态，不是失败。
      ScheduleUseCase.noteSyncOk();
      if (snap != null) {
        const ivs = await partnerIntervalsFromSnapshot(snap, pairId);
        if (ivs == null) {
          Logger.warn('ScheduleUseCase', 'snapshot decrypt/decode failed');
          // 解密/解码炸了不是网络问题，重试同一份只会再炸一次：按不可重试落「已降级」（协议 §7 的解密失败行）
          ScheduleUseCase.noteSyncFailure(new Error('SNAPSHOT_UNDECODEABLE'));
          return await ScheduleUseCase.cachedPartnerBusy(pairId);
        }
        // 先落信封再进游标：反过来的话一次崩溃就是"游标前进了、这一版却再也拉不回来"（服务端按版本过滤，不重发）
        await SettingsStore.setPartnerSnapCache(JSON.stringify(snap));
        await SettingsStore.setPartnerSnapVer(snap.version);
        return ScheduleUseCase.snapshotResult(ivs, snap.shareLevel);
      }
    } catch (e) {
      // CloudApiError（网络/配额/服务端语义码）等：云端路径不可用，静默沿用最后一次有效快照
      Logger.warn('ScheduleUseCase', 'pull snapshot degraded: ' + (e as Error).message);
      ScheduleUseCase.noteSyncFailure(e);
    }
    return await ScheduleUseCase.cachedPartnerBusy(pairId);
  }

  /**
   * 这一趟没有新快照时的兜底：把本地缓存的**最后一次有效信封**重新解密出来。
   *
   * 少了这一步，"无更新"这条常态路径会让游标前进之后的每一次重算/日视图都退回本机代录；
   * 两台设备都没代录数据时，就是 TA 的数据凭空消失（§11 第 2 条取证撞上）。
   * 信封里带着 pairId，所以上一轮配对的残留会在下一行被挡掉，不跨配对复用。
   * 这里是整条链路的最后一级，往下没有可退的口径，所以它自己一颗异常都不许抛。
   */
  private static async cachedPartnerBusy(pairId: string): Promise<PartnerBusyResult | null> {
    const raw = SettingsStore.getPartnerSnapCache();
    if (raw === '' || pairId === '') {
      return null;
    }
    try {
      // 回读走与网络回包同一个解析器（字段完整性 + 版本门），避免两套口径漂
      const snap = AgcSnapshotSync.parseSnapshot(raw, pairId, 0);
      if (snap == null || snap.pairId !== pairId) {
        return null;
      }
      const ivs = await partnerIntervalsFromSnapshot(snap, pairId);
      if (ivs == null) {
        Logger.warn('ScheduleUseCase', 'cached snapshot undecryptable');
        return null;
      }
      Logger.info('ScheduleUseCase', 'partner busy from cached snapshot v' + snap.version);
      return ScheduleUseCase.snapshotResult(ivs, snap.shareLevel);
    } catch (e) {
      Logger.warn('ScheduleUseCase', 'cached snapshot rejected: ' + (e as Error).message);
      return null;
    }
  }

  /**
   * 解码后的对方区间 → 装配结果。快照产出时已并入对方缓冲，接收侧不再二次加缓冲；
   * 剥离 SLEEP 段得到"不含睡眠"不可用（L1 位图解码后标签全为 BUSY，剥离结果仍含睡眠
   * → 引擎侧同休日/旅行判定自然保守）。
   */
  private static snapshotResult(ivs: Interval[], shareLevel: number): PartnerBusyResult {
    const r: PartnerBusyResult = {
      busy: ivs,
      tripBusy: ivs.filter((iv: Interval) => iv.tag !== 'SLEEP'),
      source: 'SNAPSHOT',
      shareLevel: shareLevel
    };
    return r;
  }

  /**
   * 构建并加密推送我的快照（我的 shareLevel + 单调递增版本）。
   * 全链路 try-catch：开关关闭/未配对/HUKS 无密钥/AGC 未就绪/加密失败均静默返回 false，绝不影响本机主流程。
   */
  static async pushMySnapshot(startEpochDay: number): Promise<boolean> {
    if (!FeatureFlags.cloudPairing) {
      return false;
    }
    try {
      const pairId = SettingsStore.getPairId();
      if (pairId === '' || !await PairKeyStore.hasPairKey(pairId)) {
        return false;
      }
      const uid = await SettingsStore.getOrCreateUid();
      const params = SettingsStoreParams();
      const my = await ScheduleUseCase.loadMySchedule(startEpochDay, params, OWNER_ME);
      const shareLevel = SettingsStore.getShareLevel();
      const version = await SettingsStore.nextSnapshotVersion();
      const data = SnapshotBuilder.build(my, params, startEpochDay, shareLevel, version);
      // 密文在 HUKS 内产出，端上任何一处都不曾持有密钥；AAD 绑住"这条快照属于这个配对+这个 uid+这个版本"
      const payload = await PairKeyStore.seal(pairId,
        aadOf(pairId, uid, version, SNAPSHOT_SCHEMA_VERSION), SnapshotCodec.encode(data));
      const stored = await new AgcSnapshotSync().putSnapshot(pairId, uid, version, shareLevel, payload, newRequestId());
      Logger.info('ScheduleUseCase', 'snapshot pushed v' + version + ' level=' + shareLevel
        + ' stored=' + stored);
      ScheduleUseCase.noteSyncOk();
      return true;
    } catch (e) {
      Logger.warn('ScheduleUseCase', 'push snapshot degraded: ' + (e as Error).message);
      ScheduleUseCase.noteSyncFailure(e);
      return false;
    }
  }

  /**
   * 把一次云端失败写进三态（协议 §3.4：`retryable` → 待重试，其余 → 已降级）。
   * 语义码只用来挑文案，不显示给用户；不是 `CloudApiError` 的（HUKS 拒绝、解密/解码炸了）
   * 按不可重试处理，并记成 `LOCAL` 那一格——§7 给那三行开的处置是"提示重新配对"，
   * 兜底那句（"不是网络问题"）说不到点上。
   */
  private static noteSyncFailure(e: Object): void {
    const err = e as CloudApiError;
    const isCloud = err.name === 'CloudApiError';
    ScheduleUseCase.writeSyncState(outcomeOfFailure(isCloud && err.retryable),
      isCloud ? err.semantic : SYNC_CODE_LOCAL);
  }

  /**
   * 一次**通了**的云往返把结论清回「已同步」——这是「已降级」唯一的自愈出口：
   * 不可重试的失败不排任何重试，只有下一次按需拉成功才说明云端真的活了。
   *
   * 已经在「已同步」时一个字节都不写。拉是高频路径（首页、共同时间、冲突解释都走它），
   * 每次成功都 flush 一遍偏好，等于把只读的计算路径接到磁盘上。
   */
  private static noteSyncOk(): void {
    let raw = '';
    try {
      raw = SettingsStore.getCloudSyncState();
    } catch (e) {
      // 偏好没就绪：这一次没什么可清的，写入也一样会失败
      return;
    }
    if (decodeSyncState(raw).outcome === SYNC_STATE_OK) {
      return;
    }
    ScheduleUseCase.writeSyncState(SYNC_STATE_OK, '');
  }

  /**
   * 三态落偏好：写失败只留一行 warn——它只是界面的一条提示条与当天的排程依据，
   * 绝不允许因为它把本机主流程带崩（门禁 §4 第 4 条：云端任何失败都不得阻断本机）。
   */
  private static writeSyncState(outcome: string, code: string): void {
    SettingsStore.setCloudSyncState(encodeSyncState(outcome, todayEpochDay(), code)).catch((e: Error) => {
      Logger.warn('ScheduleUseCase', 'sync state write failed: ' + e.message);
    });
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

  /** 冲突检测并回写 plan 状态与 conflict_hint（原因码 + 受影响区间 + 替代窗口起止）。 */
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
    // 归因要分侧的区间：并集在合并时只留先到的 tag，事后无从还原"是你的课还是 TA 的班"。
    const sources: ConflictSources = { my: myAvail.notAvailable, partner: partnerBusy };
    const planLites: PlanLite[] = [];
    for (let i = 0; i < planRows.length; i++) {
      const lite: PlanLite = { id: planRows[i].id, startMin: planRows[i].start, endMin: planRows[i].end };
      planLites.push(lite);
    }
    const outcomes = detectConflicts(planLites, busyUnion, windows, sources);
    for (let i = 0; i < outcomes.length; i++) {
      const oc = outcomes[i];
      const newStatus = oc.conflict ? 'CONFLICT' : 'OK';
      const newHint = ScheduleUseCase.conflictHintOf(oc, planRows[i].conflictHint);
      const row = planRows[i];
      if (row.status !== newStatus || row.conflictHint !== newHint) {
        await ScheduleRepo.updatePlanConflict(oc.planId, newStatus, newHint);
        // 内存行跟着落库结果走，调用方读到的状态与数据库是同一份事实
        row.status = newStatus;
        row.conflictHint = newHint;
      }
    }
  }

  /**
   * conflict_hint 文本：无冲突写空串，有冲突写结构化的原因码/来源/受影响区间/替代窗口。
   * "保留原计划"的确认标记只在冲突签名（原因 + 受影响区间）没变时结转——
   * 日程又动了一次就是新冲突，不能拿上一次那句"算了"替用户决定。
   */
  static conflictHintOf(oc: ConflictOutcome, previousHint: string): string {
    if (!oc.conflict) {
      return '';
    }
    return encodeConflictHint(
      withKeepCarried(hintFromOutcome(oc, false), decodeConflictHint(previousHint)));
  }

  /**
   * UI 保存动作后的统一事件入口：重算 + AppStorage 重算计数广播 + 排一次合并同步。
   * 页面通过 AppStorage 监听 recomputeCount 变化刷新（毫秒级同步计算，无需发布订阅）。
   */
  static async onScheduleChanged(): Promise<void> {
    await ScheduleUseCase.recompute(todayEpochDay());
    const cur: number = AppStorage.get<number>(RECOMPUTE_COUNT_KEY) ?? 0;
    AppStorage.setOrCreate<number>(RECOMPUTE_COUNT_KEY, cur + 1);
    ScheduleUseCase.scheduleMergedSync();
  }

  /**
   * 下拉刷新的统一动作：重算一遍视界，然后广播让各页重读读模型。
   *
   * 重算本身就是"同步"：已配对时 recompute → buildPartnerBusy → pullPartnerSnapshot 会带着本机
   * 游标去云上要新版本、解出对方的忙碌再参与本轮计算。所以在共同时间页下拉一次就能看到对方刚改的
   * 班表，不必退回后台再切回来等回前台那一次。
   *
   * 与 onScheduleChanged 只差一步：这里不排推送。下拉时本机数据没有变化，而快照版本是本机单调游标、
   * 云函数按天计费——每拉一次就推一版，烧的是配额，换不来任何新数据。
   */
  static async pullToRefresh(): Promise<void> {
    await ScheduleUseCase.recompute(todayEpochDay());
    const cur: number = AppStorage.get<number>(RECOMPUTE_COUNT_KEY) ?? 0;
    AppStorage.setOrCreate<number>(RECOMPUTE_COUNT_KEY, cur + 1);
    // 「现在」那条线也跟着挪一挪：下拉这一次就是用户主动要求重看当下
    ScheduleUseCase.notifyClockTick();
  }

  /**
   * 排一次"合并同步"（协议 §7 触发时机表）：同一 5 秒窗口内的多次触发只推送一次。
   *
   * 合并掉的只是重复调用，不是内容——到点时 `pushMySnapshot` 读的是**当时**的最新班表，
   * 所以用户连改三次班表只花掉一次云配额，推出去的那份仍包含全部三次。
   * 关闭态与未配对（含 PENDING_CONFIRM）一个定时器都不建：触发点可以随便调，档位在这里收口。
   */
  static scheduleMergedSync(): void {
    if (!FeatureFlags.cloudPairing || SettingsStore.getPairState() !== PAIRED) {
      return;
    }
    if (ScheduleUseCase.syncTimer >= 0) {
      return;
    }
    // 协议 §7 末行：可重试的失败**当天不再重排**，不可重试的一直排不动，直到某次拉成功清回「已同步」。
    // 拦在这里而不是 `pushMySnapshot` 里面，是为了让 `nextSnapshotVersion()` 一次都不被消费：
    // 版本号是本机单调游标，白烧一格不写坏数据（§3.3 已经算过这笔），但会让日志里的版本对不上实际落库的那一版。
    // 这里也不排任何"稍后再试"的定时器（§3.3：端侧没有自动退避重试循环）——真正的再试由日切后的下一次保存带起。
    if (pushBlockedToday(SettingsStore.getCloudSyncState(), todayEpochDay())) {
      return;
    }
    ScheduleUseCase.syncTimer = setTimeout(() => {
      ScheduleUseCase.syncTimer = -1;
      ScheduleUseCase.pushMySnapshot(todayEpochDay()).catch(() => {
      });
    }, SYNC_MERGE_WINDOW_MS);
  }

  /** 撤掉挂起中的合并同步：解除配对后不该再有一次推送排在路上。 */
  static cancelMergedSync(): void {
    if (ScheduleUseCase.syncTimer >= 0) {
      clearTimeout(ScheduleUseCase.syncTimer);
      ScheduleUseCase.syncTimer = -1;
    }
  }

  /** 广播一次"重新看钟"：只让钟点读数取值，不读库、不重算（见 CLOCK_TICK_KEY）。 */
  static notifyClockTick(): void {
    const cur: number = AppStorage.get<number>(CLOCK_TICK_KEY) ?? 0;
    AppStorage.setOrCreate<number>(CLOCK_TICK_KEY, cur + 1);
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
    const windows: Window[] = [];
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
      myTrueBusy: avail.trueBusy,
      // tripBusy 就是"剥掉作息的对方忙碌"：出行通道要的正是这份，文案与它同一口径
      partnerTrueBusy: partner != null ? partner.tripBusy : null,
      partnerSource: partner != null ? partner.source : 'NONE',
      partnerShareLevel: partner != null ? partner.shareLevel : 0
    };
    return dv;
  }

  /**
   * 一段时间内"排不开"的区间（真忙 + 收整 + 作息，已合并）：我这半边与
   * detectAndWriteConflicts 归因用的 `sources.my` 同一份口径，所以按它排开的起点不会再被判冲突。
   *
   * 起草器用它把默认起点挪出睡觉时间（D-25）：旅行通道只扣真忙、睡眠算在窗口里，
   * 一段连续休息的窗口起点可以是 00:00，不查这一份就会把"选窗口 → 直接保存"的第一条计划排进被窝里。
   * 天数按视界封住（与引擎同一上限口径），不随窗口长度无限放大。
   *
   * D-28：本机代录态把 TA 的同一份并进来——TA 的精确作息本来就在手上（partner_profile 三值
   * ＋ owner='PARTNER' 的班表），代录侧不存在隐私障碍，默认起点却会整段落进 TA 的被窝。
   * 云端快照那半边只有粗粒度忙闲（§0.3），仍不替 TA 挪起点，所以判据是"有没有档案"而不是"配没配对"。
   */
  static async unavailableForDraftOver(startEpochMin: number, endEpochMin: number): Promise<Interval[]> {
    const params = SettingsStoreParams();
    const firstDay = Math.floor(startEpochMin / MIN_PER_DAY);
    const lastDay = Math.max(firstDay, Math.ceil(endEpochMin / MIN_PER_DAY) - 1);
    const days = Math.max(1, Math.min(lastDay - firstDay + 1, params.horizonDays));
    const my = await ScheduleUseCase.loadMySchedule(firstDay, params, OWNER_ME);
    const out = buildAvailability(my, params, firstDay, days).notAvailable;
    const profile = SettingsStore.getPartnerProfile();
    if (profile == null) {
      return out;
    }
    const partnerParams = ScheduleUseCase.partnerParamsOf(params, profile);
    const ta = await ScheduleUseCase.loadMySchedule(firstDay, partnerParams, OWNER_PARTNER);
    // 只拼接不合并：firstArrangableStart 取的是相交区间的最大 end，两段各自成段不影响结论
    return out.concat(buildAvailability(ta, partnerParams, firstDay, days).notAvailable);
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
