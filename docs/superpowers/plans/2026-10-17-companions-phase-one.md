# Companions Phase One Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [x]`) syntax for tracking.

**Goal:** 将已选 B 造型接入共同休时页头并实现生命周期安全的轻呼吸和连击捏压。

**Architecture:** 纯函数 CompanionMotion 计算连击与变换；CompanionsDuo 私有 Animator 驱动独立组件；CoTimeView 仅提供可见性条件和固定占位。原 PNG 不编辑，仅绘制裁切去掉底边残片。

**Tech Stack:** ArkTS / ArkUI AnimatorResult / 本地 PNG / Node TypeScript 转译回归 / HTML 视觉预览。

**Spec:** docs/design/companions-animation-spec-2026-10-16.md；实施边界 docs/plans/2026-10-17-companions-phase-one-design.md。

## Global Constraints

保留现有脏工作区；不提交、发布、安装或改云端；不新增权限、设置和依赖。第一阶段整图呼吸，独立分层动作和声音等待真正资产；固定 112×56vp，窄屏 100vp。

### Task 1: 纯运动模型

Files: `entry/src/main/ets/util/CompanionMotion.ets`, `tools/test/companion-motion-regression.mjs`。

Interfaces: `nextCompanionCombo(previous, lastTap, now)`, `companionSquishSpec(combo, reduce, depthRandom, peakRandom, timeRandom)`, `companionSquishFrame(spec, elapsed, fromX, fromY, fromAngle)`, `companionBreath(progress)`；所有返回值为命名 interface。

- [x] 写回归：`assert.equal(nextCompanionCombo(4, 1000, 1200), 5)`、500/800ms 边界、随机上下限和结尾精确归位。
- [x] 运行 `node tools/test/companion-motion-regression.mjs`，确认缺少实现时失败。
- [x] 实现四段连续插值，5 连击摇摆和减少动态效果幅度上限；无 timer/网络依赖。
- [x] 重跑回归，端点、连续性和所有随机边界必须通过。

### Task 2: 原生页头组件

Files: `entry/src/main/ets/component/CompanionsDuo.ets`, `entry/src/main/ets/view/CoTimeView.ets`, `entry/src/main/resources/base/media/companions_peek_b.png`。

Interfaces: `CompanionsDuo({ active: boolean, availableWidth: number })`；组件自行订阅前台、根页可见、减少动态效果；按压仅变换自身，不广播重算。

- [x] 保存用户原 PNG，使用 `.clip(true)` 局部裁切排除底部碎片；不修改源文件像素。
- [x] 写控制方法回归：换页取消、旧 finish 不重启、重新激活单一实例、减少动态效果只保留克制点击反馈。
- [x] 创建两个独立 Animator 实例分别负责呼吸和点击；取消时先摘掉实例引用，所有回调检查身份和当前可见性。
- [x] header 改 Row，文字 `.layoutWeight(1)`；关闭 `.sheetVisible/.dayVisible` 遮挡时的循环；保持分段和滚动布局。
- [x] 回归加入 `tools/test/run.mjs`，不将假 Animator 测试宣称为设备测试。

### Task 3: 预览与编译

Files: `docs/prototype/companions-motion-2026-10-17.html`, `docs/validation/2026-10-17-companions-phase-one.md`。

- [x] 提供独立 360/390 深浅背景预览及点击反馈，标明 HTML 与原生不完全等效；读取生产模型而非另写参数。
- [x] 浏览器检查无横向溢出、标题不重叠、点击不触发业务动作、裁切边缘正确。
- [x] 运行 ArkTS skill 编译脚本，最多三次失败修复；执行 `node tools/verify.mjs --steps=offline,debug,release`。
- [x] 检查限定文件 diff 与空白；记录通过证据、未完成分层项目和真机手感检查步骤。未经授权不提交整个脏工作区。

执行说明：已获用户按设计文档开发的授权，当前会话内实施；所指 execution 子技能本次未提供，以逐项实现及回归代替，不派生 agent。
