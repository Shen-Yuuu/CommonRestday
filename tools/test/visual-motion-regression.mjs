/** 真实纯函数 + 源码接线；不把它当作设备渲染/手势证据。 */
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import { createRequire } from 'node:module';
import { fileURLToPath } from 'node:url';
const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '../..');
const read = p => fs.readFileSync(path.join(root, p), 'utf8');
const require = createRequire(import.meta.url);
const tsc = process.env.CRD_TSC || 'D:/local/DevEcoStudio/tools/hvigor/hvigor/node_modules/typescript/bin/tsc';
const ts = require(path.resolve(path.dirname(tsc), '..'));
const helper = read('entry/src/main/ets/util/VisualMotionMath.ets');
const compiled = ts.transpileModule(helper, { compilerOptions: { module: ts.ModuleKind.CommonJS } });
const exports = {};
new Function('exports', compiled.outputText)(exports);
const { rangeRatio, lerpRatio, homeContentKey } = exports;
assert.equal(rangeRatio(10, 10, 15), 0);
assert.equal(rangeRatio(10, 20, 0), 0);
assert.equal(rangeRatio(10, 20, 30), 1);
assert.equal(rangeRatio(10, 20, 15), 0.5);
assert.equal(rangeRatio(10, 20, NaN), 0);
assert.equal(lerpRatio(0.2, 0.8, 0), 0.2);
assert.equal(lerpRatio(0.2, 0.8, 1), 0.8);
assert.equal(lerpRatio(0.2, 0.8, 0.5), 0.5);
assert.equal(lerpRatio(0.2, 0.8, 2), 0.8);
const h = { mode: 'SOLO', partnerName: 'TA', tonight: {}, fullRestDay: {}, trip: {},
  nextWindow: null, conflictCount: 0, conflictReason: '', today: {}, computedAt: 1, stale: false };
