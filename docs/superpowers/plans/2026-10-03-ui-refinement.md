# 首页与设置交互精简 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [x]`) syntax for tracking.
>
> 本机未提供上述两个执行技能。本次按用户授权在当前会话逐项实施、验证，不启动子代理、不自动提交工作树。

**Goal:** 实施已确认的 1–8 项界面调整，9–10 保留设计建议。

**Architecture:** 现有页面增量修改；新建可测试的今日日程投影和粒子参数模型。现有概览服务只补读取和标识，不改数据库或云协议。

**Tech Stack:** ArkTS/ArkUI、UIDesignKit HdsTabs、API 26 animator、离线 Hypium runner、Hvigor。

**Spec:** `docs/plans/2026-10-03-ui-refinement-design.md`

## Global Constraints

- API 26；不操作设备、不部署云端、不删除数据、不修改签名。
- 不提交/覆盖已有用户 WIP；不修改共享等级数值或协议，不读取 TA 私有日程。
- 默认三条日程，可展开；作息 sheet 38% 屏高，热区至少 44vp；减少动效停粒子。
- 视觉验收标待用户测试，不以静态断言冒充设备证据。

## Task 1：单次点击反馈

**Files:** `entry/src/main/ets/navigation/AppNavigator.ets`、`entry/src/main/ets/component/QuickAnswerRow.ets`、`entry/src/main/ets/view/HomeView.ets`、`tools/test/ui-refinement-regression.mjs`。

**Interfaces:** 保留 `selectTab(tab: number): void`、`QuickAnswerRow.onTap: () => void` 与原有 sheet 打开动作。

- [x] 静态测试先断言 Dock 切页不使用 animateTo，HdsTabs `.animationDuration(0)`；答案 `press` 不启动 animateTo。
  ```js
  assert.doesNotMatch(selectTabSource, /animateTo/);
  assert.match(navSource, /animationDuration\(0\)/);
  assert.doesNotMatch(answerPressSource, /animateTo/);
  ```
- [x] `node tools/test/ui-refinement-regression.mjs` 先红。
- [x] 改为直接 `goTab(tab)`；缩放只改变被按下项。答案按下直接写状态，释放透明度局部淡出，不给整张卡/页面添动画；sheet 可见时重复打开直接 return。
- [x] 重跑静态断言、press 审计，设备验收列双项闪层/两次闪烁为待测。

## Task 2：今日安排投影与时间轴

**Files:** 新建 `feature/src/main/ets/model/TodayAgenda.ets`；修改 `feature/Index.ets`、`feature/src/main/ets/usecase/ScheduleOverviewQueryService.ets`、`entry/src/main/ets/view/HomeView.ets`、`entry/src/main/ets/component/TodayOverview.ets`；新增 `entry/src/test/TodayAgendaTest.ets` 并注册到 `entry/src/test/List.test.ets`，同步离线 barrel `tools/test/run.mjs`。

**Interfaces:** `AgendaSource { id: string; start: number; end: number; name: string; kind: string }`；`TodayAgendaItem { id: string; timeText: string; name: string; kind: string }`；`buildTodayAgenda(sources: AgendaSource[], epochDay: number): TodayAgendaItem[]`；`ScheduleOverviewQueryService.getTodayAgenda(epochDay: number): Promise<TodayAgendaItem[]>`。

- [x] 新测试覆盖今天交集、结束零点、跨天、排序、空/无效、排除恢复；先运行 `node tools/test/run.mjs` 观察缺模型失败。
  ```ts
  expect(buildTodayAgenda([{ id: 'p', start: 540, end: 660, name: '上课', kind: 'COURSE' }], 0)[0].timeText)
    .assertEqual('09:00–11:00');
  ```
- [x] 纯投影按真实区间筛选并调用 DateLabel；现有 WeekBlock 加稳定来源 ID/类别，查询固定 OWNER_ME；不改 busy 区间计算。
- [x] HomeView 的异步 landing 闸同时保护日程落地，失败说明不冒充空态；TodayOverview 默认 `slice(0, 3)`，用主题色点/标签和展开动作。
- [x] 普通计划 `PLAN_COLOR = '#F0568C'`，班次自选色和冲突色不变。
- [x] 离线测试与静态检查通过，日程排序/跨天/深浅主题人工清单待测。

## Task 3：我的页和紧凑详情

**Files:** `entry/src/main/ets/view/MeView.ets`、`tools/test/me-settings-regression.mjs`、`tools/test/ui-refinement-regression.mjs`。

**Interfaces:** 复用 `openDetails(kind: string)`、`closeDetails()`、`saveMyParams()`、`pickLevel(level: number)`；保存、取消和云重试业务不改。

- [x] 修改旧半屏断言为 38% 高度和直接表单断言，新增标题/无 Radio/整卡点击断言，先红。
  ```js
  assert.match(me, /'38%'/);
  assert.doesNotMatch(levelSource, /Radio\(/);
  assert.match(levelSource, /accessibilityChecked/);
  ```
- [x] 身份标题/备注与共享文案精简；卡片点击原路由，云重试阻止事件冒泡。共享行作为单一可访问按钮，明确选中态。
- [x] 作息打开即填草稿，紧凑四格输入+最短选项，正文滚动、操作固定；不再在 sheet 里套查看卡和编辑按钮。伴侣高度按当前状态扩展。
- [x] 取消关闭重新载入已保存值；保持手动重试；静态与 a11y、copy、press 门禁。

## Task 4：可停止的随机粒子

**Files:** 新建 `commons/src/main/ets/util/DockSparkMotion.ets`、`entry/src/main/ets/util/ForegroundSignal.ets`；修改 `commons/Index.ets`、`entry/src/main/ets/component/DockFx.ets`、`entry/src/main/ets/entryability/EntryAbility.ets`；新增 `entry/src/test/DockSparkMotionTest.ets` 并接入离线 runner。

**Interfaces:** `DockSparkMotion.next(random: number, periodMs: number)` 产生位置/漂移/等待；`publishForeground(active: boolean): void` 写 `crd_app_foreground`。粒子用 `AnimatorResult`，onFinish 在透明时生成下一轮；不建后台定时服务。

- [x] 先断言随机参数边界与非恒定输出，生命周期静态断言 `cancel()`、减少动效/前台 Watch，先红。
- [x] 单轮 animator 保持原移动周期；结束后重置位置与延迟。onFrame 只更新粒子本身，背景/减少动效/销毁时 cancel。
- [x] EntryAbility 仅补前后台发布，不改原初始化/心跳/清理链。栈目的地及 router 页覆盖 Dock 时也停运动（AppNavigator.onNavBarStateChange、Index.onPageShow/onPageHide）。
- [x] 纯参数测试与生命周期静态门禁；粒子连续性和功耗不作离线通过声明。

## Task 5：验证与交接

- [x] `node tools/verify.mjs --steps=offline`：两档 typecheck 与离线用例、各项审计，禁止调高基线。
- [x] 用已有本机 SDK 跑 debug、release 编译；无安装/设备测试。
- [x] 新建 `docs/validation/2026-10-03-ui-refinement-acceptance.md`：记录实际输出及设备手工步骤，失败项如实登记。
- [x] 逐项对照 1–10：1–8 已实现/待设备；9–10 仅方案。所有本批变更保持未提交以避免混入用户 WIP。
