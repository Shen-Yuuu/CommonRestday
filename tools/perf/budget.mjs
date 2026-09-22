/**
 * 主线程预算测量入口（阶段 5 Task 5.4）：把「120 天重算」「快照编解码」「1000 窗口读模型投影」
 * 各跑若干次，输出 P50/P95/max，供 docs/validation/performance-budget.md 记录与 16ms 门槛比对。
 *
 *   node tools/perf/budget.mjs            # 首次会自动先跑离线套件产出转译结果
 *
 * 口径（重要，别把这张表当成设备结论）：
 * - 这里跑的是 domain 引擎 / codec / feature 读模型这些**无设备依赖的纯逻辑段**，
 *   用的是同一份 .ets 转译出来的 JS，所以数字对应的是"真代码"，不是重写一遍的等价实现。
 * - 采样环境是开发机 x86 单线程，设备主线程通常更慢 → 这张表是**下界**。
 *   下界已超 16ms 的条目＝必须迁 TaskPool 的结论；下界很低的条目仍要真机 hilog 复核，见文档 §3。
 */
import fs from 'node:fs';
import path from 'node:path';
import { spawnSync } from 'node:child_process';
import { createRequire } from 'node:module';
import { fileURLToPath } from 'node:url';

const HERE = path.dirname(fileURLToPath(import.meta.url));
const REPO = path.normalize(path.join(HERE, '..', '..'));
const OUT = path.join(REPO, 'tools', 'test', 'out');

/** 16ms 主线程预算（60fps 一帧）——与 RecomputeExecutor.MAIN_THREAD_BUDGET_MS 同口径。 */
const BUDGET_MS = 16;

function ensureBuilt() {
  const marker = path.join(OUT, 'domainIndex.js');
  if (fs.existsSync(marker)) {
    return true;
  }
  console.log('tools/test/out 不存在，先跑一次离线套件转译源码…');
  spawnSync('node', [path.join(REPO, 'tools', 'test', 'run.mjs')], { stdio: 'ignore' });
  if (!fs.existsSync(marker)) {
    console.error('转译产物仍缺失：手动执行 node tools/test/run.mjs 后重试。');
    return false;
  }
  return true;
}

// ---------- 采样 ----------

/** 就近取秩（nearest-rank，不插值）：样本少时宁可保守，别报出中间值假象。 */
function pct(sorted, q) {
  return sorted[Math.min(sorted.length - 1, Math.floor(q * sorted.length))];
}

function sample(label, iters, warmup, fn) {
  for (let i = 0; i < warmup; i++) {
    fn(i);
  }
  const ms = new Float64Array(iters);
  for (let i = 0; i < iters; i++) {
    const t0 = process.hrtime.bigint();
    fn(i);
    ms[i] = Number(process.hrtime.bigint() - t0) / 1e6;
  }
  const sorted = Array.from(ms).sort((a, b) => a - b);
  return {
    label: label,
    n: iters,
    p50: pct(sorted, 0.5),
    p95: pct(sorted, 0.95),
    max: sorted[sorted.length - 1]
  };
}

// ---------- 夹具：一份"重度用户"的 120 天班表 ----------

function mkType(id, name, startMin, endMin, crossDay, cin, cout, recovery) {
  return {
    id: id, name: name, color: '#000000', startMin: startMin, endMin: endMin, crossDay: crossDay,
    commuteInMin: cin, commuteOutMin: cout, recoveryMin: recovery, nightMode: 0,
    allowActivity: false, kind: 'WORK'
  };
}

