/** 源码接线检查，不把点击/动画的设备效果当作已验收。 */
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '../..');
const read = (p) => fs.readFileSync(path.join(root, p), 'utf8');
const nav = read('entry/src/main/ets/navigation/AppNavigator.ets');
for (const symbol of ['house', 'heart', 'person']) {
  assert.match(nav, new RegExp("icon: \\$r\\('sys\\.symbol\\." + symbol
    + "'\\), selectedIcon: \\$r\\('sys\\.symbol\\." + symbol + "_fill'\\)"),
    'Dock 线框和实心图标必须保持同族：' + symbol);
}
assert.match(nav, /selectedIcon: Resource/);
assert.match(nav, /SymbolGlyph\(this\.activeTab === item\.tab \? item\.selectedIcon : item\.icon\)/);
assert.match(nav, /fontColor\(\[this\.activeTab === item\.tab \? \$r\('app\.color\.brand_pink'\)/,
  '选中仍使用原玫红色');
const select = nav.slice(nav.indexOf('  private selectTab('), nav.indexOf('  private pressTab('));
assert.doesNotMatch(select, /animateTo/, '不把切换整个页面放进按压动画');
assert.match(nav, /\.animationDuration\(0\)/, '关闭内容区切换动画');
assert.match(nav, /stopPropagation\(\)/, '自制条目隔离系统页签点击反馈');
const planSheet = read('entry/src/main/ets/component/WindowDetailSheet.ets');
const bunnyStart = planSheet.indexOf("        Image($r('app.media.xiuxiu_peek'))");
assert.ok(bunnyStart >= 0, '使用已确认造型的新版透明休休素材');
const bunny = planSheet.slice(bunnyStart, planSheet.indexOf(".accessibilityLevel('no')", bunnyStart));
assert.doesNotMatch(bunny, /\.shadow\(|\.backgroundColor\(|\.border\(/, '透明兔子不绘制矩形投影或底框');
assert.match(bunny, /\.width\(PEEK_W\)[\s\S]*\.height\(PEEK_H\)/);
assert.match(bunny, /\.margin\(\{ left: PEEK_LEFT, top: PEEK_MARGIN_TOP \}\)/);
assert.match(planSheet, /const PEEK_MARGIN_TOP: number = -PEEK_OUT \+ PEEK_CARD_DROP;/,
  '兔子的贴边补偿单独调整，不缩短容纳耳朵的透明带');
assert.match(bunny, /\.translate\(\{ y: this\.peekRisen \? 0 : PEEK_RISE_Y \}\)/);
assert.match(bunny, /\.hitTestBehavior\(HitTestMode\.Transparent\)/);
assert.match(bunny, /\.objectFit\(ImageFit\.Contain\)/, '新版兔子等比显示，避免压扁或裁掉耳朵');
const answer = read('entry/src/main/ets/component/QuickAnswerRow.ets');
assert.doesNotMatch(answer, /animateTo/, '答案行不在按下与松开各启动一趟显式动画');
const home = read('entry/src/main/ets/view/HomeView.ets');
assert.match(home, /sheetOpening \|\| this\.sheetVisible/, '异步读取详情期间也禁止重复打开');
assert.ok(/getTodayAgenda\(dayOfStart\(now\)\)/.test(home),
  '今日安排必须把本次读取的 epochMin 用 dayOfStart 换成当天，不能当毫秒传给 todayEpochDay');
assert.doesNotMatch(home, /getTodayAgenda\(todayEpochDay\(now\)\)/);
const today = read('entry/src/main/ets/component/TodayOverview.ets');
assert.match(today, /this\.agenda\.slice\(0, 3\)/);
assert.match(today, /展开今日安排|收起今日安排/);
const query = read('feature/src/main/ets/usecase/ScheduleOverviewQueryService.ets');
assert.match(query, /PLAN_COLOR = '#F0568C'/);
assert.match(query, /getWeekSchedule\(OWNER_ME, epochDay - 1\)/, '今日列表只读我侧，保留昨天开始的夜班');
const me = read('entry/src/main/ets/view/MeView.ets');
assert.match(me, /return '单人模式'/);
assert.doesNotMatch(me, /identitySub\(|Text\('伴侣（本机代录）'\)|Text\('两台手机配对同步'\)/);
const level = me.slice(me.indexOf('  levelBlock()'), me.indexOf('  scheduleCard()'));
assert.doesNotMatch(level, /Radio\(/);
assert.match(level, /accessibilityChecked\(this\.shareLevel === lv\)/);
assert.match(me, /height: this\.detailKind === 'rhythm' \? '46%' : this\.partnerSheetHeight\(\)/,
  '作息面板根据实测反馈略增高，仍不到半屏');
assert.match(me, /rhythmForm\(\)/);
const dock = read('entry/src/main/ets/component/DockFx.ets');
assert.doesNotMatch(dock, /keyframeAnimateTo|iterations: -1/);
assert.match(dock, /onFinish/);
assert.match(dock, /cancel\(\)/);
assert.match(dock, /DockSparkMotion\.next/);
assert.match(dock, /crd_app_foreground/);
assert.match(dock, /@Watch\('onPlaybackChanged'\)/);
assert.match(dock, /crd_root_page_visible/);
assert.match(nav, /onNavBarStateChange/);
const ability = read('entry/src/main/ets/entryability/EntryAbility.ets');
assert.match(ability, /onForeground\(\): void \{\s*publishForeground\(true\)/);
assert.match(ability, /onBackground\(\): void \{\s*publishForeground\(false\)/);
assert.match(ability, /onDestroy\(\): void \{\s*publishForeground\(false\)/);
const rootPage = read('entry/src/main/ets/pages/Index.ets');
assert.match(rootPage, /onPageHide\(\): void \{\s*AppStorage\.setOrCreate<boolean>\('crd_root_page_visible', false\)/);
console.log('ui-refinement-regression: PASS（结构接线；视觉待设备）');
