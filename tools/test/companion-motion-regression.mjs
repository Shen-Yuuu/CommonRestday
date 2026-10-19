/** Production controller with fake timers/Animator; not a device rendering test. */
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import { createRequire } from 'node:module';
const root = path.resolve(import.meta.dirname, '../..');
const read = p => fs.readFileSync(path.join(root, p), 'utf8');
const require = createRequire(import.meta.url);
const ts = require('D:/local/DevEcoStudio/tools/hvigor/hvigor/node_modules/typescript');
const out = {};
new Function('exports', ts.transpileModule(read('entry/src/main/ets/util/CompanionMotion.ets'),
  { compilerOptions: { module: ts.ModuleKind.CommonJS } }).outputText)(out);
const { nextCompanionCombo: combo, companionSquishSpec: spec, companionSquishFrame: frame,
  companionSlotWidth: width } = out;
assert.equal(combo(4, 1000, 1200), 5);
assert.equal(combo(5, 1000, 1499), 5);
assert.equal(combo(2, 1000, 1500), 3);
assert.equal(combo(2, 1000, 1501), 1);
assert.equal(combo(2, 1000, 999), 1);
assert.equal(width(324), 100); assert.equal(width(354), 112); assert.equal(width(0), 112);
for (let n = 1; n <= 5; n++) {
  const s = spec(n, false, .5, .5, .5);
  assert.equal(s.depth, [.68, .63, .57, .52, .48][n - 1]);
  assert.equal(s.peak, [1.18, 1.22, 1.27, 1.33, 1.38][n - 1]);
  assert.deepEqual(frame(s, 0, .9, 1.1, 2), { x: .9, y: 1.1, angle: 2 });
  assert.equal(frame(s, s.pressMs, 1, 1, 0).y, s.depth);
  assert.deepEqual(frame(s, s.duration, .9, 1.1, 2), { x: 1, y: 1, angle: 0 });
  for (const r of [0, .5, 1]) for (const reduced of [false, true]) {
    const rs = spec(n, reduced, r, r, r);
    for (let t = 0; t <= rs.duration; t++) {
      const f = frame(rs, t, 1, 1, 0);
      assert.ok(Number.isFinite(f.x) && Number.isFinite(f.y) && Number.isFinite(f.angle));
      assert.ok(f.y >= (reduced ? .84 : .48) - 1e-12 && f.y <= (reduced ? 1.08 : 1.38) + 1e-12);
      assert.ok(Math.abs(f.angle) <= (reduced ? 0 : 5) + 1e-12);
    }
  }
}
const source = read('entry/src/main/ets/component/CompanionsDuo.ets');
const controller = source.slice(0, source.indexOf('  build() {'))
  .replace(/^import\b[\s\S]*?;\s*/gm, '').replace(/@\w+(?:\([^)]*\))?\s*/g, '')
  .replace('export struct CompanionsDuo', 'export class CompanionsDuo') + '\n}';
const exports = {}, timers = new Map(), anims = [];
let timerId = 0;
const later = (fn, delay) => { const id = ++timerId; timers.set(id, { fn, delay }); return id; };
const cancel = id => timers.delete(id);
const fire = id => { const t = timers.get(id); assert.ok(t, 'scheduled timer exists'); timers.delete(id); t.fn(); };
const sources = { TouchScreen: 0, Mouse: 1, Keyboard: 2 }, touches = { Down: 0, Up: 1, Cancel: 2 };
new Function('exports', 'SourceType', 'TouchType', 'setTimeout', 'clearTimeout', ...Object.keys(out),
  ts.transpileModule(controller, { compilerOptions: { module: ts.ModuleKind.CommonJS } }).outputText)(
  exports, sources, touches, later, cancel, ...Object.values(out));
