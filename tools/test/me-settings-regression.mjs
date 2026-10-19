/** 我的页设置结构检查，不代替设备上的高度、键盘和滚动验收。 */
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const repo = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '../..');
const me = fs.readFileSync(path.join(repo, 'entry/src/main/ets/view/MeView.ets'), 'utf8');
assert.doesNotMatch(me, /配对同步需要云服务能力|更多计算设置|this\.advanced\b|advancedHead/,
  '删除云服务冗余说明和计算设置折叠，而非仅藏起入口');
assert.match(me, /height: this\.detailKind === 'rhythm' \? '46%' : this\.partnerSheetHeight\(\)/,
  '作息固定紧凑高度，伴侣按状态扩展');
assert.match(me, /preferType: SheetType\.BOTTOM/);
assert.match(me, /dragBar: false/, '紧凑面板不额外占用系统拖动条的高度');
const sheet = me.slice(me.indexOf('  detailsSheet()'), me.indexOf('  cardHead('));
assert.match(sheet, /Scroll\(\)[\s\S]*\.layoutWeight\(1\)/, '半屏内保留可滚动正文');
assert.match(sheet, /if \(this\.detailKind === 'rhythm'\) \{\s*this\.rhythmSheet\(\)/,
  '作息使用独立布局，不与伴侣和称呼表单共用条件内边距');
const rhythmSheet = sheet.slice(sheet.indexOf('  rhythmSheet()'));
assert.match(rhythmSheet, /Text\('作息设置'\)[\s\S]*?\.fontWeight\(FontWeight\.Bold\)/);
assert.match(rhythmSheet, /Scroll\(\) \{\s*this\.rhythmForm\(\)[\s\S]*?\.layoutWeight\(1\)/);
assert.match(rhythmSheet, /padding\(\{ left: 20, right: 20, top: 20, bottom: 24 \}\)/,
  '标题不贴边，底部按钮给手势区留白');
const rhythm = me.slice(me.indexOf('  rhythmForm()'), me.indexOf('  private minSlotChoices('));
assert.match(rhythm, /this\.calculationForm\(\)/, '编辑态计算参数直接显示');
assert.match(rhythm, /this\.rhythmTimeButton\(false\)/);
assert.match(rhythm, /this\.rhythmTimeButton\(true\)/);
assert.match(rhythm, /Text\(bed \? this\.myBed : this\.myWake\)/,
  '时间读数在 Builder 内直接观察 State，不能把动态时间按值传入后定格');
assert.doesNotMatch(rhythm, /TextInput\(\{ text: this\.my(?:Wake|Bed) \}/, '时间不再自由输入文本');
assert.doesNotMatch(rhythm, /睡前准备\\n|往后计算\\n/, '数值单位不在标签内换行');
assert.match(rhythm, /Text\('睡前准备（分钟）'\)/);
assert.match(rhythm, /Text\('往后计算（天）'\)/);
assert.equal((rhythm.match(/\.width\(80\)\.textAlign\(TextAlign\.End\)\.padding\(\{ left: 0, right: 0 \}\)/g) ?? []).length, 2,
  '两项数字共用右边缘、同宽输入框与零水平内边距');
assert.doesNotMatch(rhythm, /Text\('分钟'\)|Text\('天'\)/, '不能在数字右侧再留一列单位，数字要落在行末');
const picker = me.slice(me.indexOf('  private pickRhythmTime('), me.indexOf('  private pickMinSlot('));
assert.match(picker, /this\.getUIContext\(\)\.showTimePickerDialog\(/);
assert.match(picker, /useMilitaryTime: true/);
assert.match(picker, /onAccept: \(result: TimePickerResult\)/);
assert.match(picker, /!this\.detailsOpen \|\| this\.detailKind !== 'rhythm' \|\| !this\.myEditing \|\| this\.mySaving/,
  '关闭作息或保存中不接收迟到的时间回调');
assert.doesNotMatch(picker, /onChange:|saveMyRhythm|setParams/, '系统选择器仅接受时改草稿，不在滚动时写库');
assert.match(me, /this\.startEditMyParams\(\)/, '打开作息直接编辑草稿');
assert.doesNotMatch(rhythm, /this\.advanced|advancedHead|if \(this\.advanced/);
const form = me.slice(me.indexOf('  calculationForm()'), me.indexOf('  dataCard()'));
assert.match(form, /Text\('最短共同时段'\)/, '直接展开的选项需要可读标签');
assert.match(form, /Row\(\{ space: 8 \}\) \{\s*Text\('最短共同时段'\)/,
  '外层固定横排，不能把整组选项挤到标签下');
assert.match(form, /this\.myMinSlot === v \? DesignTokens\.shareSelectedBg : Color\.Transparent/);
assert.match(form, /this\.myMinSlot === v \? DesignTokens\.textAccent : DesignTokens\.textSecondary/);
assert.match(me, /return v % 60 === 0 \? '' \+ \(v \/ 60\) \+ '小时' : v \+ '分钟'/,
  '选项短标签，至少语义保留在最短时段和无障碍标签中');
assert.match(rhythm, /onChange\(\(v: string\) => \{ this\.myHorizon = v; \}\)/);
assert.match(form, /onClick\(\(\) => this\.pickMinSlot\(v\)\)/);
assert.match(me, /horizonText: this\.myHorizon, minSlotMin: this\.myMinSlot/,
  '计算参数必须继续随作息保存，不只是静态展示');
assert.match(me, /cancelMyEdit\(\): void \{\s*this\.myEditing = false;\s*this\.reloadMyParams\(\)/,
  '取消保留重新读取已保存参数的逻辑');
console.log('me-settings-regression: PASS（46% 作息面板/标题顶部留白/数字行末对齐/系统时间选择/保存取消）');
