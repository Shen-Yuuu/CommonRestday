/** Execute production draft methods; source wiring is not device visual acceptance. */
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const root = path.resolve(__dirname, '../..');
const read = file => fs.readFileSync(path.join(root, file), 'utf8');
const ts = require(path.resolve(path.dirname(process.env.CRD_TSC ||
  'D:/local/DevEcoStudio/tools/hvigor/hvigor/node_modules/typescript/bin/tsc'), '..'));
const compile = source => ts.transpileModule(source, {
  compilerOptions: { target: ts.ScriptTarget.ES2020, module: ts.ModuleKind.CommonJS }
}).outputText;
const sheet = read('entry/src/main/ets/component/WindowDetailSheet.ets');
const first = sheet.indexOf('  // ---------- 自定义日期时间');
assert.ok(first >= 0, '缺少原弹窗内自定义日期时间编辑方法');
const methods = sheet.slice(first, sheet.indexOf('  // ---------- 类型与标题', first));
const steps = sheet.slice(sheet.indexOf('  shiftStart(delta:'), first);
const labels = {};
new Function('exports', compile(read('commons/src/main/ets/util/DateLabel.ets')))(labels);
const epochDayOf = (y, m, d) => Math.floor(Date.UTC(y, m - 1, d) / 86400000);
const dayOfStart = min => Math.floor(min / 1440);
const stamp = (y, m, d, h, min = 0) => epochDayOf(y, m, d) * 1440 + h * 60 + min;
const control = {};
new Function('exports', 'DateLabel', 'epochDayOf', 'dayOfStart', 'MIN_PER_DAY', compile(`
export class TimeControl {
  planStart = ${stamp(2026, 10, 16, 9)}; planEnd = ${stamp(2026, 10, 16, 11)};
  mounted = true; foreground = true; saving = false; timeTouched = false;
  draftGeneration = 1; pickerGeneration = 0; customTimeEnd = -1;
  dateOptions: Object | null = null; clockOptions: Object | null = null;
  getUIContext() { return {
    showDatePickerDialog: (options: Object) => { this.dateOptions = options; },
    showTimePickerDialog: (options: Object) => { this.clockOptions = options; }
  }; }
${steps}
${methods}
}`))(control, labels.DateLabel, epochDayOf, dayOfStart, 1440);
const draft = new control.TimeControl();
draft.toggleCustomTime(false);
assert.equal(draft.customTimeEnd, 0);
assert.equal(draft.timeTouched, true, '展开编辑后异步默认时间不能覆盖手动操作');
const quick = new control.TimeControl();
quick.shiftStart(180);
assert.equal(quick.planStart, stamp(2026, 10, 16, 12));
assert.equal(quick.planEnd, stamp(2026, 10, 16, 11), '快捷步进也不提前限制起止先后');
quick.shiftEnd(180);
assert.equal(quick.planEnd, stamp(2026, 10, 16, 14));
quick.saving = true; quick.shiftStart(15); quick.shiftEnd(-15);
assert.equal(quick.planStart, stamp(2026, 10, 16, 12));
assert.equal(quick.planEnd, stamp(2026, 10, 16, 14), '提交中不允许继续修改');
const oldEnd = draft.planEnd;
draft.pickCustomDate(false);
draft.dateOptions.onDateAccept(new Date(2026, 11, 31));
assert.equal(draft.planStart, stamp(2026, 12, 31, 9));
assert.equal(draft.planEnd, oldEnd, '允许起点暂时晚于终点，不联动或回调终点');
draft.pickCustomClock(false);
draft.clockOptions.onAccept({ hour: 23, minute: 47 });
assert.equal(draft.planStart, stamp(2026, 12, 31, 23, 47), '支持非15分钟整格');
draft.toggleCustomTime(true);
draft.pickCustomDate(true);
draft.dateOptions.onDateAccept(new Date(2027, 0, 1));
draft.pickCustomClock(true);
draft.clockOptions.onAccept({ hour: 0, minute: 0 });
assert.equal(draft.planEnd, stamp(2027, 1, 1, 0), '跨年午夜属于实际下一日');
assert.equal(draft.customDateLabel(true), '2027年1月1日');
assert.equal(labels.DateLabel.edgeTime(draft.planEnd, false), '00:00', '编辑器钟面与实际选中日对应');
assert.equal(labels.DateLabel.edgeTime(draft.planEnd, true), '24:00', '区间摘要保持原有终点读法');
assert.match(sheet, /Button\(DateLabel\.edgeTime\(end \? this\.planEnd : this\.planStart, false\)\)/);
assert.equal(draft.planStart, stamp(2026, 12, 31, 23, 47));
const saved = [draft.planStart, draft.planEnd];
draft.pickCustomClock(true); // Cancel: no onAccept.
assert.deepEqual([draft.planStart, draft.planEnd], saved);
draft.clockOptions.onAccept({});
draft.clockOptions.onAccept({ hour: 25, minute: 0 });
draft.clockOptions.onAccept({ hour: 12, minute: NaN });
draft.setCustomTime(true, NaN);
draft.setCustomTime(true, Infinity);
draft.pickCustomDate(true);
draft.dateOptions.onDateAccept(new Date(NaN));
assert.deepEqual([draft.planStart, draft.planEnd], saved, '非法组件值不能污染草稿');
for (const expire of [d => d.mounted = false, d => d.foreground = false, d => d.saving = true,
  d => d.draftGeneration++, d => d.pickerGeneration++, d => d.customTimeEnd = 0]) {
  const d = new control.TimeControl(); d.toggleCustomTime(true); d.pickCustomClock(true);
  const before = d.planEnd; expire(d); d.clockOptions.onAccept({ hour: 20, minute: 30 });
  assert.equal(d.planEnd, before, '过期选择器不能改写草稿');
}
const concurrent = new control.TimeControl(); concurrent.toggleCustomTime(false);
concurrent.pickCustomDate(false); const staleDate = concurrent.dateOptions;
concurrent.pickCustomClock(false); staleDate.onDateAccept(new Date(2027, 0, 1));
assert.equal(concurrent.planStart, stamp(2026, 10, 16, 9));
concurrent.toggleCustomTime(false);
assert.equal(concurrent.customTimeEnd, -1, '同一入口可收起');
assert.doesNotMatch(methods, /planDraftError|winStart|winEnd|Math\.min\(|Math\.max\(/,
  '自定义编辑不提前校验业务范围、不钳制、不修改另一端');

const flow = read('feature/src/main/ets/model/PlanFlow.ets');
const validateSource = flow.slice(flow.indexOf('export function planDraftError('),
  flow.indexOf('/** 能力结果 →'));
const validation = {};
new Function('exports', 'MIN_PLAN_MIN', compile(validateSource))(validation, 15);
const submit = sheet.slice(sheet.indexOf('  async submitPlan():'), sheet.indexOf('  build() {'));
let writes = 0; const notices = [];
const submitControl = {};
new Function('exports', 'planDraftError', 'PLAN_KINDS', 'appToast', 'secureSharedPlans', 'PlanUseCase', compile(`
export class SubmitControl {
  mounted = true; saving = false; title = '旅行'; kindIdx = 0; cloudPlan = false;
  planStart = 100; planEnd = 200; winStart = 100; winEnd = 400;
${submit}
}`))(submitControl, validation.planDraftError, [{ key: 'trip' }], text => notices.push(text),
  () => { writes++; throw new Error('Invalid draft reached cloud'); },
  { createPlan: () => { writes++; throw new Error('Invalid draft reached local'); } });

(async () => {
  for (const cloud of [false, true]) {
    for (const [start, end, message] of [[300, 200, '计划开始需早于结束'],
      [90, 200, '计划时间需在窗口范围内'], [100, 401, '计划时间需在窗口范围内'],
      [100, 110, '计划时长至少 15 分钟']]) {
      const d = new submitControl.SubmitControl(); d.cloudPlan = cloud;
      d.planStart = start; d.planEnd = end;
      await d.submitPlan();
      assert.equal(notices.at(-1), message);
      assert.equal(d.saving, false);
      assert.equal(d.planStart, start); assert.equal(d.planEnd, end);
    }
  }
  assert.equal(writes, 0, '非法草稿不应产生本地或云端写入');
  assert.equal(validation.planDraftError({ title: '旅行', start: draft.planStart, end: draft.planEnd },
    stamp(2026, 12, 31, 0), stamp(2027, 1, 2, 0)), '计划时长至少 15 分钟');
  assert.equal(validation.planDraftError({ title: '旅行', start: draft.planStart, end: draft.planEnd + 2 },
    stamp(2026, 12, 31, 0), stamp(2027, 1, 2, 0)), '');

  assert.match(read('entry/src/main/ets/view/HomeView.ets'), /title: '两人份'/);
  assert.match(read('entry/src/main/ets/navigation/AppNavigator.ets'), /text: '两人份', tab: NavRoutes\.TAB_HOME/);
  const co = read('entry/src/main/ets/view/CoTimeView.ets');
  assert.match(co.slice(co.indexOf('  header()'), co.indexOf('  segmentControl()')), /Text\('共同休时'\)/);
  const body = co.slice(co.indexOf('  windowBody()'), co.indexOf('  detailPane()'));
  assert.doesNotMatch(body, /this\.filterRow\(|Text\('共 '/, '筛选统计不能留在滚动区外');
  const filters = co.slice(co.indexOf('  listFilters()'), co.indexOf('  listContent()'));
  assert.match(filters, /Text\('共 '[\s\S]*?\.fontSize\(12\)/);
  assert.match(filters, /this\.filterRow\(\)/);
  const list = co.slice(co.indexOf('  listContent()'), co.indexOf('  weekContent()'));
  assert.match(list, /List\([\s\S]*?ListItem\(\)\s*\{\s*this\.listFilters\(\)/);
  assert.doesNotMatch(list, /Scroll\(this\.windowScroller\)/, '空态也走同一List，避免滚动容器互换');
  assert.match(list, /edgeEffect\(EdgeEffect\.Spring, \{ alwaysEnabled: true \}\)/);
  const timeForm = sheet.slice(sheet.indexOf('      // ⑤ 起止调节'), sheet.indexOf('      if (this.cloudPlan)', sheet.indexOf('      // ⑤ 起止调节')));
  assert.match(timeForm, /Text\('时间调节'\)/);
  assert.equal((timeForm.match(/Button\('…'\)/g) || []).length, 2);
  for (const end of ['false', 'true']) {
    assert.match(timeForm, new RegExp(`this\\.toggleCustomTime\\(${end}\\)`));
    assert.match(timeForm, new RegExp(`this\\.customTimeEditor\\(${end}\\)`));
  }
  console.log('plan-time-list-regression: PASS（生产时间编辑/延后校验/跨年午夜/取消/过期回调/名称与列表接线；设备视觉待验）');
})().catch(error => { console.error(error); process.exitCode = 1; });
