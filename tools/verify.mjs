/**
 * 统一发布验证入口：把"离线测试 + 命令行出包 + 告警基线 + 性能预算"合成一条命令，
 * 使发布文档里的每个数字都能被一条命令复现。
 *
 *   node tools/verify.mjs                     # offline + debug 出包（日常门禁）
 *   node tools/verify.mjs --steps=offline,perf
 *   node tools/verify.mjs --steps=offline,debug,release,ohostest,perf   # 提审前全量
 *
 * 退出码：0 全部步骤通过 / 1 任一步骤失败 / 2 环境不满足（缺 tsc、缺 hvigor、缺 SDK）。
 *
 * 口径：
 * - offline 步骤自己不放宽——run.mjs 在类型编译不通过时返回 3，这里同样判失败；
 * - 告警计数只在 clean 之后有意义（增量构建会把 ArkTS 编译任务判为 UP-TO-DATE，
 *   少报的 WARN 不是"改好了"，所以带出包步骤时先 clean）；
 * - 基线写在 tools/verify-baseline.json，数量上升即失败——降了要显式改基线，不静默放宽。
 */
import fs from 'node:fs';
import path from 'node:path';
import { spawnSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';

const HERE = path.dirname(fileURLToPath(import.meta.url));
const REPO = path.normalize(path.join(HERE, '..'));
const BASELINE = path.join(HERE, 'verify-baseline.json');
const LOG_DIR = path.join(REPO, '..', '.crdtest');
const DEVECO = process.env.DEVECO_HOME || 'D:/local/DevEcoStudio';
const HVIGOR = path.join(DEVECO, 'tools/hvigor/bin/hvigorw.js').replace(/\\/g, '/');
const SDK = path.join(DEVECO, 'sdk').replace(/\\/g, '/');

const STEPS = ['offline', 'debug', 'release', 'ohostest', 'perf'];

const arg = (name, dflt) => {
  const hit = process.argv.find((a) => a.startsWith('--' + name + '='));
  return hit === undefined ? dflt : hit.slice(name.length + 3);
};

function run(cmd, args, logFile) {
  const r = spawnSync(cmd, args, { cwd: REPO, encoding: 'utf8', env: {
    ...process.env, DEVECO_SDK_HOME: SDK
  } });
  const out = (r.stdout || '') + (r.stderr || '');
  if (logFile !== null) {
    fs.mkdirSync(path.dirname(logFile), { recursive: true });
    fs.writeFileSync(logFile, out);
  }
  return { status: r.status === null ? 1 : r.status, out };
}

/** 一条出包步骤：clean → assembleHap，返回是否成功与 ArkTS WARN 条数。 */
function buildStep(name, module, buildMode, baseline) {
  const log = path.join(LOG_DIR, 'verify-' + name + '.log');
  const limit = (baseline.arktsWarn || {})[name];
  if (typeof limit !== 'number') {
    return { ok: false, line: name + ' 缺 ArkTS:WARN 基线（回填 tools/verify-baseline.json 后才可比）' };
  }
  const clean = run('node', [HVIGOR, 'clean', '--no-daemon'], null);
  if (clean.status !== 0) {
    return { ok: false, line: name + ' clean 失败，详见日志' };
  }
  const args = [HVIGOR, '--mode', 'module', '-p', 'product=default', '-p', 'module=' + module,
    '-p', 'buildMode=' + buildMode, 'assembleHap', '--no-daemon'];
  const r = run('node', args, log);
  const warns = (r.out.match(/ArkTS:WARN/g) || []).length;
  const built = /BUILD SUCCESSFUL/.test(r.out);
  if (!built) {
    return { ok: false, line: name + ' BUILD FAILED（' + log.replace(/\\/g, '/') + '）' };
  }
  if (warns > limit) {
    return { ok: false,
      line: name + ' ArkTS:WARN ' + warns + ' > 基线 ' + limit + '（告警不得上升）' };
  }
  return { ok: true, line: name + ' BUILD SUCCESSFUL，ArkTS:WARN ' + warns + '（基线 '
    + limit + '），日志 ' + log.replace(/\\/g, '/') };
}

function offlineStep() {
  const r = run('node', [path.join(REPO, 'tools/test/run.mjs')], null);
  const type = (r.out.match(/typecheck: (.*)/) || [, '?'])[1];
  const tests = (r.out.match(/tests: (.*)/) || [, '?'])[1];
  const count = (r.out.match(/(\d+) passed, (\d+) failed/) || [, '?', '?']);
  return { ok: r.status === 0,
    line: 'offline typecheck=' + type + ' tests=' + tests + ' → ' + count[1] + ' passed / '
      + count[2] + ' failed，exit ' + r.status };
}

function perfStep() {
  const r = run('node', [path.join(REPO, 'tools/perf/budget.mjs')], null);
  const lines = r.out.trim().split(/\r?\n/).filter((l) => l.trim() !== '').slice(-4);
  return { ok: r.status === 0, line: 'perf exit ' + r.status + '\n  ' + lines.join('\n  ') };
}

function main() {
  const wanted = arg('steps', '').split(',').filter((s) => s !== '');
  const steps = wanted.length > 0 ? wanted : ['offline', 'debug'];
  const unknown = steps.filter((s) => !STEPS.includes(s));
  if (unknown.length > 0) {
    console.log('未知步骤：' + unknown.join(',') + '；可选 ' + STEPS.join(','));
    process.exitCode = 2;
    return;
  }
  if (!fs.existsSync(BASELINE)) {
    console.log('缺基线文件 ' + BASELINE);
    process.exitCode = 2;
    return;
  }
  const baseline = JSON.parse(fs.readFileSync(BASELINE, 'utf8'));
  const needHvigor = steps.some((s) => s !== 'offline' && s !== 'perf');
  if (needHvigor && (!fs.existsSync(HVIGOR) || !fs.existsSync(SDK))) {
    console.log('未找到 hvigor 或 SDK：设 DEVECO_HOME=<DevEco 安装目录> 后重试。');
    process.exitCode = 2;
    return;
  }
  let ok = true;
  for (const s of steps) {
    const r = s === 'offline' ? offlineStep()
      : s === 'perf' ? perfStep()
        : s === 'debug' ? buildStep('debug', 'entry@default', 'debug', baseline)
          : s === 'release' ? buildStep('release', 'entry@default', 'release', baseline)
            : buildStep('ohostest', 'entry@ohosTest', 'debug', baseline);
    console.log((r.ok ? 'PASS ' : 'FAIL ') + r.line);
    ok = ok && r.ok;
  }
  console.log('\n' + (ok ? 'verify: ALL PASS' : 'verify: FAILED'));
  process.exitCode = ok ? 0 : 1;
}

main();
