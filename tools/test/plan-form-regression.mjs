/** 执行生产草稿方法；布局断言只验证接线，不替代设备视觉验收。 */
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import { createRequire } from 'node:module';
import { fileURLToPath } from 'node:url';
const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '../..');
const read = file => fs.readFileSync(path.join(root, file), 'utf8');
const require = createRequire(import.meta.url);
const tsc = process.env.CRD_TSC || 'D:/local/DevEcoStudio/tools/hvigor/hvigor/node_modules/typescript/bin/tsc';
const ts = require(path.resolve(path.dirname(tsc), '..'));
const compile = source => ts.transpileModule(source, {
  compilerOptions: { module: ts.ModuleKind.CommonJS }
}).outputText;
const kinds = {};
new Function('exports', compile(read('feature/src/main/ets/model/PlanKinds.ets')))(kinds);
const sheet = read('entry/src/main/ets/component/WindowDetailSheet.ets');
const methods = sheet.slice(sheet.indexOf('  pickKind(idx:'), sheet.indexOf('  // ---------- 时间轴端点文字'));
assert.ok(methods.includes('onTitleChange(v:'), '必须提取生产代码而非复写行为');
const controls = {};
new Function('exports', 'PLAN_KINDS', 'OTHER_PLAN_KIND_KEY', compile(
  'export class DraftControl { title = ""; kindIdx = 0;\n' + methods + '\n}'
))(controls, kinds.PLAN_KINDS, kinds.OTHER_PLAN_KIND_KEY);
const draft = new controls.DraftControl();
let previous = '';
for (let index = 0; index < kinds.PLAN_KINDS.length; index++) {
  draft.pickKind(index);
  assert.equal(draft.kindIdx, index);
  assert.equal(draft.title, kinds.PLAN_KINDS[index].key === 'custom' ? previous : kinds.PLAN_KINDS[index].label);
  previous = draft.title;
}
draft.pickKind(0);
assert.equal(draft.title, '吃饭', '从其他切回固定分类应恢复默认标题');
draft.onTitleChange('下班后吃火锅');
draft.pickKind(kinds.PLAN_KINDS.length - 1);
assert.equal(draft.title, '下班后吃火锅', '切换其他保留自填标题');
for (let index = 0; index < kinds.PLAN_KINDS.length; index++) {
  draft.onTitleChange('下班后吃火锅');
  draft.pickKind(index);
  assert.equal(draft.title, kinds.PLAN_KINDS[index].key === 'custom' ? '下班后吃火锅' : kinds.PLAN_KINDS[index].label,
    '固定类型更新标题；其他保留当前标题');
}
for (const index of [-1, 0.5, kinds.PLAN_KINDS.length, NaN]) {
  const before = [draft.title, draft.kindIdx];
  draft.pickKind(index);
  assert.deepEqual([draft.title, draft.kindIdx], before, '无效分类索引不得修改草稿');
}
const titleRow = sheet.slice(sheet.indexOf('      // ④ 标题'), sheet.indexOf('      // ⑤ 起止调节'));
assert.match(titleRow, /Row\(\{ space: 12 \}\)/);
assert.match(titleRow, /\.alignItems\(VerticalAlign\.Center\)/);
assert.match(titleRow, /TextInput[\s\S]*minHeight: AccessibilityPolicy\.minHit\(this\.senior\)[\s\S]*\.layoutWeight\(1\)/);
assert.doesNotMatch(titleRow, /\.height\(/, '字号放大时不固定输入框高度');
const prototype = read('docs/prototype/index.html');
const prototypeKinds = new Function(prototype.match(/var PLAN_KINDS = [^\n]+/)[0] + '\nreturn PLAN_KINDS;')();
assert.deepEqual(prototypeKinds, kinds.PLAN_KINDS.map(option => ({ k: option.key, n: option.label })));
assert.match(prototype, /class="row gap10 mt12"[^\n]*align-items:center[^\n]*标题/);
assert.match(prototype, /id="f-dtitle"[^\n]*flex:1;min-width:0;min-height:44px/);
console.log('plan-form-regression: PASS（固定分类更新标题/其他保留标题/无效索引/同排接线/原型一致；视觉待设备）');
