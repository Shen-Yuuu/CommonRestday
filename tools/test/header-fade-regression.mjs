/** 只验证渐隐颜色端点和页面入口，不替代设备像素验收。 */
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const repo = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '../..');

function matchingTransparentEnd(start, end) {
  return /^#[0-9a-f]{6}$/i.test(start ?? '') && /^#00[0-9a-f]{6}$/i.test(end ?? '')
    && start.slice(1).toUpperCase() === end.slice(3).toUpperCase();
}

assert.equal(matchingTransparentEnd('#FFF0E7', '#00000000'), false, '透明黑不能作暖色渐隐终点');
assert.equal(matchingTransparentEnd('#FFF0E7', '#00FFF0E7'), true);
assert.equal(matchingTransparentEnd('#2E2445', '#002E2445'), true);
assert.equal(matchingTransparentEnd('#2E2445', '#00FFF0E7'), false, '深浅色不能混用');
assert.equal(matchingTransparentEnd('#2E2445', '#882E2445'), false, '终点必须完全透明');

for (const tier of ['base', 'dark']) {
  const file = `entry/src/main/resources/${tier}/element/color.json`;
  const colors = JSON.parse(fs.readFileSync(path.join(repo, file), 'utf8')).color;
  const start = colors.find((c) => c.name === 'page_grad_top')?.value;
  const end = colors.find((c) => c.name === 'page_grad_clear')?.value;
  assert.equal(matchingTransparentEnd(start, end), true, file + '：渐隐必须同 RGB、只减 alpha');
}
const component = fs.readFileSync(path.join(repo, 'entry/src/main/ets/component/FadingHeader.ets'), 'utf8');
const edge = component.slice(component.indexOf('export struct HeaderFadeEdge'),
  component.indexOf('export struct FadingScrollViewport'));
assert.match(edge, /\[DesignTokens\.pageGradClear,\s*1\]/);
assert.doesNotMatch(edge, /Color\.Transparent/);
assert.match(edge, /@ObjectLink visual: ScrollHeaderState/, '只有视觉叶节点观察偏移');
assert.match(edge, /\.opacity\(ScrollHeaderMotion\.edgeOpacity\(this\.visual\.offset\)\)/,
  '内容停在顶部时不能常驻一条遮罩');
const surface = component.slice(component.indexOf('export struct FadingHeaderSurface'),
  component.indexOf('export struct StickyPageHeader'));
assert.doesNotMatch(surface, /backgroundBlurStyle|backgroundEffect|GlassStyle/, '不能再把均匀模糊矩形接到渐变条上');
assert.doesNotMatch(surface, /onAreaChange|onSizeChange|contentHeight|onHeaderHeight|@State/,
  '固定页头不得量高回写布局状态');
assert.match(surface, /Column\(\)[\s\S]*this\.content\(\)[\s\S]*\.backgroundColor\(DesignTokens\.pageGradTop\)/,
  '页头自然量高，渐隐在视口内而非靠高度回写拼接');
const coTime = fs.readFileSync(path.join(repo, 'entry/src/main/ets/view/CoTimeView.ets'), 'utf8');
const week = coTime.slice(coTime.indexOf('  weekContent()'), coTime.indexOf('  plansBody()'));
assert.match(week, /Scroll\(this\.weekScroller\)/);
assert.match(week, /\.height\('100%'\)/, '周历 Scroll 必须具有确定的视口高度');
assert.match(week, /\.edgeEffect\(EdgeEffect\.Spring,\s*\{ alwaysEnabled: true \}\)/);
assert.match(week, /Column\(\)[\s\S]*\.padding\(\{ bottom: DesignTokens\.dockClearance \}\)/,
  '底部留白必须位于滚动内容内');