assert.equal(homeContentKey(h, [], false), homeContentKey({ ...h, computedAt: 99 }, [], false));
assert.notEqual(homeContentKey(h, [], false), homeContentKey({ ...h, conflictCount: 1 }, [], false));
assert.notEqual(homeContentKey(h, [], false), homeContentKey(h, [{ id: 'new' }], false));
assert.notEqual(homeContentKey(h, [], false), homeContentKey(h, [], true));
assert.notEqual(homeContentKey(h, [], false), homeContentKey({ ...h, stale: true }, [], false));
const home = read('entry/src/main/ets/view/HomeView.ets');
for (const delay of [0, 45, 90]) assert.match(home, new RegExp(`revealDelay: ${delay}\\b`));
assert.match(home, /homeContentKey/);
assert.match(home, /await this\.load\(false\)/);
assert.match(home, /首页内容没有变化/);
const reveal = read('entry/src/main/ets/component/QuickAnswerRow.ets');
assert.match(reveal, /aboutToDisappear[\s\S]*clearTimeout/);
assert.match(reveal, /LocalTween/);
assert.doesNotMatch(reveal, /animateTo/);
const directional = read('entry/src/main/ets/component/DirectionalContent.ets');
assert.match(directional, /onCommit\(target\)/);
assert.match(directional, /HitTestMode\.None/);
assert.match(directional, /aboutToDisappear[\s\S]*cancel\(\)/);
assert.doesNotMatch(directional, /animateTo|Visibility/);
// 在内存中执行真实组件的控制方法，替换帧/时钟端口；不解析或模拟 ArkUI build()。
function controlClass(source, name, bindings) {
  const controller = source.slice(0, source.indexOf('  build() {'))
    .replace(/^import\b[\s\S]*?;\s*/gm, '')
    .replace(/@\w+(?:\([^)]*\))?\s*/g, '')
    .replace(`export struct ${name}`, `export class ${name}`) + '\n}';
  const js = ts.transpileModule(controller, { compilerOptions: { module: ts.ModuleKind.CommonJS } }).outputText;
  const out = {};
  new Function('exports', ...Object.keys(bindings), js)(out, ...Object.values(bindings));
  return out[name];
}
class TweenPort {
  pending = null;
  cancel() { this.pending = null; }
  play(_ctx, from, to, ms, frame, finish = () => {}) {
    this.cancel(); this.pending = { to, ms, frame, finish }; frame(from);
  }
  finish() { const p = this.pending; this.pending = null; if (p) { p.frame(p.to); p.finish(); } }
}
const Directional = controlClass(directional, 'DirectionalContent', { LocalTween: TweenPort });
const d = new Directional();
d.getUIContext = () => ({});
const commits = [];
d.onCommit = n => commits.push(n);
d.aboutToAppear(); commits.length = 0;
d.target = 1; d.switchToTarget();
assert.deepEqual(commits, [], '退出完毕前不能替换真实内容');
d.target = 0; d.switchToTarget();
assert.equal(d.tween.pending, null, '迅速点回当前视图撤销旧动画');
d.target = 1; d.switchToTarget(); d.tween.finish();
assert.deepEqual(commits, [1]);
assert.equal(d.tween.pending.ms, 110);
d.target = 0; d.switchToTarget(); d.tween.finish(); d.tween.finish();
assert.deepEqual(commits, [1, 0], '最终意图覆盖未完成的入场');
assert.equal(d.moving, false);
d.target = 1; d.switchToTarget(); d.aboutToDisappear();
assert.equal(d.tween.pending, null, '离开撤销帧回调');
d.aboutToAppear();
assert.equal(commits.at(-1), 1, '重新挂载时请求 tab 与实际内容一致');
d.foreground = false; d.target = 0; d.switchToTarget();
assert.equal(d.tween.pending, null);
assert.equal(commits.at(-1), 0, '后台直接落最终状态，不跑帧');
const co = read('entry/src/main/ets/view/CoTimeView.ets');
assert.match(co, /DirectionalContent\(/);
assert.match(co, /selected: this\.selectedWindow\(w\)/);
assert.match(co, /onDisappear: \(\) => \{ this\.sheetVisible = false;/);
assert.match(co, /listScrollY/);
assert.match(co, /weekScrollY/);
const card = read('entry/src/main/ets/component/EditorialCard.ets');
assert.match(card, /\.outline\(/);
assert.match(card, /\.onHover\(/);
const sheet = read('entry/src/main/ets/component/WindowDetailSheet.ets');
assert.match(sheet, /PlanRangePreview\(/);
assert.match(sheet, /successTimer = setTimeout/);
assert.match(sheet, /SUCCESS_HOLD_MS = 400/);
assert.match(sheet, /request !== this\.draftGeneration/);
assert.match(sheet, /catch \(e\)/);
assert.match(sheet, /this\.created \? DesignTokens\.successAction/);
assert.match(sheet, /closeSheet\(\)/);
assert.match(read('entry/src/main/ets/component/PlanRangePreview.ets'), /LocalTween/);
const Preview = controlClass(read('entry/src/main/ets/component/PlanRangePreview.ets'), 'PlanRangePreview',
  { LocalTween: TweenPort, rangeRatio, lerpRatio, DesignTokens: { motion: (reduce, ms) => reduce ? 0 : ms } });
const p = new Preview(); p.getUIContext = () => ({});
p.winStart = 0; p.winEnd = 120; p.planStart = 0; p.planEnd = 60; p.aboutToAppear();
p.planStart = 15; p.updateRange(); p.tween.pending.frame(0.5);
p.planStart = 30; p.updateRange(); p.tween.finish();
assert.equal(p.startRatio, 0.25, '快速调节从当前帧接到最新目标');
assert.equal(p.planStart, 30, '动画不能回写真实草稿');
p.planEnd = 90; p.updateRange(); p.foreground = false; p.onForegroundChanged();
assert.equal(p.tween.pending, null);
assert.equal(p.endRatio, 0.75);
p.updateRange(); p.aboutToDisappear(); assert.equal(p.tween.pending, null);
// 创建成功的400ms只驱动确认/关闭，不二次持久化；退后台、换窗口、离开均撤销旧反馈。
const timers = new Map(); let timerId = 0;
const closed = []; const shown = [];
const saves = []; const published = [];
const Sheet = controlClass(sheet, 'WindowDetailSheet', {
  DRAFT_GRID_MIN: 15,
  setTimeout: (fn, ms) => {
    const id = ++timerId; timers.set(id, { fn: () => { timers.delete(id); fn(); }, ms }); return id;
  },
  clearTimeout: id => timers.delete(id), appToast: msg => shown.push(msg),
  PLAN_KINDS: [{ key: 'eat', label: '一起吃饭' }], planDraftError: () => '',
  PlanUseCase: { createPlan: () => new Promise((resolve, reject) => saves.push({ resolve, reject })) },
  publishPlanSaved: id => published.push(id), isOnSystemCalendar: () => false,
  LOCAL_ONLY_NOTE: '仅保存在应用内', Logger: { warn: () => {} }
});
const s = new Sheet(); s.mounted = true; s.created = true; s.createdPlanId = 'saved'; s.createdMessage = 'local';
s.onClose = () => closed.push('close'); s.onCreated = id => closed.push(id);
s.holdSuccess(); const first = timers.get(s.successTimer);
assert.equal(first.ms, 400);
s.foreground = false; s.onForegroundChanged(); assert.equal(timers.size, 0);
s.foreground = true; s.onForegroundChanged(); const next = timers.get(s.successTimer);
next.fn(); first.fn();
assert.deepEqual(closed, ['close', 'saved'], '确认只通知一次，旧时钟不得重复通知');
assert.deepEqual(shown, ['local']);
s.created = true; s.holdSuccess(); const stale = timers.get(s.successTimer);
s.closeSheet(); stale.fn(); assert.deepEqual(closed, ['close', 'saved', 'close']);
s.created = true; s.holdSuccess(); s.aboutToDisappear(); assert.equal(s.successTimer, -1);
assert.equal(timers.size, 0);
const form = new Sheet(); form.mounted = true;
const saving = form.submitPlan(); await form.submitPlan();
assert.equal(saves.length, 1, '双击创建只调用一次持久化端口');
saves[0].resolve({ ok: true, planId: 'one', calendarState: 'LOCAL_ONLY' }); await saving;
assert.equal(form.created, true);
assert.deepEqual(published, ['one']);
timers.get(form.successTimer).fn();
assert.equal(shown.at(-1), '计划已创建（仅保存在应用内）', '确认不可冒充系统日历写入');
const failed = new Sheet(); failed.mounted = true;
const refused = failed.submitPlan(); saves[1].resolve({ ok: false, error: '没有保存' }); await refused;
assert.equal(failed.saving, false, '失败后允许再次点击');
assert.equal(failed.created, false);
assert.equal(failed.successTimer, -1);
const abandoned = new Sheet(); abandoned.mounted = true; let oldClosed = 0;
abandoned.onClose = () => oldClosed++;
const oldRequest = abandoned.submitPlan(); abandoned.aboutToDisappear();
saves[2].resolve({ ok: true, planId: 'old', calendarState: 'LOCAL_ONLY' }); await oldRequest;
assert.equal(oldClosed, 0, '旧窗口回包不能关闭之后打开的窗口');
assert.equal(abandoned.created, false);
assert.deepEqual(published, ['one', 'old'], '实际保存的计划仍保留列表定位信号');
const changed = new Sheet(); changed.mounted = true;
const changedRequest = changed.submitPlan(); changed.draftGeneration++;
saves[3].resolve({ ok: true, planId: 'changed', calendarState: 'LOCAL_ONLY' }); await changedRequest;
assert.equal(changed.created, false, '换窗口后拒绝旧成功动画');
const thrown = new Sheet(); thrown.mounted = true;
const thrownRequest = thrown.submitPlan(); saves[4].reject(new Error('port unavailable')); await thrownRequest;
assert.equal(thrown.saving, false, '异常也不能把按钮永远锁在创建中');
assert.equal(timers.size, 0);
const swatchModule = {};
const swatchJS = ts.transpileModule(read('commons/src/main/ets/util/SwatchInk.ets'),
  { compilerOptions: { module: ts.ModuleKind.CommonJS } }).outputText;
new Function('exports', swatchJS)(swatchModule);
for (const tier of ['base', 'dark']) {
  const colors = JSON.parse(read(`entry/src/main/resources/${tier}/element/color.json`)).color;
  const success = colors.find(c => c.name === 'plan_success_action').value;
  const foreground = colors.find(c => c.name === 'hero_fg').value;
  assert.ok(swatchModule.SwatchInk.contrast(success, foreground) >= 4.5, '成功按钮小字对比度');
}
console.log('visual-motion-regression: PASS（纯函数/真实控制方法与假帧时钟端口 + 接线；不替代 ArkUI 设备验收）');
