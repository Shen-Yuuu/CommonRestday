# Sticky Gradient Headers Implementation Plan

> **For agentic workers:** 按任务逐项在当前会话执行；本任务不委派、不提交其他人的工作树改动。

**Goal:** 为已确认的四个页面增加清晰的固定标题和克制的渐隐边缘。

**Architecture:** 共用无交互渐隐组件与页头表面；同休/我的通过 Scroller 读取绝对偏移，固定页头按真实内容量高并给正文等高占位。班表工具栏移出滚动正文，共同页保持既有固定工具布局。

**Tech Stack:** ArkTS、ArkUI V1、SDK API 26、Hypium 离线 runner。

**Spec:** `docs/plans/2026-10-01-sticky-gradient-headers-design.md`

## Global Constraints

- 不连接或操作模拟器，不修改用户数据，不提交已有 WIP。
- 保留刷新、双 sheet 独立宿主、侧别参数和周历当前周状态。
- 装饰层 `HitTestMode.None` / `accessibilityLevel('no')`；正文不加前景模糊。
- 使用 `overlay` 时原生最外层必须设 `HitTestMode.Transparent`，内部装饰才设 `None`。
- 所有颜色用现有主题资源；减少动效时标题不缩放。

### Task 1: 滚动口径与共享表面

**Files:** 新增 `commons/src/main/ets/util/ScrollHeaderMotion.ets`、`entry/src/main/ets/component/FadingHeader.ets`；修改 `commons/Index.ets`、`tools/test/run.mjs`、`entry/src/test/PresentationModelsTest.ets`。

**Interfaces:** `ScrollHeaderMotion.progress(offset: number, reduceMotion: boolean): number` 返回 0–1；`HeaderFadeEdge` 接收 fadeHeight；`FadingHeaderSurface` 接收 content Builder、onHeaderHeight；`StickyPageHeader` 接收标题、副标题、滚动偏移、留白与 trailing Builder。

- [x] 加入断言 `progress(-20,false)===0`、`progress(48,false)===0.5`、`progress(200,false)===1`、`progress(200,true)===0`，先运行 `node tools/test/run.mjs` 确认缺少导出导致红灯。
- [x] 实现 `return reduceMotion || !Number.isFinite(offset) ? 0 : Math.min(1, Math.max(0, offset / 96));`，接入 runner 的 commons barrel。
- [x] 表面只模糊背景，页头内容高度经 `onAreaChange` 回传；装饰尾部独立且禁止命中。
- [x] 再跑离线用例，确认新增边界断言通过。

### Task 2: 同休与我的

**Files:** `entry/src/main/ets/view/HomeView.ets`、`MeView.ets`。

- [x] 新增独立 `Scroller`、偏移状态和量高状态；用 `onDidScroll` 读取 `currentOffset().yOffset`，滚动只改变标题缩放，不改变占位高度。
- [x] 根 Stack 中保留 Refresh/Scroll，把页头移动至固定上层，正文顶部留页头实际高度；同休保留日期，问候语移至副标题，我的保留所有摘要卡与详情面板。
- [x] sheet 仍绑在原独立节点，背景只画在页面根节点。

### Task 3: 共同时间与日程录入

**Files:** `entry/src/main/ets/view/CoTimeView.ets`、`ScheduleHub.ets`。

- [x] 共同页 List/周历/PlansView 的滚动区域外层用 Stack 叠 `HeaderFadeEdge`，分别 12/8/12vp，筛选与日期按钮不重排。
- [x] 日程录入页将返回、侧别、视图切换移入固定 FadingHeaderSurface；正文 Refresh/Scroll 占剩余高度，保留原空态与点击回调。

### Task 4: 门禁与交接

**Files:** `docs/validation/2026-10-01-sticky-gradient-headers-acceptance.md`。

- [x] 执行 `node tools/verify.mjs --steps=offline,debug,release,ohostest`，只编译 ohosTest，不在设备上运行。
- [x] 记录真实读数与边界；交接滚动、刷新、深浅切换、2×字体、减少动效、顶部按钮与 sheet 的设备步骤，不将视觉观感标为已验。

### Task 5: 设备截图反馈修订（覆盖早先的模糊拼接方案）

- [x] 灰黑接缝先更换为两档同 RGB 透明端点；随后用户截图显示仍是横向模糊条带，记录该次修订不充分。
- [x] 撤掉 `FadingHeaderSurface` 的矩形系统模糊，用单一底色渐变覆盖量高后的标题区域与 36vp 尾部；新方案不宣称渐变背景模糊。
- [x] 为共同列表、周历、PlansView 的实际 List 及 ScheduleHub 的 Scroll 增加控制器，按绝对偏移更新边缘遮罩透明度：0vp 隐藏、24vp 完整显示。保留筛选、操作行、切周与点击回调。
- [x] 周历 Scroll 限定剩余视口高度，竖向滚动及短内容回弹开启；dock 留白放入内层 Column，不再压在 Scroll 上。
- [x] 新增 `edgeOpacity()` 与 `opaqueStop()` 边界用例，扩充颜色/结构回归并先红后绿；最终离线两档各 269 passed，debug/release/ohosTest 均构建成功。
- [x] 记录本机未操作模拟器；渐隐观感及周历手势留给用户复验，不用编译结果替代。

### Task 6: 周历整块无响应与抬头间距（第三次反馈）

- [x] 核实 SDK `common.d.ts` 的 overlay 约定：最外层需允许穿透；四个渐隐 Builder 补原生 Row 外层、确定高度和 Transparent。
- [x] 删除周历根节点的加载禁用；读数前的昵称读取移入异常保护，成功/失败都由当前请求的 finally 收尾；旧空闲块在更新中不发起计划。
- [x] 日期导航与本周合并；移除常驻空白 20vp，间距 8→4vp；补日期表头点击，保留按钮热区。
- [x] 新增结构回归先红后绿，约束覆盖层外层、加载锁、finally 收尾、紧凑导航与表头点击。该检查不替代设备触摸及像素证据。
- [x] 全量本机门禁 ALL PASS：离线两档各 269 passed；debug/release WARN 287、ohosTest 编译 WARN 267，未上调基线。
- [ ] 用户复验切周、日期/色块、上下滚动、下拉刷新和紧凑抬头。

### Task 7: 用户确认紧凑页头与稳定渐隐节点（覆盖 Task 6 的 overlay 结构）

- [x] 用户确认副标题淡出、不折叠布局，首卡留白约 8vp；实施方案见 `2026-10-01-stable-scroll-headers.md`。
- [x] 删除四处 CustomBuilder overlay，改共享固定 Stack + clip 视口；保留点击穿透、控制器、刷新与 sheet 宿主。
- [x] 同休/我的占位不再含渐隐尾部；尾部改 16vp，副标题接透明度逻辑，减少动效保留副标题。
- [x] 最终本机门禁 ALL PASS：两档各 271 passed；debug/release WARN 287、ohosTest 编译 WARN 267，基线未上调。
- [ ] 用户跨页闪烁复验，不能只靠构建判设备通过。