// 滚动不能再通过 CustomBuilder overlay 重建遮罩；静态 Stack 视口只更新透明度。
for (const [file, count] of [
  ['CoTimeView', 2],
  ['PlansView', 1],
  ['ScheduleHub', 1]
]) {
  const source = fs.readFileSync(path.join(repo, `entry/src/main/ets/view/${file}.ets`), 'utf8');
  assert.doesNotMatch(source, /\.overlay\(/, `${file}：滚动边缘不能使用重建式 overlay`);
  assert.doesNotMatch(source, /@State[^\n]*(?:[fF]adeOpacity|headerOffset|headerHeight)/,
    `${file}：滚动装饰不得写页面状态`);
  assert.doesNotMatch(source, /(?:listVisual|weekVisual|scrollVisual)\.offset/,
    `${file}：正文不得读取 @Track offset，否则重新扩大刷新范围`);
  assert.equal((source.match(/FadingScrollViewport\(\{/g) ?? []).length, count,
    `${file}：所有滚动遮罩都必须放在固定视口节点内`);
}
const viewport = component.slice(component.indexOf('export struct FadingScrollViewport'),
  component.indexOf('export struct FadingHeaderSurface'));
assert.match(viewport, /Stack\([\s\S]*this\.content\(\)[\s\S]*HeaderFadeEdge/);
assert.match(viewport, /\.height\('100%'\)[\s\S]*\.clip\(true\)/, '固定视口明确裁剪，不绘制到置顶栏上');
assert.match(viewport, /HeaderFadeEdge[\s\S]*\.hitTestBehavior\(HitTestMode\.None\)/);
assert.doesNotMatch(viewport, /\bif\s*\(|\.overlay\(/, '渐隐层不得滚动时挂载/卸载');
assert.match(viewport, /@ObjectLink visual: ScrollHeaderState/, '按引用传递，不能复制或替换视觉对象');
assert.doesNotMatch(viewport, /@Prop|visual\.offset/, '正文视口不得读取滚动偏移属性');
const sticky = component.slice(component.indexOf('export struct StickyPageHeader'));
assert.match(sticky, /@ObjectLink visual: ScrollHeaderState/);
assert.match(sticky, /\.opacity\(ScrollHeaderMotion\.subtitleOpacity\(this\.visual\.offset, this\.reduceMotion\)\)/);
assert.doesNotMatch(sticky, /Visibility|\bif\s*\(/, '副标题只淡出，不删行或动态改变高度');
for (const file of ['HomeView', 'MeView']) {
  const source = fs.readFileSync(path.join(repo, `entry/src/main/ets/view/${file}.ets`), 'utf8');
  assert.doesNotMatch(source, /headerOffset|headerHeight|onHeaderHeight|headerVisual\.offset/,
    `${file}：不得形成偏移→标题量高→滚动内容占位回路`);
  assert.match(source, /top:\s*8\b/, `${file}：正文只留 8vp，不补固定标题高度`);
  assert.match(source, /@State private headerVisual: ScrollHeaderState = new ScrollHeaderState\(\)/,
    `${file}：使用稳定对象引用和属性级 Track，不在滚动时重新分配对象`);
  assert.match(source, /FadingScrollViewport\(\{ fadeHeight: 16, visual: this\.headerVisual \}\)/);
  assert.match(source, /Column\(\)\s*\{\s*(?:this\.header\(\)|StickyPageHeader\()/,
    `${file}：页头与正文按上下布局排列，不叠绘标题`);
}
const state = component.slice(component.indexOf('export class ScrollHeaderState'),
  component.indexOf('export struct HeaderFadeEdge'));
assert.match(state, /@Track offset: number = 0/);
assert.match(state, /ScrollHeaderMotion\.visualOffset\(offset\)/);
assert.match(state, /if \(next !== this\.offset\)/, '相同偏移不重复通知');
assert.doesNotMatch(component, /onAreaChange|onSizeChange|onHeaderHeight|contentHeight|\.animation\(|animateTo/,
  '滚动视觉不能回写测量或引入隐式布局动画');
const calendar = fs.readFileSync(path.join(repo, 'entry/src/main/ets/component/WeekScheduleView.ets'), 'utf8');
assert.doesNotMatch(calendar, /\.enabled\(!this\.loading\)/, '加载不能禁用整个周历及切周/重试');
assert.doesNotMatch(calendar, /Text\(this\.loading\s*\?\s*'更新中…'\s*:\s*''\)[\s\S]{0,180}\.height\(20\)/,
  '加载结束不能保留一行空白');
const nav = calendar.slice(calendar.indexOf('  weekNav()'), calendar.indexOf('  axisLine()'));
assert.match(nav, /WeekNavigator\(\{/, '周历与周班表共享一排翻周控件');
const navigator = fs.readFileSync(path.join(repo, 'entry/src/main/ets/component/WeekNavigator.ets'), 'utf8');
assert.match(navigator, /Text\('本周'\)/);
assert.match(navigator, /sys\.symbol\.chevron_left/);
assert.match(navigator, /sys\.symbol\.chevron_right/);
assert.equal((calendar.match(/finally\s*\{\s*if \(this\.landing\.isCurrent\(token\)\)\s*\{\s*this\.loading = false;/g) ?? []).length,
  2, '两种读数成功/失败均收尾，旧请求不能关闭新请求的加载状态');
const commonHead = calendar.slice(calendar.indexOf('  commonHead()'), calendar.indexOf('  laneRow('));
assert.match(commonHead, /\.onClick\([\s\S]*this\.onPickDay\(ed\)/, '共同周历日期表头也可点');

const me = fs.readFileSync(path.join(repo, 'entry/src/main/ets/view/MeView.ets'), 'utf8');
const main = me.slice(me.indexOf('  build() {'), me.indexOf('  private contentPadding()'));
assert.equal((main.match(/this\.dataCard\(\)/g) ?? []).length, 2, '窄屏和宽屏均直接展示数据与隐私');
assert.doesNotMatch(me, /moreSummaryCard|openDetails\('more'\)|更多设置/);
console.log('header-fade-regression: PASS（叶节点观察偏移/无量高回写 + 固定渐隐裁剪 + 周历交互 + 主页隐私）');
