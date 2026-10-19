const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const assert = require('node:assert/strict');
const html = fs.readFileSync(path.resolve(__dirname, '../../docs/prototype/weekly-schedule-redesign-2026-10-09.html'), 'utf8');
const modelSource = html.match(/<script id="roster-model">([\s\S]*?)<\/script>/)[1];
const M = vm.runInNewContext(modelSource + '\nRosterModel;');
const shift = (name, start, end, nextDay = false) => ({ id: name, name, color: '#83a8d5', segments: [{ start, end, nextDay }] });
const day = (...entries) => ({ status: 'work', entries });
let passed = 0;
function test(name, fn) { fn(); passed++; console.log('PASS ' + name); }
test('星期一及跨月日期计算', () => {
  assert.equal(M.monday('2026-10-09'), '2026-10-05');
  assert.equal(M.addDays('2026-10-31', 1), '2026-11-01');
  assert.throws(() => M.stamp('2026-02-30'), /有效日期/);
});
test('未安排与明确休息分开统计', () => {
  const result = M.weekSummary({ '2026-10-05': day(shift('早班', '07:00', '15:00')), '2026-10-06': { status: 'rest', entries: [] } }, '2026-10-05');
  assert.equal(result.work, 1); assert.equal(result.rest, 1); assert.equal(result.unknown, 5);
});
test('一个班次两个时段不会填满午休', () => {
  const split = { ...shift('白班', '08:00', '12:00'), segments: [{ start: '08:00', end: '12:00' }, { start: '14:00', end: '18:00' }] };
  assert.equal(M.conflicts({ '2026-10-09': day(split, shift('午间', '12:00', '14:00')) }).length, 0);
});
test('同一天早班和晚班可以共存', () => assert.equal(M.conflicts({ '2026-10-09': day(shift('早班', '07:00', '15:00'), shift('晚班', '18:00', '21:00')) }).length, 0));
test('相同时间重复添加被识别', () => assert.equal(M.conflicts({ '2026-10-09': day(shift('早班', '07:00', '15:00'), shift('重复', '08:00', '12:00')) }).length, 1));
test('跨午夜与次日班次冲突', () => assert.equal(M.conflicts({ '2026-10-08': day(shift('夜班', '22:00', '10:00', true)), '2026-10-09': day(shift('早班', '08:00', '15:00')) }).length, 1));
test('时段结束须正确且不超过24小时', () => {
  assert.throws(() => M.intervals('2026-10-09', [shift('错误', '22:00', '06:00')]), /次日结束/);
  assert.throws(() => M.intervals('2026-10-09', [shift('过长', '08:00', '12:00', true)]), /24小时/);
});
test('应用班次保存快照，不受班次修改影响', () => {
  const preset = shift('白班', '08:00', '12:00'); const assigned = M.snapshot(preset, 'applied');
  preset.segments[0].end = '13:00'; assert.equal(assigned.segments[0].end, '12:00');
});
test('复制保留原有工作与休息，不修改源', () => {
  const source = { '2026-10-05': day(shift('早班', '07:00', '15:00')), '2026-10-12': { status: 'rest', entries: [] } };
  const before = JSON.stringify(source); const result = M.copyWeeks(source, '2026-10-05', ['2026-10-12'], 'keep');
  assert.equal(result.skipped, 1); assert.equal(result.roster['2026-10-12'].status, 'rest'); assert.equal(JSON.stringify(source), before);
});
test('替换覆盖目标班次，不将源未知日期补成休息', () => {
  const result = M.copyWeeks({ '2026-10-05': day(shift('早班', '07:00', '15:00')), '2026-10-12': day(shift('晚班', '18:00', '21:00')) }, '2026-10-05', ['2026-10-12'], 'replace');
  assert.equal(result.roster['2026-10-12'].entries[0].name, '早班'); assert.equal(result.roster['2026-10-13'], undefined);
});
test('合并支持多班，同时阻止重叠', () => {
  const source = { '2026-10-05': day(shift('早班', '07:00', '15:00')), '2026-10-12': day(shift('晚班', '18:00', '21:00')) };
  assert.equal(M.copyWeeks(source, '2026-10-05', ['2026-10-12'], 'merge').roster['2026-10-12'].entries.length, 2);
  source['2026-10-12'] = day(shift('冲突', '10:00', '18:00'));
  assert.throws(() => M.copyWeeks(source, '2026-10-05', ['2026-10-12'], 'merge'), /时间重叠/);
});
test('复制检查目标周以外的跨夜班次', () => {
  const source = { '2026-10-05': day(shift('早班', '07:00', '15:00')), '2026-10-11': day(shift('夜班', '22:00', '10:00', true)) };
  assert.throws(() => M.copyWeeks(source, '2026-10-05', ['2026-10-12'], 'replace'), /时间重叠/);
});
test('重复按指定周一范围展开，不无限延长', () => {
  const targets = M.weeklyTargets('2026-10-05', '2026-10-12', '2026-10-26');
  assert.equal(targets.length, 3); assert.equal(targets[2], '2026-10-26');
  assert.throws(() => M.weeklyTargets('2026-10-05', '2026-10-13', '2026-10-26'), /周一/);
  assert.throws(() => M.copyWeeks({}, '2026-10-05', [], 'keep'), /目标周/);
});
test('两个内联脚本语法正确且无外部依赖', () => {
  for (const script of html.matchAll(/<script[^>]*>([\s\S]*?)<\/script>/g)) new vm.Script(script[1]);
  assert.equal(/<script[^>]+src=|<link[^>]+href=["']https?:/.test(html), false);
});
// Execute rendering and handlers with a minimal in-memory DOM adapter.
// This validates view/state paths, not actual browser layout or hit-testing.
const nodes = new Map();
const handlers = {};
const fields = {};
const node = id => {
  if (!nodes.has(id)) nodes.set(id, {
    innerHTML: '', textContent: '', childElementCount: 0,
    replaceChildren() { this.innerHTML = ''; this.childElementCount = 0; },
    contains() { return false; }, querySelector() { return null; },
    querySelectorAll() { return []; }, scrollIntoView() {},
    classList: { toggle() {} }
  });
  return nodes.get(id);
};
const modal = node('modal-root');
modal.querySelectorAll = selector => {
  if (selector === '.segment-editor') {
    return [...modal.innerHTML.matchAll(/<div class="segment-editor">([\s\S]*?)<\/label><\/div>/g)].map(match => ({ querySelector(selector) {
      if (selector === '.seg-next') return { checked: /class="seg-next" checked/.test(match[1]) };
      const attr = selector === '.seg-start' ? 'seg-start' : 'seg-end';
      return { value: match[1].match(new RegExp('class="' + attr + '"[^>]*value="([^"]+)"'))[1] };
    } }));
  }
  if (selector === '.copy-target:checked') return [...modal.innerHTML.matchAll(/class="copy-target"[^>]*value="([^"]+)" checked/g)].map(match => ({ value: match[1] }));
  return [];
};
modal.querySelector = selector => {
  if (selector === 'input[name=strategy]:checked') return { value: 'keep' };
  if (selector === '#personal-kinds .active') return { dataset: { kind: '运动' } };
  return null;
};
const documentAdapter = {
  activeElement: null,
  getElementById(id) {
    if (Object.hasOwn(fields, id)) return { value: fields[id] };
    return node(id);
  },
  querySelectorAll() { return []; },
  addEventListener(name, fn) { handlers[name] = fn; }
};
const uiSource = html.match(/<script id="prototype-ui">([\s\S]*?)<\/script>/)[1];
const context = vm.createContext({ document: documentAdapter, requestAnimationFrame: fn => fn(), setTimeout: () => 1, clearTimeout() {} });
vm.runInContext(modelSource + '\n' + uiSource, context);
function click(action, data = {}) {
  const button = { dataset: { action, ...data }, disabled: false };
  handlers.click({ target: { closest: () => button } });
}
test('初始周班表正确渲染并保留未安排日期', () => {
  assert.match(node('app').innerHTML, /周班表/);
  assert.match(node('app').innerHTML, /工作 5 天 · 休息 1 天/);
  assert.match(node('app').innerHTML, /1 天未安排/);
});
test('同日新增晚班、保存、翻周不会默认重复', () => {
  click('edit-day', { date: '2026-10-09' });
  click('apply-preset', { date: '2026-10-09', id: 'p4' });
  assert.match(node('app').innerHTML, /有未保存的班表修改/);
  assert.match(modal.innerHTML, /18:00–21:00/);
  click('close'); click('save-week'); click('next');
  assert.match(node('app').innerHTML, /7 天未安排/);
  click('previous');
  assert.match(node('app').innerHTML, /18:00–21:00/);
  assert.match(node('app').innerHTML, /本周已保存/);
});
test('重复添加工作班次提示冲突，不污染当前班表', () => {
  click('edit-day', { date: '2026-10-09' });
  click('apply-preset', { date: '2026-10-09', id: 'p1' });
  assert.match(node('form-error').textContent, /时间重叠/);
  assert.match(node('app').innerHTML, /本周已保存/);
});
test('修改常用班次不改动已经应用的班次时间', () => {
  click('view', { view: 'presets' }); click('edit-preset', { id: 'p1' });
  fields['entry-name'] = '白班新版'; fields['entry-color'] = '#83a8d5';
  modal.innerHTML = modal.innerHTML.replace('value="08:30"', 'value="08:00"');
  click('save-preset', { id: 'p1', date: '' });
  assert.match(node('app').innerHTML, /白班新版/);
  click('view', { view: 'week' });
  assert.match(node('app').innerHTML, /08:30–12:00/);
  assert.doesNotMatch(node('app').innerHTML, /白班新版/);
});
test('复制整周进入下一周，未知日不自动补齐', () => {
  click('copy'); assert.match(modal.innerHTML, /不复制个人安排/);
  click('perform-copy');
  assert.match(node('app').innerHTML, /10月12日 — 10月18日/);
  assert.match(node('app').innerHTML, /1 天未安排/);
  assert.match(node('app').innerHTML, /本周已保存/);
});
test('个人日程显示在首页时间轴，用户内容安全转义', () => {
  click('view', { view: 'home' }); click('add-schedule');
  assert.match(modal.innerHTML, /个人安排/); assert.match(modal.innerHTML, /工作排班/);
  click('personal');
  fields['personal-title'] = '<新安排>'; fields['personal-date'] = '2026-10-09';
  // The initial sample already has yoga at 19:00. First click warns; second saves.
  click('save-personal'); assert.match(node('form-error').textContent, /已有安排/);
  click('save-personal');
  assert.match(node('app').innerHTML, /&lt;新安排&gt;/);
  assert.match(node('app').innerHTML, /运动 · 个人安排/);
  assert.doesNotMatch(node('app').innerHTML, /<新安排>/);
});
test('其他日期工作录入与恢复样例入口正常', () => {
  click('work-date'); fields['work-date'] = '2026-10-20'; click('go-work-date');
  assert.match(modal.innerHTML, /10月20日 周二/);
  click('reset'); assert.match(node('app').innerHTML, /10月5日 — 10月11日/);
});
console.log(`${passed} prototype tests passed (model + simulated DOM; browser visual review not included).`);