const context = { createAnimator(config) {
  const a = { config, cancelled: false, play() {}, cancel() { this.cancelled = true; } };
  anims.push(a); return a;
}};
const c = new exports.CompanionsDuo(); c.getUIContext = () => context; c.foreground = true;
c.aboutToAppear(); assert.equal(anims.length, 0, 'no permanent breathing/story animator');
assert.equal(timers.size, 2);
assert.ok(timers.get(c.bunnyTimer).delay >= 5000 && timers.get(c.bunnyTimer).delay <= 8000);
assert.ok(timers.get(c.bearTimer).delay >= 7000 && timers.get(c.bearTimer).delay <= 10000);
c.onPlaybackChanged(); assert.equal(timers.size, 2, 'no duplicate blink scheduling');
fire(c.bunnyTimer); assert.equal(c.bunnyClosed, true); assert.equal(c.bearClosed, false);
assert.equal(timers.get(c.bunnyTimer).delay, 150);
fire(c.bunnyTimer); assert.equal(c.bunnyClosed, false);
fire(c.bearTimer); assert.equal(c.bearClosed, true);
const staleBlink = timers.get(c.bearTimer).fn;
c.squish(); assert.equal(timers.size, 0); assert.equal(c.bearClosed, false);
staleBlink(); assert.equal(c.bearClosed, false); assert.equal(timers.size, 0, 'stale blink cannot restart');
const old = anims.at(-1); old.onFrame(100);
const current = { x: c.squishX, y: c.squishY };
c.squish(); const latest = anims.at(-1); latest.onFrame(0);
assert.equal(c.squishX, current.x); assert.equal(c.squishY, current.y);
old.onFrame(0); old.onFinish(); assert.equal(c.squishAnimator, latest);
latest.onFinish(); assert.equal(timers.size, 2); assert.equal(c.squishY, 1);
for (const field of ['active', 'foreground', 'rootVisible', 'visible']) {
  const pending = [...timers.values()].map(t => t.fn);
  c[field] = false; c.onPlaybackChanged(); assert.equal(timers.size, 0);
  assert.equal(c.bunnyClosed, false); assert.equal(c.bearClosed, false);
  c[field] = true; c.onPlaybackChanged(); assert.equal(timers.size, 2);
  for (const cb of pending) cb();
  assert.equal(timers.size, 2, 'cancelled epoch cannot mutate new schedules');
}
c.reduceMotion = true; c.onPlaybackChanged(); assert.equal(timers.size, 0);
c.squish(); const reduced = anims.at(-1);
for (let t = 0; t <= reduced.config.duration; t++) {
  reduced.onFrame(t); assert.ok(c.squishY >= .84 - 1e-12 && c.squishY <= 1.08 + 1e-12);
}
reduced.onFinish(); assert.equal(timers.size, 0);
c.reduceMotion = false; c.onPlaybackChanged();
c.handleTouch(touches.Down, sources.TouchScreen); const physical = c.squishAnimator;
c.handleTouch(touches.Up, sources.TouchScreen); c.activateClick(sources.TouchScreen);
assert.equal(c.squishAnimator, physical, 'physical down and click count once');
c.activateClick(sources.TouchScreen); assert.notEqual(c.squishAnimator, physical);
const assistive = c.squishAnimator; c.activateClick(sources.Keyboard);
assert.notEqual(c.squishAnimator, assistive);
c.handleTouch(touches.Cancel, sources.TouchScreen);
assert.equal(c.squishAnimator, undefined); assert.equal(c.squishY, 1); assert.equal(timers.size, 2);
const pending = [...timers.values()].map(t => t.fn);
c.aboutToDisappear(); for (const cb of pending) cb();
assert.equal(timers.size, 0); assert.equal(c.bunnyClosed, false);
assert.doesNotMatch(source, /companionBreath|CompanionNarrative|storyKind|earAt|setInterval|iterations: -1/);
assert.match(source, /\.offset\(\{ y: 3 \}\)/);
assert.match(source, /event\.stopPropagation\(\)/); assert.match(source, /onVisibleAreaChange/);
assert.doesNotMatch(source, /\.shadow\(|ScheduleUseCase|CloudApi|AppStorage\.(set|setOrCreate)/);
const actor = read('entry/src/main/ets/component/CompanionActor.ets');
assert.match(actor, /Image\(this\.plate\(\)\)/);
assert.doesNotMatch(actor, /clipShape|PathShape|\.piece\(|_head|\.rotate\(|\.translate\(/);
const scene = read('entry/src/main/ets/component/CompanionScene.ets');
assert.doesNotMatch(scene, /pose\.|Breath|CompanionNarrative/);
const co = read('entry/src/main/ets/view/CoTimeView.ets');
assert.match(co, /active: this\.active && !this\.sheetVisible && !this\.dayVisible/);
assert.match(co, /availableWidth: this\.headerWidth/);
const header = co.slice(co.indexOf('  header() {'), co.indexOf('  segmentControl() {'));
assert.match(header, /Row\(\{ space: 10 \}\)\s*\{[\s\S]*Column\(\{ space: 2 \}\)\s*\{[\s\S]*Text\('共同休时'\)[\s\S]*Text\(this\.subtitle\(\)\)[\s\S]*\}\.layoutWeight\(1\)\.alignItems\(HorizontalAlign\.Start\)\.offset\(\{ y: 3 \}\)[\s\S]*CompanionsDuo/);
assert.match(header, /\.alignItems\(VerticalAlign\.Bottom\)/);
console.log('companion-motion-regression: PASS (blink-only controller, timers, touch and full silhouettes; no device claims)');
