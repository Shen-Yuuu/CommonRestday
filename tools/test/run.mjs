/**
 * 离线单测入口：把纯逻辑源码（domain + feature 读模型 + 两套 Hypium 用例）转译成
 * CommonJS 后用 Node 跑，给改动一个不需要真机的快速反馈信号。
 *
 *   node tools/test/run.mjs          # 仓库根目录执行
 *   CRD_ONLY=commonTimeQueryService node tools/test/run.mjs   # 只跑一个 describe
 *
 * 退出码：0 类型编译、用例、文案口径审计**都**干净 / 1 有用例失败或文案口径冲突 /
 * 2 环境不满足（缺 tsc）/ 3 类型编译失败。完整输出同时写在 tools/test/out/last-run.log。
 *
 * 只有 `typecheck: 0 errors` + 九条静态口径（`copy`／`a11y`／`landing`／`press`／`contrast`／`horizon`／`endread`／`span`／`clip`）全 PASS
 * + `tests: passed` + 退出码 0 才可以写成"全绿"：
 * 转译有类型错误时不产出 JS、也不启动用例（tsconfig 的 noEmitOnError=true），
 * 所以不存在"用例通过但工程编不过"的假绿。`copy` 见 tools/test/copy-audit.mjs。
 *
 * 注意：这里证明的是"纯装配与计算逻辑"，不覆盖 @kit/RDB/Preferences/云调用与渲染；
 * 那些仍由 DevEco 的 ohosTest（真机 Instrument Test）负责。
 */
