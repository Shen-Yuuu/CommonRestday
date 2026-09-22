/**
 * 离线单测入口：把纯逻辑源码（domain + feature 读模型 + 两套 Hypium 用例）转译成
 * CommonJS 后用 Node 跑，给改动一个不需要真机的快速反馈信号。
 *
 *   node tools/test/run.mjs          # 仓库根目录执行
 *   CRD_ONLY=commonTimeQueryService node tools/test/run.mjs   # 只跑一个 describe
 *
 * 退出码：0 全部通过 / 1 有用例失败 / 2 环境不满足（缺 tsc）。
 * 完整输出同时写在 tools/test/out/last-run.log。
 *
 * 注意：这里证明的是"纯装配与计算逻辑"，不覆盖 @kit/RDB/Preferences/云调用与渲染；
 * 那些仍由 DevEco 的 ohosTest（真机 Instrument Test）负责。
 */
import fs from 'node:fs';
import path from 'node:path';
import { spawnSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';

const HERE = path.dirname(fileURLToPath(import.meta.url));
const REPO = path.normalize(path.join(HERE, '..', '..'));
const OUT = path.join(HERE, 'src');
const JS = path.join(HERE, 'out');
const LOG = path.join(HERE, 'out', 'last-run.log');

/** 裸模块名 -> 临时 barrel：设备侧源码（@kit、cloud、RDB、Preferences）不参与拷贝，用类型壳替代。 */
const BARE = {
  domain: 'domainIndex', feature: 'featureIndex', data: 'dataIndex', commons: 'commonsIndex'
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
    skip: ['ScheduleUseCase.ets',
      'ScheduleOverviewQueryService.ets', 'ProfileSettingsService.ets',
      // 两个门面包 @kit.CalendarKit / reminderAgentManager；PlanUseCase 通过能力端口调用它们，
      // 单测注入确定性端口实现，这里只需要类型壳让默认适配器过编译。
      'CalendarGateway.ets', 'ReminderGateway.ets',
      // 扫码/分享门面包 @kit.ScanKit / @kit.ShareKit / 剪贴板；一次性凭据口径由 domain 的
      // PairLinkTest 离线覆盖，这里不参与转译（真机侧行为见 docs/testing-checklist.md）。
      'PairingShareGateway.ets']
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
 * ScheduleUseCase 的类型壳：设备侧这里跑引擎与广播，桩只保留"重算发生了一次"的可观测语义
 * ——按设备侧同名键累加 recomputeCount，用例据此断言一次保存只重算一次。
 */
const STUB_SCHEDULE_USECASE = `
import { Interval, SectionTime, Window } from '../../../../main/ets/model/Types';

export const RECOMPUTE_COUNT_KEY = 'recomputeCount';

declare const AppStorage: {
  get(k: string): number | undefined;
  setOrCreate(k: string, v: number): boolean;
};

export interface DayViewData {
  epochDay: number;
  windows: Window[];
  myBusy: Interval[];
  partnerBusy: Interval[] | null;
  partnerSource: string;
  partnerShareLevel: number;
}

export class ScheduleUseCase {
  static async onScheduleChanged(): Promise<void> {
    const cur: number = AppStorage.get(RECOMPUTE_COUNT_KEY) ?? 0;
    AppStorage.setOrCreate(RECOMPUTE_COUNT_KEY, cur + 1);
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
      partnerSource: 'NONE', partnerShareLevel: 0
    };
    return dv;
  }
}
`;

/** Logger 类型壳：commons 的 log 目录包 hilog，不参与转译。 */
const STUB_LOGGER = `
export class Logger {
  static info(tag: string, msg: string): void {}
  static warn(tag: string, msg: string): void {}
  static error(tag: string, msg: string): void {}
}
`;

/** 设备侧门面（SettingsStore/ScheduleRepo）的类型壳：用例只驱动纯装配，能过类型即可。 */
const STUB_DATA = `
import { Course, ScheduleOverride, ShiftType, Window } from './main/ets/model/Types';

export const PAIRED = 'PAIRED';

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
    const out: PlanRow[] = [];
    planRows.forEach((r: PlanRow) => {
      if (r.status !== 'CANCELLED') { out.push(r); }
    });
    out.sort((a: PlanRow, b: PlanRow) => a.start - b.start);
    return out;
  }
}

export class SettingsStore {
  static getPairState(): string { return 'NONE'; }
  static getPartnerProfile(): PartnerProfile | null { return null; }
}
`;

/**
 * 设备侧日历/提醒门面的类型壳：PlanUseCase 只在默认适配器里引用它们，
 * 用例通过 PlanUseCase.bindCapabilities 注入确定性端口实现，所以这里返回"能力不可用"即可。
 */
const STUB_GATEWAYS = {
  'CalendarGateway.ts': `
import { CalendarOutcome, CalendarWriteResult } from '../model/PlanFlow';

export class CalendarGateway {
  static init(context: Object): void {}
  static async requestPermissions(): Promise<boolean> { return false; }
  static async confirmEvent(t: string, s: number, e: number): Promise<CalendarWriteResult> {
    return { outcome: CalendarOutcome.UNAVAILABLE, eventId: '' };
  }
  static async writeEvent(t: string, s: number, e: number): Promise<CalendarWriteResult> {
    return { outcome: CalendarOutcome.UNAVAILABLE, eventId: '' };
  }
  static async removeEvent(eventId: string): Promise<boolean> { return false; }
}
`,
  'ReminderGateway.ts': `
export class ReminderGateway {
  static init(context: Object): void {}
  static async publish(title: string, startMin: number): Promise<number> { return -1; }
  static async cancel(reminderId: number): Promise<void> {}
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
    + "export * from './feature/main/ets/model/PlanFlow';\n"
    + "export * from './feature/main/ets/config/FeatureFlags';\n"
    + "export * from './feature/main/ets/usecase/CommonTimeQueryService';\n"
    + "export * from './feature/main/ets/usecase/CardSummaryService';\n"
    + "export * from './feature/main/ets/usecase/ScheduleUseCase';\n"
    + "export * from './feature/main/ets/usecase/ScheduleCommandService';\n"
    + "export * from './feature/main/ets/usecase/PlanUseCase';\n");
  for (const [name, body] of Object.entries(STUB_GATEWAYS)) {
    const dir = path.join(OUT, 'feature/main/ets/integration');
    fs.mkdirSync(dir, { recursive: true });
    fs.writeFileSync(path.join(dir, name), body);
  }
  fs.writeFileSync(path.join(OUT, 'commonsLogStub.ts'), STUB_LOGGER);
  fs.writeFileSync(path.join(OUT, 'commonsIndex.ts'),
    "export * from './commons/main/ets/util/DateLabel';\n"
    + "export * from './commons/main/ets/constant/AppConst';\n"
    + "export * from './commonsLogStub';\n");
  fs.writeFileSync(path.join(OUT, 'dataIndex.ts'),
    "export * from './data/main/ets/db/MigrationRunner';\nexport * from './dataStubs';\n");
  fs.writeFileSync(path.join(OUT, 'dataStubs.ts'), STUB_DATA);
  fs.writeFileSync(path.join(OUT, 'feature/main/ets/usecase/ScheduleUseCase.ts'),
    STUB_SCHEDULE_USECASE);
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

function main() {
  const log = [];
  const say = (line) => {
    console.log(line);
    log.push(line);
  };
  prepare();
  const tsc = findTsc();
  if (tsc === null) {
    say('未找到 TypeScript 编译器。装好 DevEco Studio 后设 CRD_TSC=<.../typescript/bin/tsc> 重试。');
    fs.mkdirSync(JS, { recursive: true });
    fs.writeFileSync(LOG, log.join('\n') + '\n');
    process.exitCode = 2;
    return;
  }
  // noEmitOnError:false：类型报错照样产出 JS，先让用例跑起来，报错本身也打进日志。
  const compile = spawnSync('node', [tsc, '-p', path.join(HERE, 'tsconfig.json')], { encoding: 'utf8' });
  if (compile.stdout) {
    say(compile.stdout.trimEnd());
  }
  if (compile.status !== 0) {
    say('--- tsc 报了类型错误，仍继续执行已产出的用例 ---');
  }
  const run = spawnSync('node', [path.join(HERE, 'boot.cjs')], { encoding: 'utf8' });
  if (run.stdout) {
    say(run.stdout.trimEnd());
  }
  if (run.stderr) {
    say(run.stderr.trimEnd());
  }
  fs.mkdirSync(JS, { recursive: true });
  fs.writeFileSync(LOG, log.join('\n') + '\n');
  console.log('\n日志：' + LOG.replace(/\\/g, '/'));
  process.exitCode = run.status === 0 ? 0 : (run.status ?? 1);
}

main();