/** 双方各自：两班倒 + 周末轮休的循环、20 条单日覆盖、40 门课、若干计划占用。 */
function buildSchedule(D, startDay, plans) {
  const shiftTypes = [
    mkType('day', '白班', 540, 1080, false, 30, 30, 0),
    mkType('early', '早班', 420, 900, false, 30, 30, 0),
    mkType('mid', '中班', 660, 1140, false, 20, 20, 0),
    mkType('late', '晚班', 900, 1380, false, 20, 30, 0),
    mkType('night', '夜班', 1350, 480, true, 20, 40, 360)
  ];
  const template = {
    id: 't1', name: '五二休', seq: ['day', 'early', 'mid', 'day', 'late', 'night', 'day'],
    anchorEpochDay: startDay
  };
  const overrides = [];
  for (let i = 0; i < 20; i++) {
    overrides.push({ epochDay: startDay + i * 6 + 1, shiftTypeId: i % 3 === 0 ? null : 'mid' });
  }
  const courses = [];
  for (let i = 0; i < 40; i++) {
    courses.push({
      id: 'c' + i, name: '课程' + i, weekday: (i % 7) + 1,
      sectionStart: (i % 11) + 1, sectionEnd: (i % 11) + 1 + (i % 3),
      weekFrom: 1, weekTo: 20, parity: i % 3 === 0 ? 1 : 0, place: '教学楼'
    });
  }
  return {
    shiftTypes: shiftTypes,
    template: template,
    overrides: overrides,
    courses: courses,
    sectionTimes: defaultSectionTimes(),
    termStartEpochDay: startDay,
    plans: plans,
    wakeMin: 420,
    bedMin: 1350,
    windDownMin: 20
  };
}

/** 轻度用户：一种班 + 做一休一、无课程无计划、单人——门槛要能证明这种数据不必跨线程。 */
function buildLight(D, startDay) {
  return {
    shiftTypes: [mkType('day', '白班', 540, 1080, false, 30, 30, 0)],
    template: { id: 't1', name: '做一休一', seq: ['day', 'day'], anchorEpochDay: startDay },
    overrides: [],
    courses: [],
    sectionTimes: defaultSectionTimes(),
    termStartEpochDay: startDay,
    plans: [],
    wakeMin: 420,
    bedMin: 1350,
    windDownMin: 20
  };
}

function defaultSectionTimes() {
  const out = [];
  const groups = [[0, 480], [4, 840], [8, 1140]];
  for (let g = 0; g < groups.length; g++) {
    for (let i = 0; i < 4; i++) {
      const start = groups[g][1] + i * 55;
      out.push({ startMin: start, endMin: start + 45 });
    }
  }
  return out;
}

