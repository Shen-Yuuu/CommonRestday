# Stable Scroll Headers Implementation Plan

> **For agentic workers:** 在当前会话逐任务执行，不委派、不提交已有工作树改动。技能建议的 superpowers 执行子技能未在本会话提供，使用本计划逐项执行与验证。

**Goal:** 收紧首页留白、实现副标题淡出、移除滚动遮罩动态重建路径。

**Architecture:** 第二轮以自然高度 Column 固定页头；@Track offset 只在标题/渐隐叶节点读取，正文视口不读取偏移；共享 Stack 明确裁剪。第一轮量高方案保留为下方历史，已退役。

**Tech Stack:** ArkTS / ArkUI V1、API 26、Hypium 离线 runner、静态结构回归。

**Spec:** `docs/plans/2026-10-01-stable-scroll-headers-design.md`

## Global Constraints

- 不操作模拟器，不安装/卸载，不清空数据，不改云配对和权限。
- 保留所有既有 WIP，不提交；测试包只编译，不执行设备测试。
- 不通过动态高度/删行隐藏副标题；保留刷新、控制器、切周、双 sheet 独立宿主。
- 不上调告警基线；设备观感与闪烁消失不能用构建成功代替。

## 第二轮实施：仅视觉叶节点观察滚动

本节继续当前会话实施，前一轮勾选仅表示那轮代码工作完成，不表示闪烁验收通过。以 Spec 第二轮修订为准。

### Task 4: 去除量高回环与整页滚动状态

**Files:** `component/FadingHeader.ets`、`view/HomeView.ets`、`MeView.ets`、`CoTimeView.ets`、`PlansView.ets`、`ScheduleHub.ets`、`commons/src/main/ets/util/ScrollHeaderMotion.ets`、`entry/src/test/PresentationModelsTest.ets`、`tools/test/header-fade-regression.mjs`。

**Interfaces:** `ScrollHeaderState.update(offset: number): void`；`ScrollHeaderMotion.visualOffset(offset: number): number`；两个视觉叶节点与视口 `@ObjectLink visual: ScrollHeaderState`（仅叶节点读取 offset）；页面 @State 持有对象，@Track offset 负责属性级更新。

- [x] 写结构断言：HeaderSurface 禁止 onAreaChange/onSizeChange/高度回调；各页面禁止 headerOffset/headerHeight/fadeOpacity 页面数值状态；Home/Me 用 Column + 8vp 正文留白。`node tools/test/header-fade-regression.mjs` 旧实现先红（未按叶节点观察），实现后绿。
- [x] 纯逻辑新增绝对偏移截断与单调前进/回顶断言；实现规范化 offset：

```ts
static visualOffset(offset: number): number {
  return Number.isFinite(offset) ? Math.min(96, Math.max(0, offset)) : 0;
}
```

- [x] 隔离观察对象，页面持有 @State 对象而非偏移数值，叶节点通过 @ObjectLink 读取 @Track offset，视口仅传引用；update 仅在值变化时赋 offset：

```ts
@Observed
export class ScrollHeaderState {
  @Track offset: number = 0;
  update(offset: number): void {
    const next = ScrollHeaderMotion.visualOffset(offset);
    if (next !== this.offset) { this.offset = next; }
  }
}
```

- [x] Home/Me 普通 Column 固定页头，正文视口原生 Column 用 layoutWeight(1)，不留动态顶部占位；保持原刷新/详情面板宿主。
- [x] 四个列表/周历/计划/班表入口使用各自视觉对象，wrapper 不读取 offset；onAppear 与 onDidScroll 只更新对应对象，空态复位为 0。
- [x] 执行全量命令与相关文件 `git diff --check`。默认并发命令因内存/页面文件不足失败；按验收记录的低内存串行参数重新 clean 出包，三档均成功（287/287/267 WARN，不上调基线）；最终 offline 两档各 271 passed / 0 failed。不能将默认全量命令记录为 ALL PASS。
- [x] 记录编译/离线结果，交接跨页连续滚动与大字体复验。不提交 WIP，不操作设备，不声称已经消除现场闪烁。
- [ ] 用户设备复验通过：连续滚动时标题不往复跳大小，停住后稳定，周历切页不扩散。

### Task 1: 紧凑页头与副标题淡出

