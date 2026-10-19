# Same-Identity Layered Companions Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 在确认过的造型上实现可独立变化的表情与四段互动，而不是替换成另一种兔熊。

**Architecture:** 保留原造型身体画面，通过统一坐标的五官与耳爪分层装配。纯时间线计算姿态，原型与 ArkUI 共用数学；单时钟调度且严格跟随生命周期。

**Tech Stack:** ArkTS / ArkUI / 原造型透明 PNG / 独立矢量五官 / imagegen / Node / HTML 预览。

**Spec:** docs/plans/2026-10-17-companions-layered-design.md；原四段动作时序以 docs/design/companions-animation-spec-2026-10-16.md 为参照。

## Global Constraints

不重设造型；表情动作可变；不新增设置/声音/触觉权限；不触碰云同步；44vp 固定页头；不将画面裁切/逐帧切换冒充完整分层；保留用户脏工作区，不自动提交。

### Task 1：原造型身体底图与装配资产

Files: entry/src/main/resources/base/media/companions_*；docs/prototype/assets/companions-layered-*；docs/design/companions-layer-map-2026-10-17.md。

- [x] 使用已确认单角色 PNG 局部编辑去除五官，保留原造型与原文件；再生成无耳/爪的身体底图，部件取自同一原始画布。
- [x] 以 120×120 统一画布记录裁切路径、眼鼻嘴坐标和轴点。默认装配与源图比较，body/head PNG 尺寸严格一致。
- [x] 每个角色制作 4 套独立五官，无额外脸部白底；表达平静、察觉、开心、困倦。
- [x] 资源回归通过，浅深原型检查。初稿误用外侧爪已修正为相邻爪，增加约 4vp 间距回归。

### Task 2：纯动作时间线

Files: entry/src/main/ets/util/CompanionNarrative.ets；tools/test/companion-narrative-regression.mjs。

Produces: `companionNarrativeFrame(kind:number, elapsed:number): CompanionScenePose`；`companionNarrativeDuration(kind:number):number`。
`CompanionScenePose` 包含 bubuFace/xiuxiuFace（0..3）、双方 x/y/angle、兔双耳 angle、熊耳 angle、双方 pawX/pawY/pawOpacity；所有默认姿态为 0，默认缩放 1。

- [x] 先写并验证红灯：生产时间线文件缺失；随后完成边界与终态断言。
- [x] 12s / 10s / 8s / 10s 分段插值；对视停留 1.8s，近爪停留约 3.94vp。
- [x] 每毫秒采样测试通过，含有限值、范围、停留、终态及眨眼/耳动。

### Task 3：原型调度与逐动作验收

Files: docs/prototype/companions-layered-2026-10-17.html；tools/design/build-companion-preview.mjs。

- [x] 从生产时间线和 Rig 机械转译，预览仅负责时钟与绘制。
- [x] 四条单独预览、随机待机和暂停，明确为装配/动作预览。
- [x] 标准/100×44 窄尺寸、深浅、四故事关键帧与点击中断均已在浏览器检查；隐藏恢复测试另记录。原生设备仍待验，不以预览代替。

### Task 4：原生组件与生命周期门禁

Files: entry/src/main/ets/component/CompanionsDuo.ets；tools/test/companion-motion-regression.mjs；tools/test/run.mjs；docs/validation/2026-10-17-companions-layered.md。

- [x] 原生分层接线，保留 touch-down/assistive-click 去重、500ms 连击和旧动画身份防护。
- [x] 统一 ambient 时钟；前后台/页签/遮挡取消复位；点击从当前姿态平滑归位，回弹后新排等待。
- [x] 假 Animator 控制方法测试通过：单时钟、旧回调/后台/遮挡无效、连点归位、恢复不补播。
- [x] 技能脚本编译及 offline/debug/release 全通过；两档各 368/0；Debug 280 WARN、Release 278 WARN，低于原 289 基线。设备帧率/接缝未验、音效/触觉未加入。

执行方式：当前会话内执行，不派生 agent；execution 子技能不可用，按上述检查点直接实施。
