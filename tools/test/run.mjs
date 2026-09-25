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
 * 只有 `typecheck: 0 errors` + `copy: PASS` + `tests: passed` + 退出码 0 才可以写成"全绿"：
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

export const PAIRED = 'PAIRED';
export const PAIR_NONE = 'NONE';
export const PAIR_WAITING = 'WAITING';

export interface PlanRow {
  start: number; end: number; id: string; title: string; kind: string; status: string;
  createdBy: string; windowRef: string; conflictHint: string; myEventId: string;
  reminderId: number; updatedAt: number; calendarState: string; syncState: string;
}

export interface PartnerProfile { nick: string; wakeMin: number; bedMin: number; windDownMin: number; }

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
  static getShareLevel(): number {
    return Number(settingOf('share_level', 2));
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
  /** 只读：长期密钥不再由本应用写入（阶段 6R.2），读到的恒是空串或上一版原型留下的残留。 */
  static async getPairKey(): Promise<string> {
    return settingOf('pair_key', '') as string;
  }
  static async clearPairKey(): Promise<void> {
    settingsRows.delete('pair_key');
  }
  static getPartnerSnapVer(): number {
    return Number(settingOf('partner_snap_ver', 0));
  }
  static async setPartnerSnapVer(v: number): Promise<void> {
    settingsRows.set('partner_snap_ver', v);
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
 * 云客户端的离线桩：设备侧那份 import @kit.CloudFoundationKit，不参与转译。
 * 关键差别：桩**必定成功**（返回一个会话），而真机上 AGC 未配置时 `cloudFunction.call` 必定抛错。
 * 只有"云端被误配置成功"这一格才能暴露缺失的开关守卫——少一次判断，pairId/pairState 就会被写进本机，
 * 这正是验收报告 B1 的原始风险。`calls` 与设备侧同名，用来断言关闭态一条请求都没发。
 */
const STUB_CLOUD = `
export interface PairingSession {
  sessionId: string;
  code: string;
  creatorUid: string;
  status: string;
  expiresAt: number;
}

export class AgcPairingClient {
  /** 云函数调用计数（设备侧同名字段）：关闭态的断言就打这里。 */
  static calls: number = 0;

  async createPairing(uid: string): Promise<PairingSession> {
    AgcPairingClient.calls = AgcPairingClient.calls + 1;
    return mkSession('session-from-the-cloud', '246810', uid);
  }

  async joinPairing(code: string, uid: string): Promise<PairingSession> {
    AgcPairingClient.calls = AgcPairingClient.calls + 1;
    return mkSession('session-from-the-cloud', code, uid);
  }

  async unpair(pairId: string, uid: string): Promise<void> {
    AgcPairingClient.calls = AgcPairingClient.calls + 1;
  }
}

function mkSession(id: string, code: string, creator: string): PairingSession {
  const s: PairingSession = {
    sessionId: id, code: code, creatorUid: creator, status: 'WAITING', expiresAt: 0
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
    ? 'PASS（隐私政策三处全文同源 + 摘要五条 + 全仓无绝对化表述 + 清空文案口径）'
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
  prepare();
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
  // 两条静态口径审计都不参与"用例绿"，所以用例全绿时还要各自为政地把退出码压回 1。
  const auditViolations = copyViolations.length + a11yViolations.length;
  if (testsPassed && auditViolations > 0) {
    say('--- 用例全绿但离线口径审计未通过（退出码 1）---');
  }
  finish(testsPassed && auditViolations === 0 ? 0 : (testsPassed ? 1 : (run.status ?? 1)));
}

main();
