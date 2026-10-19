import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import { createRequire } from 'node:module';
const root = path.resolve(import.meta.dirname, '../..');
const require = createRequire(import.meta.url);
const ts = require('D:/local/DevEcoStudio/tools/hvigor/hvigor/node_modules/typescript');
const math = {};
new Function('exports', ts.transpileModule(fs.readFileSync(path.join(root,
  'tools/design/legacy/CompanionNarrative.ets'), 'utf8'), { compilerOptions: {
  module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2020
} }).outputText)(math);
const { companionNarrativeFrame: frame, companionNarrativeDuration: duration, companionIdlePose: idle } = math;
assert.deepEqual([0, 1, 2, 3].map(duration), [12000, 10000, 8000, 10000]);
for (let kind = 0; kind < 4; kind++) {
  assert.deepEqual(frame(kind, -1), idle());
  assert.deepEqual(frame(kind, NaN), idle());
  assert.deepEqual(frame(kind, duration(kind)), idle());
  assert.deepEqual(frame(kind, duration(kind) + 1), idle());
  for (let t = 0; t <= duration(kind); t++) {
    const pose = frame(kind, t);
    for (const actor of [pose.bubu, pose.xiuxiu]) {
      for (const value of Object.values(actor)) assert.ok(Number.isFinite(value));
      assert.ok(Number.isInteger(actor.face) && actor.face >= 0 && actor.face <= 3);
      assert.ok(actor.pawOpacity >= 0 && actor.pawOpacity <= 1);
      assert.ok(actor.scaleX >= .95 && actor.scaleX <= 1.05);
      assert.ok(actor.scaleY >= .95 && actor.scaleY <= 1.05);
      assert.ok(Math.abs(actor.angle) <= 12);
      assert.ok(Math.abs(actor.earRight) <= 18);
    }
  }
}
assert.equal(frame(0, 5200).xiuxiu.face, 1);
assert.deepEqual(frame(0, 5200), frame(0, 6999), 'keep the 1.8s mutual gaze pause');
assert.equal(frame(1, 3600).xiuxiu.face, 3);
assert.equal(frame(1, 3600).bubu.face, 3);
assert.equal(frame(2, 1500).xiuxiu.earRight, 18);
assert.ok(frame(2, 1650).bubu.scaleX < 1);
assert.equal(frame(3, 3500).xiuxiu.pawOpacity, 1);
assert.deepEqual(frame(3, 3500), frame(3, 5499), 'paws hesitate before moving back');
assert.deepEqual(frame(99, 100), idle());
assert.equal(math.companionIdleFrame(5100, 5000, 7000, 8000).xiuxiu.face, 3);
assert.equal(math.companionIdleFrame(5160, 5000, 7000, 8000).xiuxiu.face, 0);
assert.equal(math.companionIdleFrame(7100, 5000, 7000, 8000).bubu.face, 3);
assert.ok(Math.abs(math.companionIdleFrame(8075, 5000, 7000, 8000).xiuxiu.earLeft - 6) < 1e-9);
assert.ok(math.companionIdleFrame(8600, 5000, 7000, 8000).bubu.pawY > 0);
assert.equal(math.companionSameScene(idle(), idle()), true);
assert.deepEqual(math.companionBlendScene(frame(1, 4000), idle(), 1), idle());
const rig = {};
new Function('exports', ts.transpileModule(fs.readFileSync(path.join(root,
  'tools/design/legacy/CompanionRig.ets'), 'utf8'), { compilerOptions: {
  module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2020
} }).outputText)(rig);
for (let t = 3500; t < 5500; t += 10) {
  const gap = rig.companionNearPawGap(frame(3, t));
  assert.ok(gap >= 3 && gap <= 5, 'nearest paws stop roughly 4vp apart, not the two outer paws');
}
console.log('companion-narrative-regression: PASS (archived prototype timelines, every-ms sampling; no device claims)');
