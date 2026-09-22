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
    skip: ['ScheduleUseCase.ets', 'PlanUseCase.ets', 'ScheduleCommandService.ets',
      'ScheduleOverviewQueryService.ets', 'ProfileSettingsService.ets']
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

/** 设备侧门面（SettingsStore/ScheduleRepo）与 ScheduleUseCase 的类型壳：用例只驱动纯装配，能过类型即可。 */
const STUB_SCHEDULE_USECASE = `
import { Interval, Window } from '../../../../main/ets/model/Types';

export interface DayViewData {
  epochDay: number;
  windows: Window[];
  myBusy: Interval[];
  partnerBusy: Interval[] | null;
  partnerSource: string;
  partnerShareLevel: number;
}

export class ScheduleUseCase {
  static async getDayView(epochDay: number): Promise<DayViewData> {
    const dv: DayViewData = {
      epochDay: epochDay, windows: [], myBusy: [], partnerBusy: null,
      partnerSource: 'NONE', partnerShareLevel: 0
    };
    return dv;
  }
}
`;

const STUB_DATA = `
import { Window } from './main/ets/model/Types';

export const PAIRED = 'PAIRED';

export interface PlanRow {
  start: number; end: number; id: string; title: string; kind: string; status: string;
  createdBy: string; windowRef: string; conflictHint: string; myEventId: string;
  reminderId: number; updatedAt: number; calendarState: string; syncState: string;
}

export interface PartnerProfile { nick: string; wakeMin: number; bedMin: number; windDownMin: number; }

export class ScheduleRepo {
  static async listWindows(): Promise<Window[]> { return []; }
  static async listActivePlans(): Promise<PlanRow[]> { return []; }
  static async windowCacheComputedAt(): Promise<number> { return 0; }
}

export class SettingsStore {
  static getPairState(): string { return 'NONE'; }
  static getPartnerProfile(): PartnerProfile | null { return null; }
}
`;

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
    + "export * from './feature/main/ets/config/FeatureFlags';\n"
    + "export * from './feature/main/ets/usecase/CommonTimeQueryService';\n");
  fs.writeFileSync(path.join(OUT, 'commonsIndex.ts'),
    "export * from './commons/main/ets/util/DateLabel';\n"
    + "export * from './commons/main/ets/constant/AppConst';\n");
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
