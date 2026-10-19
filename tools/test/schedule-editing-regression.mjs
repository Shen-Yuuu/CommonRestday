/** 页面接线检查；设备触摸、键盘与启动页观感由用户验收。 */
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
const repo = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '../..');
const read = p => fs.readFileSync(path.join(repo, p), 'utf8');
const cycle = read('entry/src/main/ets/pages/CycleEditor.ets');
assert.match(cycle, /WeeklyRosterView/);
assert.doesNotMatch(cycle, /weekdaysMask|templatePreview|REST_IN_SEQ|saveTemplate/,
  '旧循环编辑入口复用周班表，不再保存连续轮转序列');
const weekly = read('entry/src/main/ets/component/WeeklyRosterView.ets');
assert.match(weekly, /ForEach\(\[0,1,2,3,4,5,6\]/);
assert.match(weekly, /copyRosterWeek/);
assert.match(weekly, /saveDays\(owner,this\.days/);
const day = read('entry/src/main/ets/component/DayShiftSheet.ets');
assert.match(day, /selectedDay: number/);
assert.match(day, /showDatePickerDialog/);
assert.match(day, /LatestLanding/);
assert.match(day, /this\.landing\.isCurrent\(token\)/);
assert.match(day, /const day=this\.selectedDay,owner=this\.owner/);
assert.match(day, /this\.saving \|\| this\.loading \|\| this\.failed/);
assert.match(day, /rosterSnapshot/);
assert.match(day, /next\.entries\.push\(snapshot\)/);
assert.match(day, /saveDays\(owner,\[this\.day\]/);
assert.match(day, /commitImmediately/);
assert.doesNotMatch(day, /(?:setDayShift|clearDayShift)\(/);
assert.match(day, /\.height\(this\.editorHeight\(\)\)/, '长班次编辑有独立于 FIT_CONTENT 的明确测量高度');
assert.match(day, /Scroll\(\)\{this\.shiftSelection\(\)\}\.width\('100%'\)\.layoutWeight\(1\)/,
  '列表占用扣除安全页脚后的剩余空间，不能再与 FIT_CONTENT 相互依赖测高');
const detail = read('entry/src/main/ets/component/DayDetailSheet.ets');
const detailBody = detail.slice(detail.indexOf('  build()'), detail.indexOf('  windowRow('));
assert.doesNotMatch(detailBody, /\.height\('100%'\)|\.layoutWeight\(1\)/,
  '日详情和嵌套改班都不能把少量内容强制撑满全屏');
assert.match(detailBody, /\.height\(LayoutPolicy\.wrapContent\)\s*\.flexShrink\(1\)/,
  '日详情正文随内容增长，超出可用高度时收缩为滚动区');
assert.match(detailBody, /\.flexShrink\(0\)/, '长正文不能把页头操作挤掉');
const cotime = read('entry/src/main/ets/view/CoTimeView.ets');
const cotimeDaySheet = cotime.slice(cotime.indexOf('.bindSheet($$this.dayVisible'), cotime.indexOf('.bindSheet($$this.sheetVisible'));
const hub = read('entry/src/main/ets/view/ScheduleHub.ets');
assert.doesNotMatch(hub, /临时调整|openToday|sheetOpen|title: '循环模板'/);
assert.match(hub, /WeekScheduleView\(\{ owner: this\.side/);
assert.match(hub, /onPickDay: \(epochDay: number\) => this\.openDay\(epochDay\)/);
assert.match(hub, /DayShiftSheet\(\{ owner: this\.side, epochDay: this\.dayEpoch/);
assert.match(hub, /text: '我的班表'/);
assert.doesNotMatch(hub, /WeeklyRosterView|hasDraft|hasWrite/);
const entries = hub.slice(hub.indexOf('const MAIN_ENTRIES'), hub.indexOf('/** 日程录入页'));
assert.match(entries, /title: '周班表'/);
assert.match(entries, /title: '课程表'/);
assert.doesNotMatch(entries, /常用班次|ScheduleEditor/);
assert.doesNotMatch(weekly, /Text\('周班表'\)|Button\('常用班次'\)|pages\/ScheduleEditor/);
assert.match(cycle, /sys\.symbol\.chevron_left/);
assert.match(cycle, /Text\('常用班次'\)/);
assert.match(cycle, /pages\/ScheduleEditor/);
assert.match(cycle, /ownerParam\(this\.owner\)/);
assert.match(weekly, /WeekNavigator\(\{/);
assert.match(read('entry/src/main/ets/component/WeekScheduleView.ets'), /WeekNavigator\(\{/);
const navigator = read('entry/src/main/ets/component/WeekNavigator.ets');
assert.match(navigator, /@Prop horizontalOffset:/);
assert.doesNotMatch(navigator, /@Prop offset:/, 'offset 是 CustomComponent 原生方法，不能用作数值属性');
assert.match(navigator, /accessibilityText\('查看上一周'\)/);
assert.match(navigator, /accessibilityText\('查看下一周'\)/);
assert.match(cycle, /if \(this\.dirty\) askConfirm/);
assert.match(cycle, /onBackPress\(\)/);
const hubSheet = hub.slice(hub.indexOf('.bindSheet($$this.dayVisible'));
const weeklySheet = weekly.slice(weekly.indexOf('.bindSheet($$this.sheetVisible'));
for (const host of [cotimeDaySheet, hubSheet, weeklySheet.replaceAll(':SheetSize', ': SheetSize').replaceAll(':[SheetSize', ': [SheetSize').replaceAll(':SheetType', ': SheetType')]) {
  assert.match(host, /height: SheetSize\.FIT_CONTENT/);
  assert.match(host, /detents: \[SheetSize\.FIT_CONTENT\]/);
  assert.match(host, /preferType: SheetType\.BOTTOM/);
  assert.doesNotMatch(host, /detents: \[SheetSize\.(?:MEDIUM|LARGE)/,
    '日详情／改班入口不能仍使用固定半屏或近全屏档');
}
const editor = read('entry/src/main/ets/pages/ScheduleEditor.ets');
assert.equal((editor.match(/\.bindSheet\(/g) ?? []).length, 1, '只保留班次编辑面板，不新增应用内选色面板');
assert.match(editor, /detents: \['72%'\]/);
assert.doesNotMatch(editor.slice(editor.indexOf('List({'), editor.indexOf('.bindSheet(')), /if \(this\.editing != null\)/,
  '编辑器不得仍嵌在列表末尾');
const shiftForm = editor.slice(editor.indexOf('  shiftForm()'), editor.indexOf('  editorSheet()'));
assert.match(shiftForm, /HdsColorPicker\(\{[\s\S]*initialColor: this\.pickerInitialColor/,
  '原生调色入口必须直接出现在班次表单');
assert.equal((editor.match(/HdsColorPicker\(\{/g) ?? []).length, 1);
assert.match(shiftForm, /onColorSelected: \(c: string\) => \{\s*if \(this\.editorVisible && !this\.submitting\) \{\s*this\.color = c;\s*this\.pickerInitialColor = c;/,
  '系统选色只更新当前编辑草稿，关闭编辑或保存中不能回写');
const customSlot = shiftForm.match(/Stack\(\{ alignContent: Alignment\.Center \}\) \{([\s\S]*?)\n {8}\}\.width\(44\)\.height\(44\)/);
assert.ok(customSlot, '系统调色入口放入与预设色同尺寸的 44vp 居中格子');
assert.match(customSlot[1], /HdsColorPicker\([\s\S]*\.width\(26\)\.height\(26\)\.enabled\(!this\.submitting\)/,
  '系统按钮本体按圆的尺寸居中，不能放大外框却让内部圆停在左上角');
assert.doesNotMatch(customSlot[1], /\.onClick\(/, '居中容器不得添加点击拦截层');
assert.doesNotMatch(editor, /colorPicking|colorDraft|colorPickerSheet|openColorPicker|applyColor|使用此颜色/,
  '删除应用内第二层面板、按钮和状态');
assert.match(editor, /this\.color = st\.color;\s*this\.pickerInitialColor = st\.color;/,
  '每次打开班次，都使用该班次的初始颜色');
assert.match(editor, /if \(this\.submitting\)/);
assert.match(editor, /name: this\.name, color: this\.color/, '只有保存班次把颜色写入模型');
const header = read('entry/src/main/ets/component/FadingHeader.ets');
assert.equal((header.match(/ScrollHeaderMotion\.titleScale\(this\.visual\.offset, this\.reduceMotion\)/g) ?? []).length, 2,
  '标题与日期使用同一缩放算法');
const home = read('entry/src/main/ets/view/HomeView.ets');
assert.match(home, /HeaderDateBadge\(\{/);
assert.doesNotMatch(home, /headerVisual\.offset/);
const me = read('entry/src/main/ets/view/MeView.ets');
assert.match(me, /this\.shareLevel === lv \? DesignTokens\.shareSelectedBg/);
assert.match(me, /Row\(\{ space: 8 \}\) \{\s*Text\('最短共同时段'\)/);
const entry = read('entry/src/main/ets/component/ScheduleEntrySheet.ets');
assert.match(entry, /savePersonal\(OWNER_ME/);
assert.doesNotMatch(entry, /PlanUseCase|SharedPlanUseCase|propose\(/);
assert.match(home, /ScheduleEntrySheet/);
assert.match(editor, /TimeSegmentsEditor/);
assert.equal((weekly.match(/\.bindSheet\(/g) ?? []).length, 1, '周班表只绑定一个底部面板，避免同节点绑定相互覆盖');
console.log('schedule-editing-regression: PASS（周班表/多班分段/移除临时调整/个人安排/系统调色/日期缩放/作息接线）');
