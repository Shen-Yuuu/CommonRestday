/** Bounded cleanup guards: no cloud calls or device mutations. */
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
const root = path.resolve(import.meta.dirname, '../..');
const read = p => fs.readFileSync(path.join(root, p), 'utf8');
const entry = read('entry/src/main/ets/component/ScheduleEntrySheet.ets');
assert.doesNotMatch(entry, /自己的日程自己决定|无需 TA 确认|点选可修改/);
assert.match(entry, /仅安排自己的时间/);
for (const action of ['savePersonal(OWNER_ME', 'DayShiftSheet(', 'save()', 'remove(entry)']) assert.ok(entry.includes(action));
const day = read('entry/src/main/ets/component/DayShiftSheet.ets');
assert.doesNotMatch(day, /已标记休息；个人安排不会删除|未安排工作，空闲仍按作息和其他日程计算/);
assert.match(day, /bottom:Math\.max\(12,this\.bottomSafe\+12\)/);
assert.match(day, /this\.safeFooter\(\)/);
const roster = read('entry/src/main/ets/component/WeeklyRosterView.ets');
assert.match(roster, /不影响个人安排/);
assert.match(roster, /历史循环保留，仅替换已编辑日期/);
assert.match(roster, /未安排不占用工作时间/);
const window = read('entry/src/main/ets/component/WindowDetailSheet.ets');
assert.match(window, /双方确认后占用时间/);
assert.match(window, /改期、取消会同步到系统日历/);
assert.match(window, /reviewOriginal/);
const panel = read('entry/src/main/ets/component/SharedPlansPanel.ets');
assert.match(panel, /本机请求，送达结果待核实/);
assert.match(panel, /未确认不新增占用/, 'uncertain amendment must not imply that the original accepted time is free');
assert.match(panel, /关闭未提交请求/);
assert.match(panel, /secureSharedPlans\(\)\.retry\(\)/);
assert.match(panel, /sharedPlanDiagnosticText/);
const me = read('entry/src/main/ets/view/MeView.ets');
assert.match(me, /仅本机可见/);
assert.match(me, /UnifiedPairingStatus\(/);
assert.match(me, /askUnpair\(\)/);
assert.match(me, /SHARE_LEVEL_UNKNOWN/);
assert.match(read('entry/src/main/ets/pages/OcrCourse.ets'), /不会上传|不上传/);
// Preserve legal/permission disclosure; do not hide diagnostics or accessibility to achieve shorter UI.
const strings = JSON.parse(read('entry/src/main/resources/base/element/string.json')).string;
for (const key of ['privacy_point_cloud', 'pp_cloud_b', 'pp_sys_b', 'calendar_perm_reason', 'internet_perm_reason'])
  assert.ok(strings.find(s => s.name === key)?.value.length > 0);
assert.match(read('entry/src/main/ets/view/PlansView.ets'), /!this\.sharedUnresolved && showPlanEmpty/);
const media = 'entry/src/main/resources/base/media/';
const archive = 'docs/prototype/assets/legacy-app-assets-2026-10-17/';
for (const name of ['startIcon.png', 'mascot_peek.svg', 'mascot_peek_bunny.svg', 'mascot_bunny_sleep.svg',
  'companions_peek_b.png', 'companions_bubu_head.png', 'companions_xiuxiu_head.png',
  'companions_bubu_face_1.svg', 'companions_bubu_face_2.svg', 'companions_xiuxiu_face_1.svg', 'companions_xiuxiu_face_2.svg']) {
  assert.ok(!fs.existsSync(path.join(root, media, name)), name + ' is not packaged');
  assert.ok(fs.statSync(path.join(root, archive, name)).size > 0, name + ' historic asset remains available');
}
for (const name of ['bubu', 'xiuxiu']) {
  for (const part of ['plate.png', 'face_0.svg', 'face_3.svg']) assert.ok(fs.existsSync(path.join(root, media, `companions_${name}_${part}`)));
}
assert.ok(!fs.existsSync(path.join(root, 'entry/src/main/ets/component/SecurePairingSetup.ets')));
assert.ok(!fs.existsSync(path.join(root, 'entry/src/main/ets/util/CompanionNarrative.ets')));
assert.doesNotMatch(read('entry/src/main/ets/util/CompanionRig.ets'), /CompanionNarrative|clip:|companionNearPawGap/);
assert.doesNotMatch(read('entry/src/main/ets/util/CompanionMotion.ets'), /companionBreath/);
assert.ok(fs.existsSync(path.join(root, 'tools/design/legacy/CompanionNarrative.ets')));
console.log('conservative-cleanup-regression: PASS (copy, preserved rules/actions, production vs historical assets)');
