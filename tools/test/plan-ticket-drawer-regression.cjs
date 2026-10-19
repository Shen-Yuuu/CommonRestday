/** Production presentation policies/theme plus source wiring, NOT a rendered-device test. */
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const ts = require('D:/local/DevEcoStudio/tools/hvigor/hvigor/node_modules/typescript');
const root = path.resolve(__dirname, '../..');
const cache = new Map();
const source = name => fs.readFileSync(path.join(root, name), 'utf8');
function load(name) {
  if (cache.has(name)) return cache.get(name);
  const module = { exports: {} }; cache.set(name, module.exports);
  const js = ts.transpileModule(source(name + '.ets'), { compilerOptions: {
    module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2020 } }).outputText;
  vm.runInNewContext(js, { module, exports: module.exports, require: p => load(path.posix.normalize(
    path.posix.join(path.posix.dirname(name), p))) });
  return module.exports;
}
const policy = load('feature/src/main/ets/model/SharedPlanPresentation');
const flow = load('feature/src/main/ets/model/SharedPlanFlow');
const pending = flow.initialSharedPlan('pair', 'plan', 'a', 'b', {
  title: '吃饭', kind: 'meal', start: 1200, end: 1260 });
function act(row, actor, action, nextContent = null) {
  const result = flow.evaluateSharedPlanAction(row, { actorUid: actor, action,
    expectedVersion: row.stateVersion, nowMin: 1000, nextContent });
  assert.equal(result.code, 'OK'); return result.record;
}
const accepted = act(pending, 'b', 'ACCEPT');
const amended = act(accepted, 'a', 'AMEND', { title: '晚餐', kind: 'meal', start: 1300, end: 1380 });
let count = 0;
function test(name, work) { work(); count++; console.log('PASS ' + name); }
test('confirmed drawer order is export / amend / cancel for both members', () => {
  for (const actor of ['a', 'b']) assert.deepEqual(Array.from(policy.sharedDrawerActions(accepted, actor),
    p => [p.action, p.enabled]), [['EXPORT', true], ['AMEND', true], ['CANCEL', true]]);
  assert.equal(policy.sharedInlineActions(accepted, 'a').length, 0);
});
test('pending amendment retains original occupancy and disables duplicate amendment only', () => {
  assert.deepEqual(Array.from(policy.sharedDrawerActions(amended, 'b'), p => [p.action, p.enabled]),
    [['EXPORT', true], ['AMEND', false], ['CANCEL', true]]);
  assert.deepEqual(Array.from(policy.sharedInlineActions(amended, 'b')), ['ACCEPT', 'DECLINE']);
  assert.deepEqual(Array.from(policy.sharedInlineActions(amended, 'a')), ['WITHDRAW']);
  assert.equal(flow.sharedPlanActivity(amended).content.start, accepted.acceptedContent.start);
});
test('invitation decisions stay inline; terminal, invalid and outsider rows have no drawer', () => {
  assert.deepEqual(Array.from(policy.sharedInlineActions(pending, 'b')), ['ACCEPT', 'DECLINE']);
  assert.deepEqual(Array.from(policy.sharedInlineActions(pending, 'a')), ['WITHDRAW']);
  for (const row of [pending, act(accepted, 'a', 'CANCEL'), { ...accepted, acceptedRevision: 0 }])
    assert.equal(policy.sharedDrawerActions(row, 'a').length, 0);
  assert.equal(policy.sharedDrawerActions(accepted, 'outsider').length, 0);
});
function luminance(hex) {
  const rgb = hex.replace('#', '').match(/../g).map(x => parseInt(x, 16) / 255)
    .map(x => x <= .04045 ? x / 12.92 : ((x + .055) / 1.055) ** 2.4);
  return .2126 * rgb[0] + .7152 * rgb[1] + .0722 * rgb[2];
}
test('lavender ticket and drawer text have at least 4.5:1 contrast in both themes', () => {
  for (const mode of ['base', 'dark']) {
    const colors = Object.fromEntries(JSON.parse(source(`entry/src/main/resources/${mode}/element/color.json`))
      .color.map(c => [c.name, c.value]));
    for (const [ink, bg] of [['plan_ink', 'plan_surface'], ['plan_muted', 'plan_surface'],
      ['drawer_calendar_ink', 'drawer_calendar_bg'], ['drawer_cancel_ink', 'drawer_cancel_bg']]) {
      assert.ok(colors[ink] && colors[bg], `${mode}: ${ink}/${bg} must exist`);
      const a = luminance(colors[ink]), b = luminance(colors[bg]);
      assert.ok((Math.max(a, b) + .05) / (Math.min(a, b) + .05) >= 4.5, `${mode}: ${ink}/${bg}`);
    }
  }
});
test('native drawer has equal-height panels, explicit cancellation and no full-swipe deletion', () => {
  const panel = source('entry/src/main/ets/component/SharedPlansPanel.ets');
  assert.ok(panel.includes('.swipeAction('));
  assert.ok(panel.includes('SwipeEdgeEffect.None'));
  assert.ok(panel.includes('.height(this.cardHeight)'));
  assert.ok(panel.includes('this.closeDrawer()'));
  assert.ok(panel.includes('sharedInlineActions('));
  assert.ok(panel.includes('sharedDrawerActions('));
  assert.ok(panel.includes('danger: action === SharedPlanAction.CANCEL'));
  assert.equal(/onAction:|actionAreaDistance:/.test(panel), false);
  assert.equal(panel.includes('.bindMenu('), false, 'user requested swipe-only management');
  assert.equal(panel.includes("Button('⋯')"), false, 'no ellipsis button remains');
  assert.ok(panel.includes('this.cardRow.stateVersion === row.stateVersion'), 'dialog callbacks reject stale rows');
  assert.ok(panel.includes('(row !== null && !this.rowCurrent(row))'), 'confirmed callbacks recheck mounted row before writes');
});
test('compact card uses time-only subtitle with full dates retained for accessibility', () => {
  const panel = source('entry/src/main/ets/component/SharedPlansPanel.ets');
  assert.ok(panel.includes('.constraintSize({ minHeight: 92 })'));
  assert.ok(panel.includes('DateLabel.endLabel(content.start, content.end)'));
  assert.ok(panel.includes('Text(this.timeRange(arg.row))'));
  assert.ok(panel.includes('.accessibilityText(this.timeRead(arg.row))'));
  const local = source('entry/src/main/ets/view/PlansView.ets');
  assert.ok(local.includes('Text(DateLabel.endLabel(arg.p.start, arg.p.end)'));
  assert.ok(local.includes('.accessibilityText(this.subLabel(arg.p))'));
});
test('shared card is a direct native list child; one reader and existing pull-refresh remain', () => {
  const view = source('entry/src/main/ets/view/PlansView.ets');
  assert.ok(view.includes('ListScroller = new ListScroller()'));
  assert.ok(view.includes('closeDrawer: () => this.planScroller.closeAllSwipeActions()'));
  assert.equal(/ListItem\(\)\s*\{\s*SharedPlansPanel\(\{ cardRow/.test(view), false);
  const panel = source('entry/src/main/ets/component/SharedPlansPanel.ets');
  assert.ok(panel.includes('if (this.cardRow !== null) return;'), 'cards do not read/authenticate on mount');
  assert.ok(view.includes('secureSharedPlans().refresh()'));
});
test('calendar modes share lavender builder; short blocks omit time; busy/free colors remain separate', () => {
  const view = source('entry/src/main/ets/component/WeekScheduleView.ets');
  assert.ok(view.includes('if (item.kind === \'PLAN\')'));
  assert.ok(view.includes('this.planBlock({ plan: plan, day: ed })'));
  assert.ok(view.includes('DesignTokens.planSurface'));
  assert.ok(view.includes('DesignTokens.planAccent'));
  assert.ok(view.includes('this.blockH(arg.plan.start, arg.plan.end) >= 42'));
  assert.equal(view.includes('.border({ width: 1.5, color: plan.color })'), false);
  assert.ok(view.includes('DesignTokens.busyMineGlass'));
  assert.ok(view.includes('conflicted: it.conflicted'), 'day clipping retains conflict marker');
});
test('date ticket is reused by local and cloud cards and uses canonical date semantics', () => {
  const tile = source('entry/src/main/ets/component/PlanDateTicket.ets');
  assert.ok(tile.includes('DateLabel.ymd('));
  assert.ok(tile.includes('dayOfStart(this.start)'));
  assert.ok(tile.includes('DateLabel.weekday('));
  assert.ok(tile.includes('if (this.start >= 0)'), 'no fake epoch date for invitations whose content was cleared');
  for (const file of ['component/SharedPlansPanel.ets', 'view/PlansView.ets'])
    assert.ok(source('entry/src/main/ets/' + file).includes('PlanDateTicket({ start:'));
});
console.log(`plan-ticket-drawer: ${count} passed, 0 failed (policies/theme/wiring; NOT device evidence)`);