**Files:** `commons/src/main/ets/util/ScrollHeaderMotion.ets`、`entry/src/main/ets/component/FadingHeader.ets`、`entry/src/main/ets/view/HomeView.ets`、`MeView.ets`、`entry/src/test/PresentationModelsTest.ets`。

**Interfaces:** `subtitleOpacity(offset: number, reduceMotion: boolean): number`；`contentInset(contentHeight: number): number`。

- [x] 写纯逻辑断言并运行 `node tools/test/run.mjs`。首次红灯被结构审计的旧 overlay 拦下，未单独采到这两条逻辑的缺方法红灯；实现后两条均真实通过：

```ts
expect(ScrollHeaderMotion.subtitleOpacity(0, false)).assertEqual(1);
expect(ScrollHeaderMotion.subtitleOpacity(48, false)).assertEqual(0.5);
expect(ScrollHeaderMotion.subtitleOpacity(96, false)).assertEqual(0);
expect(ScrollHeaderMotion.subtitleOpacity(200, true)).assertEqual(1);
expect(ScrollHeaderMotion.contentInset(80)).assertEqual(88);
```

- [x] 实现纯逻辑并接入副标题 opacity；回传内容 height 而非 height+fade，Sticky 的 fadeHeight=16、padding top=16/bottom=0。首页正文 top 使用 contentInset(headerHeight)：

```ts
static subtitleOpacity(offset: number, reduceMotion: boolean): number {
  return 1 - ScrollHeaderMotion.progress(offset, reduceMotion);
}
static contentInset(contentHeight: number): number {
  return (Number.isFinite(contentHeight) ? Math.max(0, contentHeight) : 0) + 8;
}
```

- [x] 运行纯逻辑与结构回归，保留副标题节点、固定量高和减少动效路径。

### Task 2: 四处稳定滚动视口

**Files:** `entry/src/main/ets/component/FadingHeader.ets`、`view/CoTimeView.ets`、`PlansView.ets`、`ScheduleHub.ets`、`tools/test/header-fade-regression.mjs`。

**Interfaces:** `FadingScrollViewport` 接收 fadeHeight（默认 24）、@Prop fadeOpacity（默认 0）及 @BuilderParam content。

- [x] 更新结构断言：四处不得出现 overlay，使用 FadingScrollViewport；视口必须有确定 height、clip(true)，渐隐禁命中且不是条件节点。运行 `node tools/test/header-fade-regression.mjs` 先红。
- [x] 加入共享组件；四处内容保持原结构，只把权重交给原生 Column 宿主，Refresh 占视口 100% 高，移除旧遮罩 Builder：

```ts
Stack({ alignContent: Alignment.Top }) {
  this.content()
  HeaderFadeEdge({ fadeHeight: this.fadeHeight, fadeOpacity: this.fadeOpacity })
    .hitTestBehavior(HitTestMode.None)
}
.width('100%').height('100%').clip(true)
```

自定义组件尾随内容块不能在闭合后链式设属性；尺寸/权重接在原生 Column 上：

```ts
Column() {
  FadingScrollViewport({ fadeHeight: 24, fadeOpacity: this.fadeOpacity }) {
    // 原 Refresh/List/Scroll 内容；Refresh 明确 height('100%')。
  }
}
.width('100%').layoutWeight(1)
```

- [x] 滚动回调只有 opacity 改变时才赋状态，保留 onAppear 恢复偏移；原 List/Scroll 的事件和 sheet 不换宿主。
- [x] 运行结构回归、offline 两档及 `node tools/verify.mjs --steps=offline,debug,release,ohostest`。首轮 debug/release 因尾随块后的链式属性失败；修正后 ALL PASS：两档各 271 passed、debug/release WARN 287、ohosTest 编译 WARN 267，未改基线。

### Task 3: 验收记录与用户交接

**Files:** `docs/validation/2026-10-01-sticky-gradient-headers-acceptance.md`，同步既有设计/计划的最新修订记录。

- [x] 记录静态/离线/编译证据，与未验证的设备结论分开。
- [x] 交接“周历连续拖动→切同休/我的→返回周历”的跨页复验；副标题回顶恢复、首卡间距、切周/日期/色块、下拉刷新、深浅色及 2× 字体均留设备核验。
- [x] 对修改源码执行 `git diff --check`；不操作模拟器、不提交 WIP。
- [ ] 用户完成设备渲染与跨页闪烁复验；该项不属于本机编译的通过结论。