function main() {
  if (!ensureBuilt()) {
    process.exitCode = 2;
    return;
  }
  const require = createRequire(import.meta.url);
  const D = require(path.join(OUT, 'domainIndex.js'));
  const F = require(path.join(OUT, 'featureIndex.js'));

  const startDay = D.todayEpochDay();
  const plans = [];
  for (let i = 0; i < 12; i++) {
    const s = (startDay + i * 9) * D.MIN_PER_DAY + 600;
    plans.push({ start: s, end: s + 180 });
  }
  const my = buildSchedule(D, startDay, plans);
  const partnerSched = buildSchedule(D, startDay, []);

  const run = (days, withPartner, sched) => {
    const p = D.defaultParams();
    p.horizonDays = days;
    let partner = null;
    if (withPartner) {
      const avail = D.buildAvailability(partnerSched, p, startDay, days);
      const tripBusy = D.mergeIntervals(avail.notAvailable.map((iv) => {
        return D.mkIv(iv.start, iv.end + p.windDownMin, iv.tag);
      }));
      partner = { shareLevel: 3, busyIntervals: avail.notAvailable, tripBusyIntervals: tripBusy };
    }
    return D.CommonFreeEngine.compute({
      my: sched, partner: partner, params: p, horizonStartEpochDay: startDay
    });
  };
  const light = buildLight(D, startDay);

  const rows = [];
  rows.push(sample('recompute_120d_light', 60, 10, () => run(120, false, light)));
  rows.push(sample('recompute_120d_solo', 60, 10, () => run(120, false, my)));
  const pair120 = run(120, true, my);
  rows.push(sample('recompute_120d_paired', 60, 10, () => run(120, true, my)));
  rows.push(sample('recompute_366d_paired', 30, 5, () => run(366, true, my)));
  // 视界扫描：HORIZON_MAX=366 是用户可设的合法值，曲线在哪一天跨过 16ms 决定了内联上限
  const sweep = [];
  for (const days of [60, 90, 120, 150, 180, 240, 366]) {
    const s = sample('  horizon_' + days + 'd', 20, 4, () => run(days, true, my));
    sweep.push(days + 'd=' + s.p50.toFixed(1) + 'ms');
  }

  // 快照：build 里含一次完整 buildAvailability，encode/decode 才是纯编解码段
  for (const level of [1, 2, 3]) {
    const p = D.defaultParams();
    const data = D.SnapshotBuilder.build(my, p, startDay, level, 1);
    const text = D.SnapshotCodec.encode(data);
    rows.push(sample('snapshot_build_L' + level + '_120d', 40, 8, () => {
      D.SnapshotBuilder.build(my, p, startDay, level, 1);
    }));
    rows.push(sample('snapshot_encode_L' + level + '_120d', 60, 10, () => {
      D.SnapshotCodec.encode(data);
    }));
    rows.push(sample('snapshot_decode_L' + level + '_120d', 60, 10, () => {
      D.SnapshotCodec.decode(text);
    }));
  }

  // 共同时间页读模型投影：设备侧列表行数由这里给出，渲染帧耗时另测（文档 §3）
  const windows = pair120.windows;
  const planRows = [];
  for (let i = 0; i < plans.length; i++) {
    planRows.push({
      id: 'p' + i, title: '计划', kind: 'OUTING', status: 'CONFIRMED', start: plans[i].start,
      end: plans[i].end, createdBy: 'ME', windowRef: '', conflictHint: '', myEventId: '',
      reminderId: -1, updatedAt: 0, calendarState: 'NONE', syncState: 'LOCAL'
    });
  }
  const now = startDay * D.MIN_PER_DAY + 660;
  const pageInput = {
    windows: windows, plans: planRows,
    filter: { key: 'ALL', fromEpochMin: now },
    mode: F.ExperienceMode.PAIRED, partnerName: 'TA', partnerSource: 'LOCAL',
    computedAt: Date.now(), nowEpochMin: now
  };
  const page = F.CommonTimeQueryService.assemblePage(pageInput);
  rows.push(sample('page_projection_' + windows.length + 'w', 80, 15, () => {
    F.CommonTimeQueryService.assemblePage(pageInput);
  }));
  // 压到 1000 行：120/366 天视界实际产不出这么多窗口，按文档口径造一份超量输入
  const stress = [];
  for (let i = 0; i < 1000; i++) {
    const src = windows[i % windows.length];
    const shift = Math.floor(i / windows.length) * D.MIN_PER_DAY * 120;
    stress.push({
      start: src.start + shift, end: src.end + shift, durationMin: src.durationMin,
      tags: src.tags, channel: src.channel
    });
  }
  const stressInput = {
    windows: stress, plans: planRows, filter: { key: 'ALL', fromEpochMin: 0 },
    mode: F.ExperienceMode.PAIRED, partnerName: 'TA', partnerSource: 'LOCAL',
    computedAt: Date.now(), nowEpochMin: now
  };
  const stressPage = F.CommonTimeQueryService.assemblePage(stressInput);
  rows.push(sample('page_projection_1000w', 60, 10, () => {
    F.CommonTimeQueryService.assemblePage(stressInput);
  }));

  const pad = (s, w) => String(s).padEnd(w);
  const num = (v) => v.toFixed(3).padStart(8);
  console.log('夹具：窗口 ' + windows.length + ' 个（常规+旅行）｜列表行 ' + page.rows.length
    + ' 行｜压测列表行 ' + stressPage.rows.length + ' 行｜L3 明文 '
    + D.SnapshotCodec.encode(D.SnapshotBuilder.build(my, D.defaultParams(), startDay, 3, 1)).length + ' 字符');
  console.log('采样：' + (process.env.CRD_PERF_MACHINE || 'dev-machine/node-x86') + '，单位 ms，就近取秩');
  console.log(pad('segment', 30) + pad('n', 6) + pad('p50', 10) + pad('p95', 10) + pad('max', 10) + 'p95 vs 16ms');
  for (const r of rows) {
    const verdict = r.p95 > BUDGET_MS ? '超预算' : '在预算内';
    console.log(pad(r.label, 30) + pad(r.n, 6) + num(r.p50) + num(r.p95) + num(r.max) + '  ' + verdict);
  }
  console.log('');
  console.log('视界扫描（paired，P50）：' + sweep.join(' '));
  console.log('说明：本表是开发机下界；paired120 产出 ' + pair120.windows.length + ' 个窗口，'
    + '压测用的 1000 行输入在实际视界内产不出，只用于给列表投影一个超量参照。');
}

main();