import fs from 'node:fs';
import path from 'node:path';
import { spawnSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';
import { auditPrivacyCopy } from './copy-audit.mjs';
import { auditAccessibility } from './a11y-audit.mjs';
import { auditLanding } from './landing-audit.mjs';
import { auditPress } from './press-audit.mjs';
import { auditContrast } from './contrast-audit.mjs';
import { auditHorizonCeiling } from './horizon-audit.mjs';
import { auditEndRead } from './endread-audit.mjs';
import { auditDaySpan } from './span-audit.mjs';
import { auditClip } from './clip-audit.mjs';

const HERE = path.dirname(fileURLToPath(import.meta.url));
const REPO = path.normalize(path.join(HERE, '..', '..'));
const OUT = path.join(HERE, 'src');
const JS = path.join(HERE, 'out');
const LOG = path.join(HERE, 'out', 'last-run.log');

/** 裸模块名 -> 临时 barrel：设备侧源码（@kit、cloud、RDB、Preferences）不参与拷贝，用类型壳替代。 */
const BARE = {
  domain: 'domainIndex', feature: 'featureIndex', data: 'dataIndex', commons: 'commonsIndex',
  // 云客户端：@kit.CloudFoundationKit 不参与转译，桩见 STUB_CLOUD。
  cloud: 'cloudIndex'
};

/**
 * 拷贝树：skip 里的文件是设备耦合源码（SettingsStore/关系型数据库/@kit/云），
 * 由下方显式类型壳替代，避免用例被真机依赖拖住。
 */
const TREES = [
  { root: 'main', from: 'domain/src/main', skip: [] },
  { root: 'test', from: 'domain/src/test', skip: [] },
  {
    root: 'feature/main', from: 'feature/src/main',
    skip: [
      // ScheduleUseCase 与概览查询要 @kit/taskpool。ProfileSettingsService 已从 skip 里移出：
      // 它只依赖 SettingsStore/ScheduleRepo/云客户端，三者下面都有同名桩，而验收报告 B1 要求
      // "关闭态云调用 0 次、pairId/key/state 不变"必须在离线侧断言，不能只写在真机清单里。
      'ScheduleUseCase.ets', 'ScheduleOverviewQueryService.ets',
      // 门面包 @kit.CalendarKit；PlanUseCase 通过能力端口调用它，单测注入确定性端口实现，
      // 这里只需要类型壳让默认适配器过编译。
      'CalendarGateway.ets',
      // 扫码/分享门面包 @kit.ScanKit / @kit.ShareKit / 剪贴板；一次性凭据口径由 domain 的
      // PairLinkTest 离线覆盖，这里不参与转译（真机侧行为见 docs/testing-checklist.md）。
      'PairingShareGateway.ets',
      // 预算门槛与线程归属：@kit.ArkTS(taskpool) + @kit.BasicServicesKit(systemDateTime)，
      // 离线只留同名口径的桩（计算照跑、永远内联）。
      'RecomputeExecutor.ets']
  },
  // 只有 @kit-free 的迁移层参与；Db.ets 需要 relationalStore，属于真机侧。
  { root: 'data/main/ets/db', from: 'data/src/main/ets/db', skip: ['Db.ets'] },
  // Logger 包 hilog；DateLabel/AppConst 是纯逻辑。
  { root: 'commons/main', from: 'commons/src/main', skip: ['log'] },
  { root: 'etest', from: 'entry/src/test', skip: [] }
];

function rel(from, to) {
  const r = path.relative(from, to).replace(/\\/g, '/');
  return r.startsWith('.') ? r : './' + r;
}

function rewrite(txt, fileDir) {
  let s = txt.replace(/(from\s+'[^']+)\.ets'/g, "$1'");
  for (const [pkg, target] of Object.entries(BARE)) {
    const to = path.normalize(path.join(OUT, target));
    s = s.replace(new RegExp("from '" + pkg + "'", 'g'), "from '" + rel(fileDir, to) + "'");
  }
  return s;
}

function copyTree(from, to, skip) {
  if (skip.includes(path.basename(to))) {
    return;
  }
  fs.mkdirSync(to, { recursive: true });
  for (const e of fs.readdirSync(from, { withFileTypes: true })) {
    const s = path.join(from, e.name);
    const d = path.join(to, e.name);
    if (e.isDirectory()) {
      copyTree(s, d, skip);
    } else if (e.name.endsWith('.ets') && !skip.includes(e.name)) {
      fs.writeFileSync(d.slice(0, -3) + 'ts', rewrite(fs.readFileSync(s, 'utf8'), to));
    }
  }
}

/**
 * ArkUI 全局的离线声明：设备侧由 @kit.ArkUI 提供，这里只补转译树真正用到的两个成员，
 * 签名与 `AppStorage.get<T>() / setOrCreate<T>()` 一致，保证同一份断言搬到真机仍然成立。
 */
const STUB_GLOBALS = `
declare const AppStorage: {
  get<T>(propName: string): T | undefined;
  setOrCreate<T>(propName: string, newValue: T): boolean;
};
`;

/**
 * ScheduleUseCase 的类型壳：设备侧这里跑引擎与广播，桩只保留"重算发生了一次"的可观测语义
 * ——按设备侧同名键累加 recomputeCount，用例据此断言一次保存只重算一次。
 */
const STUB_SCHEDULE_USECASE = `
import { defaultParams, EngineParams, Interval, SectionTime, Window } from '../../../../main/ets/model/Types';

export const RECOMPUTE_COUNT_KEY = 'recomputeCount';

export interface DayViewData {
  epochDay: number;
  windows: Window[];
  myBusy: Interval[];
  partnerBusy: Interval[] | null;
  myTrueBusy: Interval[];
  partnerTrueBusy: Interval[] | null;
  partnerSource: string;
  partnerShareLevel: number;
}

export class ScheduleUseCase {
  static async onScheduleChanged(): Promise<void> {
    const cur: number = AppStorage.get<number>(RECOMPUTE_COUNT_KEY) ?? 0;
    AppStorage.setOrCreate<number>(RECOMPUTE_COUNT_KEY, cur + 1);
  }
  /** 离线没有云层，合并同步的两个动作都只是空转：存在性为了签名对齐，行为由设备用例覆盖。 */
  static scheduleMergedSync(): void {}
  static cancelMergedSync(): void {}
  static defaultSectionTimes(): SectionTime[] {
    return [{ startMin: 480, endMin: 525 }];
  }
  static sectionTimesToJson(times: SectionTime[]): string {
    const parts: string[] = [];
    for (let i = 0; i < times.length; i++) {
      parts.push('[' + times[i].startMin + ',' + times[i].endMin + ']');
    }
    return '[' + parts.join(',') + ']';
  }
  static async getDayView(epochDay: number): Promise<DayViewData> {
    const dv: DayViewData = {
      epochDay: epochDay, windows: [], myBusy: [], partnerBusy: null,
      myTrueBusy: [], partnerTrueBusy: null,
      partnerSource: 'NONE', partnerShareLevel: 0
    };
    return dv;
  }
}

/** 参数读取壳：离线不接 Preferences，任何调用方拿到的都是出厂默认值。 */
export function SettingsStoreParams(): EngineParams {
  return defaultParams();
}
`;

/** Logger 类型壳：commons 的 log 目录包 hilog，不参与转译。 */
const STUB_LOGGER = `
export class Logger {
  static info(tag: string, msg: string): void {}
  static warn(tag: string, msg: string): void {}
  static error(tag: string, msg: string): void {}
  static perf(tag: string, msg: string): void {}
}
`;

/**
 * 预算执行器的离线桩：设备侧那份要 import @kit.ArkTS / @kit.BasicServicesKit，不参与转译。
 * 口径保持一致——计算照跑、结果同构，只是不计时、永远内联：用例断言的是共同时间，不是线程归属。
 */
const STUB_RECOMPUTE_EXECUTOR = `
import { CommonFreeEngine } from '../../../../main/ets/engine/CommonFreeEngine';
import { CommonFreeResult, EngineInput } from '../../../../main/ets/model/Types';

export const MAIN_THREAD_BUDGET_MS: number = 16;
export const MIGRATE_HORIZON_DAYS: number = 150;
export const LABEL_SAVE_FLOW: string = 'save_recompute';

export class RecomputeExecutor {
  static async compute(input: EngineInput): Promise<CommonFreeResult> {
    return CommonFreeEngine.compute(input);
  }
  static async measure<T>(label: string, work: () => Promise<T>): Promise<T> {
    return await work();
  }
}
`;

/** 设备侧门面（SettingsStore/ScheduleRepo）的类型壳：用例只驱动纯装配，能过类型即可。 */
const STUB_DATA = `
import { Course, defaultParams, EngineParams, ScheduleOverride, ShiftType, Window } from './main/ets/model/Types';
import { PendingCloudUnpair, decodeCloudDebts, encodeCloudDebts } from './domainIndex';

export const PAIRED = 'PAIRED';
export const PAIR_NONE = 'NONE';
export const PAIR_WAITING = 'WAITING';
export const PAIR_PENDING = 'PENDING_CONFIRM';

export interface PlanRow {
  start: number; end: number; id: string; title: string; kind: string; status: string;
  createdBy: string; windowRef: string; conflictHint: string; myEventId: string;
  reminderId: number; updatedAt: number; calendarState: string; syncState: string;
}

export interface PartnerProfile { nick: string; wakeMin: number; bedMin: number; windDownMin: number; }

/**
 * 云侧待补删凭据的形状与编解码都来自 domain 的 CloudDebtCodec（设备侧 import 的是同一个实现）：
 * 桩只替换那一格 Preferences 的存储，不许自己再解析一遍——批次 AP·Task 1 要证的正是
 * "旧包那一格单对象在升级后还读得回"，桩里另写一份解码，绿了也证明不了真机读得回。
 */

/** 离线计划表：upsertPlan 存行，后续 update* 就地改字段（设备侧同一段是 SQL UPDATE）。 */
const planRows = new Map<string, PlanRow>();

/**
 * 仓储桩：写入按"内存表"记账（设备侧是 SQLite），好让用例能用同名公开 API
 * 断言"本地计划先落库、日历结果只是回写"这类编排顺序，而不是靠测试专用字段。
 * runInTransaction 保留"整批要么全成要么回滚"的传播语义，好让命令层的失败分支可测。
 */
export class ScheduleRepo {
  static async listWindows(): Promise<Window[]> { return []; }
  static async windowCacheComputedAt(): Promise<number> { return 0; }
  static async runInTransaction(work: () => Promise<void>): Promise<void> { await work(); }
  static async upsertOverride(o: ScheduleOverride, note: string, owner: string): Promise<void> {}
  static async deleteOverride(epochDay: number, owner: string): Promise<void> {}
  static async upsertShiftType(st: ShiftType, owner: string): Promise<void> {}
  static async deleteShiftType(id: string, owner: string): Promise<void> {}
  static async saveTemplate(tpl: Object, owner: string): Promise<void> {}
  static async deleteTemplate(owner: string): Promise<void> {}
  static async upsertCourse(c: Course, owner: string): Promise<void> {}
  static async deleteCourse(id: string, owner: string): Promise<void> {}
  static async saveTermConfig(termStartEpochDay: number, sectionTimesJson: string): Promise<void> {}
  static async upsertPlan(p: PlanRow): Promise<void> { planRows.set(p.id, p); }
  static async updatePlanCalendar(id: string, calendarState: string, eventId: string): Promise<void> {
    const r = planRows.get(id);
    if (r !== undefined) { r.calendarState = calendarState; r.myEventId = eventId; }
  }
  static async updatePlanProjection(id: string, calendarState: string, eventId: string,
    reminderId: number): Promise<void> {
    const r = planRows.get(id);
    if (r !== undefined) {
      r.calendarState = calendarState; r.myEventId = eventId; r.reminderId = reminderId;
    }
  }
  static async updatePlanReminder(id: string, reminderId: number): Promise<void> {
    const r = planRows.get(id);
    if (r !== undefined) { r.reminderId = reminderId; }
  }
  static async updatePlanStatus(id: string, status: string): Promise<void> {
    const r = planRows.get(id);
    if (r !== undefined) { r.status = status; }
  }
  static async updatePlanTime(id: string, start: number, end: number): Promise<void> {
    const r = planRows.get(id);
    if (r !== undefined) { r.start = start; r.end = end; }
  }
  static async updatePlanConflict(id: string, status: string, conflictHint: string): Promise<void> {
    const r = planRows.get(id);
    if (r !== undefined) { r.status = status; r.conflictHint = conflictHint; }
  }
  /** 与设备侧同口径：排除 CANCELLED，按 start 升序。 */
  static async listActivePlans(): Promise<PlanRow[]> {
    return sortedRows((r: PlanRow) => r.status !== 'CANCELLED');
  }
  /** 与设备侧同口径：CLEANUP_PENDING，或已取消却仍带着日程/提醒句柄的残留行。 */
  static async listOrphanProjectionPlans(): Promise<PlanRow[]> {
    return sortedRows((r: PlanRow) => r.calendarState === 'CLEANUP_PENDING'
      || (r.status === 'CANCELLED' && (r.myEventId !== '' || r.reminderId >= 0)));
  }
  /** 与设备侧同口径：带着日程 id 或提醒句柄的全部行（含 CANCELLED），清空数据前用来带走投影。 */
  static async listPlansCarryingHandles(): Promise<PlanRow[]> {
    return sortedRows((r: PlanRow) => r.myEventId !== '' || r.reminderId >= 0);
  }
  /** 删除伴侣（本机代录）名下数据：离线只清内存表里 createdBy=PARTNER 的计划行。 */
  static async deletePartnerData(): Promise<void> {
    const drop: string[] = [];
    planRows.forEach((r: PlanRow) => {
      if (r.createdBy === 'PARTNER') { drop.push(r.id); }
    });
    for (const id of drop) { planRows.delete(id); }
  }
  static async clearAllData(): Promise<void> {
    planRows.clear();
  }
}

function sortedRows(keep: (r: PlanRow) => boolean): PlanRow[] {
  const out: PlanRow[] = [];
  planRows.forEach((r: PlanRow) => {
    if (keep(r)) { out.push(r); }
  });
  out.sort((a: PlanRow, b: PlanRow) => a.start - b.start);
  return out;
}

/**
 * 设置存储的离线桩：设备侧那份是 Preferences 文件（crd_settings），这里换成同名键的内存表，
 * 于是"写库之前就该返回"这类断言有可观察的落点——桩里没写进去，就是真机上没写进去。
 * 方法名、同步/异步形态与设备侧逐条对齐（getPairState/getShareLevel 等在设备侧都是 getSync）。
 */
const settingsRows = new Map<string, Object>();
let uidSeq = 0;

function settingOf(key: string, dflt: Object): Object {
  const v = settingsRows.get(key);
  return v === undefined ? dflt : v;
}

export class SettingsStore {
  static async setParams(p: EngineParams): Promise<void> {
    settingsRows.set('engine_params', JSON.stringify(p));
  }
  static getParams(): EngineParams {
    const text = settingOf('engine_params', '') as string;
    return text === '' ? defaultParams() : (JSON.parse(text) as EngineParams);
  }
  /**
   * 测试注入（批次 AO·AO4）：设备侧 SettingsStore.p() 在 Preferences 尚未 init 时**抛错**，
   * 于是"初始化竞态"这一格在桩里也得有同形状的失败，否则读口的 try-catch 就是没被测到的死代码。
   */
  static shareLevelFailure: Error | null = null;
  static getShareLevel(): number {
    if (SettingsStore.shareLevelFailure !== null) {
      throw SettingsStore.shareLevelFailure;
    }
    return Number(settingOf('share_level', 2));
  }
  /** 测试注入：写一个设备侧真会出现的脏值（字符串、0、9），setter 只收 1/2/3 所以绕不过去。 */
  static async setShareLevelRaw(v: Object): Promise<void> {
    settingsRows.set('share_level', v);
  }
  static async setShareLevel(level: number): Promise<void> {
    settingsRows.set('share_level', level);
  }
  static getPairState(): string {
    return settingOf('pair_state', PAIR_NONE) as string;
  }
  static async setPairState(state: string, partnerUid: string): Promise<void> {
    settingsRows.set('pair_state', state);
    settingsRows.set('partner_uid', partnerUid);
  }
  static getPartnerUid(): string {
    return settingOf('partner_uid', '') as string;
  }
  static getPairId(): string {
    return settingOf('pair_id', '') as string;
  }
  static async savePairId(pairId: string): Promise<void> {
    settingsRows.set('pair_id', pairId);
  }
  /** 只清理，不读取：密钥材料的读写口都在 HUKS（cloud/PairKeyStore），本应用侧不存在读密钥的 API。 */
  static async clearPairKey(): Promise<void> {
    settingsRows.delete('pair_key');
  }
  static getPartnerSnapVer(): number {
    return Number(settingOf('partner_snap_ver', 0));
  }
  static async setPartnerSnapVer(v: number): Promise<void> {
    settingsRows.set('partner_snap_ver', v);
  }
  /** 最后一次有效快照的信封（设备侧同名）：真机才有拉取路径，桩只保证名字与形态对齐。 */
  static getPartnerSnapCache(): string {
    return settingOf('partner_snap_cache', '') as string;
  }
  static async setPartnerSnapCache(envelope: string): Promise<void> {
    settingsRows.set('partner_snap_cache', envelope);
  }
  static async clearPartnerSnapCache(): Promise<void> {
    settingsRows.delete('partner_snap_cache');
  }
  /** 云同步三态的编码串（设备侧同名）：桩同样把 setter 露出来，用例据此摆出待重试/已降级两种形状。 */
  static getCloudSyncState(): string {
    return settingOf('cloud_sync_state', '') as string;
  }
  static async setCloudSyncState(raw: string): Promise<void> {
    settingsRows.set('cloud_sync_state', raw);
  }
  /** 心跳游标（设备侧同名）：桩把 setter 露出来，用例据此摆出"上周跳过/这周不该跳"两种形状。 */
  static getLastHeartbeatAt(): number {
    return Number(settingOf('last_heartbeat_at', 0));
  }
  static async setLastHeartbeatAt(ms: number): Promise<void> {
    settingsRows.set('last_heartbeat_at', ms);
  }
  /**
   * 云侧待补删凭据（设备侧同名，批次 AO 起是一条队列）：解码走的是 domain 那一份实现，
   * 桩这里只是把同一串原文换放进内存表。「欠账→新配对→再清空」与「终局判定只报数不敲门」
   * 两类断言因此都落在真代码上，而不是桩自证。
   */
  static getPendingCloudUnpair(): PendingCloudUnpair[] {
    return decodeCloudDebts(settingOf('pending_cloud_unpair', '') as string);
  }
  static async addPendingCloudUnpair(pairId: string, uid: string, dead: boolean): Promise<void> {
    if (pairId === '' || uid === '') {
      return;
    }
    const next = SettingsStore.getPendingCloudUnpair().filter((r: PendingCloudUnpair) => r.pairId !== pairId);
    const rec: PendingCloudUnpair = { pairId: pairId, uid: uid, dead: dead };
    next.push(rec);
    await SettingsStore.savePendingCloudUnpair(next);
  }
  static async dropPendingCloudUnpair(pairId: string): Promise<void> {
    await SettingsStore.savePendingCloudUnpair(
      SettingsStore.getPendingCloudUnpair().filter((r: PendingCloudUnpair) => r.pairId !== pairId));
  }
  static async savePendingCloudUnpair(list: PendingCloudUnpair[]): Promise<void> {
    settingsRows.set('pending_cloud_unpair', encodeCloudDebts(list));
  }
  static countDeadCloudUnpair(): number {
    return SettingsStore.getPendingCloudUnpair().filter((r: PendingCloudUnpair) => r.dead).length;
  }
  static async clearPendingCloudUnpair(): Promise<void> {
    settingsRows.delete('pending_cloud_unpair');
  }
  /**
   * 测试注入（批次 AP·Task 1）：旧包（批次 U·U5）在这一格存的是**单对象**而不是数组，
   * 而现写的 setter 只会写数组，所以"从那一版升上来还读不读得回这笔账"只能由测试
   * 把原文直接种进存储里——种的是设备侧真出现过的那串字节，不是测试专用的中间形状。
   */
  static async setPendingCloudUnpairRaw(text: string): Promise<void> {
    settingsRows.set('pending_cloud_unpair', text);
  }
  /** 同一格的原文：断言"写出去的是数组形状"时读它，不另开一份内存副本。 */
  static pendingCloudUnpairRaw(): string {
    return settingOf('pending_cloud_unpair', '') as string;
  }
  static async getOrCreateUid(): Promise<string> {
    const existing = settingOf('device_uid', '') as string;
    if (existing !== '') {
      return existing;
    }
    uidSeq = uidSeq + 1;
    const uid = 'uid-offline-' + uidSeq;
    settingsRows.set('device_uid', uid);
    return uid;
  }
  static getPartnerProfile(): PartnerProfile | null {
    const v = settingOf('partner_profile', null);
    return v == null ? null : (v as PartnerProfile);
  }
  static async savePartnerProfile(profile: PartnerProfile): Promise<void> {
    settingsRows.set('partner_profile', profile);
  }
  static async clearPartnerProfile(): Promise<void> {
    settingsRows.delete('partner_profile');
  }
  static isPrivacyAccepted(): boolean {
    return settingOf('privacy_accepted', false) === true;
  }
  static async acceptPrivacy(): Promise<void> {
    settingsRows.set('privacy_accepted', true);
  }
  static async clearAllSettings(): Promise<void> {
    settingsRows.clear();
  }
}
`;

/**
 * 云客户端的离线桩：设备侧那份 import @kit.CloudFoundationKit 与 @ohos.security.huks，不参与转译。
 * 关键差别：桩**必定成功**（返回一个会话），而真机上 AGC 未配置时 `cloudFunction.call` 必定抛错。
 * 只有"云端被误配置成功"这一格才能暴露缺失的开关守卫——少一次判断，pairId/pairState 就会被写进本机，
 * 这正是验收报告 B1 的原始风险。`calls` 与设备侧同名，用来断言关闭态一条请求都没发。
 *
 * `PairKeyStore` 同样带 `calls`：关闭态不仅不许发云请求，也不许在 HUKS 里建任何别名。
 * 桩里刻意**没有任何返回密钥材料的函数**（生产签名里也没有），所以"密钥泄漏到应用层"
 * 这类断言在结构上不成立，只能断言调用次数为 0。
 */
const STUB_CLOUD = `
export interface PairSession {
  pairId: string;
  status: string;
  code: string;
  peerUid: string;
  peerPublicKey: string;
  confirmToken: string;
  expiresAt: number;
  serverTime: number;
}

export class CloudApiError extends Error {
  readonly semantic: string;
  readonly retryable: boolean;

  constructor(semantic: string, retryable: boolean, message: string) {
    super(message);
    this.name = 'CloudApiError';
    this.semantic = semantic;
    this.retryable = retryable;
  }
}

export const CLOUD_LOCAL = 'LOCAL';
export const CLOUD_NETWORK = 'NETWORK';

export function newRequestId(): string {
  return 'request-offline';
}

export class AgcPairingClient {
  /** 云对象调用计数（设备侧同名字段）：关闭态的断言就打这里。 */
  static calls: number = 0;
  /**
   * 让 unpair 抛一次的开关（null = 正常返回）。设备侧的"云端删不动"是断网/配额/服务端拒绝
   * 撞出来的，离线复现不了，所以这一格只能靠桩注入——批次 U·U5 那三条用例打的就是它。
   */
  static unpairFailure: CloudApiError | null = null;
  /**
   * 每次 unpair 的 pairId 与 uid（批次 AP·Task 1）：补删用的 uid 必须是**那一轮**留在会话行里的
   * 那一个，本机新生成的 uid 不是成员，敲门永远撞 FORBIDDEN。只数 calls 证明不了带的谁，
   * 于是这一格把两列原样记下来，让"旧欠账的 uid 逐字没变"能在离线侧对出来。
   */
  static unpairCalls: string[] = [];
  /**
   * 让 heartbeat 悬住的开关（null = 立刻返回）。批次 AO·AO5 要断言的是"旧会话那一跳的迟到返回值
   * 不许写下新会话的游标"，而桩若即时 resolve，commitBeat 里那次同一性复核在离线侧永远走不到。
   */
  static heartbeatHold: Promise<void> | null = null;

  async createPairing(uid: string, publicKey: string): Promise<PairSession> {
    AgcPairingClient.calls = AgcPairingClient.calls + 1;
    return mkSession('WAITING', uid);
  }

  async joinPairing(code: string, uid: string, publicKey: string): Promise<PairSession> {
    AgcPairingClient.calls = AgcPairingClient.calls + 1;
    return mkSession('PENDING_CONFIRM', uid);
  }

  async confirmPairing(pairId: string, uid: string, confirmToken: string): Promise<PairSession> {
    AgcPairingClient.calls = AgcPairingClient.calls + 1;
    return mkSession('ACTIVE', uid);
  }

  async pairStatus(pairId: string, uid: string): Promise<PairSession> {
    AgcPairingClient.calls = AgcPairingClient.calls + 1;
    return mkSession('WAITING', uid);
  }

  async unpair(pairId: string, uid: string, requestId: string): Promise<number> {
    AgcPairingClient.calls = AgcPairingClient.calls + 1;
    AgcPairingClient.unpairCalls.push(pairId + '|' + uid);
    if (AgcPairingClient.unpairFailure !== null) {
      throw AgcPairingClient.unpairFailure;
    }
    return 0;
  }

  async heartbeat(uid: string, pairId: string): Promise<number> {
    AgcPairingClient.calls = AgcPairingClient.calls + 1;
    if (AgcPairingClient.heartbeatHold !== null) {
      await AgcPairingClient.heartbeatHold;
    }
    return 0;
  }
}

export class PairKeyStore {
  /** HUKS 别名操作计数（设备侧同名字段）：关闭态一条别名都不许建。 */
  static calls: number = 0;

  static async ensureIdentity(uid: string): Promise<string> {
    PairKeyStore.calls = PairKeyStore.calls + 1;
    return 'pk-offline';
  }

  static async agreeKey(uid: string, pairId: string, peerPublicKeyB64: string): Promise<void> {
    PairKeyStore.calls = PairKeyStore.calls + 1;
  }

  static async hasPairKey(pairId: string): Promise<boolean> {
    PairKeyStore.calls = PairKeyStore.calls + 1;
    return false;
  }

  static async dropPairKey(pairId: string): Promise<void> {
    PairKeyStore.calls = PairKeyStore.calls + 1;
  }
}

function mkSession(status: string, uid: string): PairSession {
  const s: PairSession = {
    pairId: 'session-from-the-cloud', status: status, code: '246810',
    peerUid: 'peer-' + uid, peerPublicKey: 'pk-peer', confirmToken: 'token-from-the-cloud',
    expiresAt: 0, serverTime: 0
  };
  return s;
}
`;

/**
 * 设备侧日历门面的类型壳：PlanCapabilities 的默认适配器引用它，
 * 用例通过 PlanCapabilities.bind 注入确定性端口实现，所以这里返回"能力不可用"即可。
 * 提醒那一侧自 D-20 起不再有设备门面（首发零提醒），所以只剩日历这一个壳。
 */
const STUB_GATEWAYS = {
  'CalendarGateway.ts': `
import { CalendarOutcome, CalendarWriteResult, RemoveOutcome } from '../model/PlanFlow';

export class CalendarGateway {
  static init(context: Object): void {}
  static async requestPermissions(): Promise<boolean> { return false; }
  static async writeEvent(t: string, s: number, e: number): Promise<CalendarWriteResult> {
    return { outcome: CalendarOutcome.UNAVAILABLE, eventId: '' };
  }
  static async exportEvent(t: string, s: number, e: number): Promise<CalendarWriteResult> {
    return { outcome: CalendarOutcome.UNAVAILABLE, eventId: '' };
  }
  static async removeEvent(eventId: string): Promise<RemoveOutcome> { return RemoveOutcome.FAILED; }
  static async purgeManagedCalendar(): Promise<boolean> { return false; }
}
`
};

/**
 * 档位覆盖：`CRD_TIER=closed|open` 改写**编译副本**里 `FeatureFlags.cloudPairing` 的字面量，
 * 源码不动。开闸批之后源码常量是 true，而"关档时一条请求都不发"这条边界仍然要被证明，
 * 所以 tools/verify.mjs 会两种档位各跑一遍，谁也没能悄悄少跑一个桶。
 * 只认 cloudPairing 一个常量：其余档位没有闭态专属用例。
 */
function overrideTier(say) {
  const tier = (process.env.CRD_TIER || '').trim().toLowerCase();
  if (tier === '') {
    say('tier: 源码档位（未设 CRD_TIER）');
    return true;
  }
  if (tier !== 'closed' && tier !== 'open') {
    say('tier: FAILED（CRD_TIER=' + tier + ' 只认 closed / open）');
    return false;
  }
  const file = path.join(OUT, 'feature/main/ets/config/FeatureFlags.ts');
  const src = fs.readFileSync(file, 'utf8');
  const want = tier === 'open' ? 'true' : 'false';
  const re = /(static readonly cloudPairing: boolean = )\b(true|false)\b/;
  if (!re.test(src)) {
    // 找不到就是这一跑**没有**跑在声称的档位上——静默继续会让两个桶看起来都绿。
    say('tier: FAILED（CRD_TIER=' + tier + '，但副本里找不到 cloudPairing 的布尔字面量，审计跟着改）');
    return false;
  }
  fs.writeFileSync(file, src.replace(re, '$1' + want));
  say('tier: CRD_TIER=' + tier + ' → 编译副本 cloudPairing=' + want);
  return true;
}

function prepare() {
  fs.rmSync(OUT, { recursive: true, force: true });
  fs.rmSync(JS, { recursive: true, force: true });
  for (const t of TREES) {
    copyTree(path.join(REPO, t.from), path.join(OUT, t.root), t.skip);
  }
  // HAR 的 barrel 在模块根目录，不在 src/main 下，单独搬。
  fs.writeFileSync(path.join(OUT, 'domainIndex.ts'),
    fs.readFileSync(path.join(REPO, 'domain/Index.ets'), 'utf8')
      .replace(/\.\/src\/main\/ets\//g, './main/ets/'));
  fs.writeFileSync(path.join(OUT, 'featureIndex.ts'),
    "export * from './feature/main/ets/model/PresentationModels';\n"
    + "export * from './feature/main/ets/model/RhythmRules';\n"
    + "export * from './feature/main/ets/model/PlanKinds';\n"
    + "export * from './feature/main/ets/model/PlanFlow';\n"
    + "export * from './feature/main/ets/model/CloudSyncRules';\n"
    + "export * from './feature/main/ets/model/SerialQueue';\n"
    + "export * from './feature/main/ets/config/FeatureFlags';\n"
    + "export * from './feature/main/ets/usecase/CommonTimeQueryService';\n"
    + "export * from './feature/main/ets/usecase/CardSummaryService';\n"
    + "export * from './feature/main/ets/usecase/ScheduleUseCase';\n"
    + "export * from './feature/main/ets/usecase/ScheduleCommandService';\n"
    + "export * from './feature/main/ets/usecase/PlanUseCase';\n"
    + "export * from './feature/main/ets/usecase/PlanProjectionCleanupService';\n"
    + "export * from './feature/main/ets/usecase/ProfileSettingsService';\n"
    + "export * from './feature/main/ets/integration/PlanCapabilities';\n");
  for (const [name, body] of Object.entries(STUB_GATEWAYS)) {
    const dir = path.join(OUT, 'feature/main/ets/integration');
    fs.mkdirSync(dir, { recursive: true });
    fs.writeFileSync(path.join(dir, name), body);
  }
  fs.writeFileSync(path.join(OUT, 'commonsLogStub.ts'), STUB_LOGGER);
  fs.writeFileSync(path.join(OUT, 'globals.d.ts'), STUB_GLOBALS);
  fs.writeFileSync(path.join(OUT, 'commonsIndex.ts'),
    "export * from './commons/main/ets/util/DateLabel';\n"
    + "export * from './commons/main/ets/util/SwatchInk';\n"
    + "export * from './commons/main/ets/constant/AppConst';\n"
    + "export * from './commonsLogStub';\n");
  fs.writeFileSync(path.join(OUT, 'dataIndex.ts'),
    "export * from './data/main/ets/db/MigrationRunner';\nexport * from './dataStubs';\n");
  fs.writeFileSync(path.join(OUT, 'dataStubs.ts'), STUB_DATA);
  fs.writeFileSync(path.join(OUT, 'cloudIndex.ts'), STUB_CLOUD);
  fs.writeFileSync(path.join(OUT, 'feature/main/ets/usecase/ScheduleUseCase.ts'),
    STUB_SCHEDULE_USECASE);
  const perfDir = path.join(OUT, 'feature/main/ets/performance');
  fs.mkdirSync(perfDir, { recursive: true });
  fs.writeFileSync(path.join(perfDir, 'RecomputeExecutor.ts'), STUB_RECOMPUTE_EXECUTOR);
  fs.copyFileSync(path.join(REPO, 'feature/BuildProfile.ets'), path.join(OUT, 'BuildProfile.ts'));
}

function findTsc() {
  const env = process.env.CRD_TSC;
  if (env && fs.existsSync(env)) {
    return env;
  }
  const bundled = 'D:/local/DevEcoStudio/tools/hvigor/hvigor/node_modules/typescript/bin/tsc';
  return fs.existsSync(bundled) ? bundled : null;
}

/** tsc 的每条诊断占一行（`path(line,col): error TSxxxx: …`），续行缩进、不计入条数。 */
function countTypeErrors(stdout) {
  if (!stdout) {
    return 0;
  }
  return stdout.split(/\r?\n/).filter((l) => /error TS\d+:/.test(l)).length;
}

function main() {
  const log = [];
  const say = (line) => {
    console.log(line);
    log.push(line);
  };
  const finish = (code) => {
    fs.mkdirSync(JS, { recursive: true });
    fs.writeFileSync(LOG, log.join('\n') + '\n');
    console.log('\n日志：' + LOG.replace(/\\/g, '/'));
    process.exitCode = code;
  };
  const copyViolations = auditPrivacyCopy(REPO);
  say('copy: ' + (copyViolations.length === 0
    ? 'PASS（隐私政策三处全文同源 + 摘要五条 + 全仓无绝对化表述 + 清空文案口径 + 说法载体跟手）'
    : 'FAILED（' + copyViolations.length + ' 项口径冲突）'));
  for (const v of copyViolations) {
    say('  - ' + v);
  }
  const a11yViolations = auditAccessibility(REPO);
  say('a11y: ' + (a11yViolations.length === 0
    ? 'PASS（no 只挂在叶子节点或无文字容器上，没有挂进带文字的容器）'
    : 'FAILED（' + a11yViolations.length + ' 处失效挂点）'));
  for (const v of a11yViolations) {
    say('  - ' + v);
  }
  const landingViolations = auditLanding(REPO);
  say('landing: ' + (landingViolations.length === 0
    ? 'PASS（读数落地闸门齐、领过号都问过归属、现生成主键的提交都上了闩）'
    : 'FAILED（' + landingViolations.length + ' 处读数闸门／提交闩不达标）'));
  for (const v of landingViolations) {
    say('  - ' + v);
  }
  const press = auditPress(REPO);
  say('press: ' + (press.violations.length === 0
    ? 'PASS（自制圆角可点节点都有按压回弹：接 ' + press.wired + ' 处，写明理由豁免 ' + press.exempt + ' 处）'
    : 'FAILED（' + press.violations.length + ' 处按压回弹不达标）'));
  for (const v of press.violations) {
    say('  - ' + v);
  }
  const contrast = auditContrast(REPO);
  say('contrast: ' + (contrast.violations.length === 0
    ? 'PASS（压在用户自选色上的前景都由底色算出来：接 ' + contrast.wired + ' 处，写明理由豁免 '
      + contrast.exempt + ' 处，两档墨色字面量与 SwatchInk 同源）'
    : 'FAILED（' + contrast.violations.length + ' 处色块对比度口径不达标）'));
  for (const v of contrast.violations) {
    say('  - ' + v);
  }
  const horizon = auditHorizonCeiling(REPO);
  say('horizon: ' + (horizon.violations.length === 0
    ? 'PASS（视界的上限与默认值各自只在 domain 定义一次：clampHorizonDays 相关行 ' + horizon.callSites
      + ' 处，commons 那份旧默认值的读者 ' + horizon.defaultReads + ' 处，出厂值被念成当前值的 '
      + horizon.defaultPaste + ' 处，离开存储的口子 '
      + horizon.mouths + ' 个都在白名单里，界面上的天数都念常量）'
    : 'FAILED（' + horizon.violations.length + ' 处视界上下界抄写）'));
  for (const v of horizon.violations) {
    say('  - ' + v);
  }
  const endread = auditEndRead(REPO);
  say('endread: ' + (endread.violations.length === 0
    ? 'PASS（区间终点的午夜读法只在 DateLabel.edgeTime 定一次：裸 hm ' + endread.callSites
      + ' 处都取起点或纯时刻，edgeTime 接 ' + endread.edgeSites + ' 处，写明理由豁免 '
      + endread.exempt + ' 处）'
    : 'FAILED（' + endread.violations.length + ' 处终点念法抄写／误读）'));
  for (const v of endread.violations) {
    say('  - ' + v);
  }
  const span = auditDaySpan(REPO);
  say('span: ' + (span.violations.length === 0
    ? 'PASS（端点归日与跨零点作息只在 domain 的 TimeUtil 定一次：取整×一天长度的除法式 '
      + span.dayDivisions + ' 处都在家里，dayOfStart／dayOfEnd／daySpan／bedEndMin 家以外接 '
      + span.readerSites + ' 处，写明理由豁免 ' + span.exempt + ' 处）'
    : 'FAILED（' + span.violations.length + ' 处归日／跨零点抄写）'));
  for (const v of span.violations) {
    say('  - ' + v);
  }
  const clip = auditClip(REPO);
  say('clip: ' + (clip.violations.length === 0
    ? 'PASS（把区间裁进窗口这件事只在 domain 的 clipInto 定一次：非嵌套的 max/min 取界对全仓 '
      + clip.pairSites + ' 处（家里 ' + clip.homePairs + ' 处），clipInto 家以外接 '
      + clip.readerSites + ' 处、intersects 接 ' + clip.predicateSites
      + ' 处，写明理由豁免 ' + clip.exempt + ' 处）'
    : 'FAILED（' + clip.violations.length + ' 处区间裁剪／交叠谓词抄写）'));
  for (const v of clip.violations) {
    say('  - ' + v);
  }
  prepare();
  if (!overrideTier(say)) {
    say('tests: FAILED（档位覆盖没落地，这一跑的结论不属于任何档位）');
    finish(1);
    return;
  }
  const tsc = findTsc();
  if (tsc === null) {
    say('未找到 TypeScript 编译器。装好 DevEco Studio 后设 CRD_TSC=<.../typescript/bin/tsc> 重试。');
    say('typecheck: skipped');
    finish(2);
    return;
  }
  // noEmitOnError:true：类型报错就不产出 JS，因此下面的用例只可能跑在编译干净的工程上。
  const compile = spawnSync('node', [tsc, '-p', path.join(HERE, 'tsconfig.json')], { encoding: 'utf8' });
  if (compile.stdout) {
    say(compile.stdout.trimEnd());
  }
  const errors = countTypeErrors(compile.stdout);
  say('typecheck: ' + (errors === 0 ? '0 errors' : errors + ' errors'));
  if (errors > 0 || compile.status !== 0) {
    say('--- 类型编译未通过：不启动用例（退出码 3）---');
    say('tests: not run');
    finish(3);
    return;
  }
  const run = spawnSync('node', [path.join(HERE, 'boot.cjs')], { encoding: 'utf8' });
  if (run.stdout) {
    say(run.stdout.trimEnd());
  }
  if (run.stderr) {
    say(run.stderr.trimEnd());
  }
  const testsPassed = run.status === 0;
  say('tests: ' + (testsPassed ? 'passed' : 'FAILED (exit ' + (run.status ?? 'null') + ')'));
  // 九条静态口径审计都不参与"用例绿"，所以用例全绿时还要各自为政地把退出码压回 1。
  const auditViolations = copyViolations.length + a11yViolations.length + landingViolations.length
    + press.violations.length + contrast.violations.length + horizon.violations.length
    + endread.violations.length + span.violations.length + clip.violations.length;
  if (testsPassed && auditViolations > 0) {
    say('--- 用例全绿但离线口径审计未通过（退出码 1）---');
  }
  finish(testsPassed && auditViolations === 0 ? 0 : (testsPassed ? 1 : (run.status ?? 1)));
}

main();
