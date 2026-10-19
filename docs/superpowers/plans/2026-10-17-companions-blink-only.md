# Companions Blink Only Implementation Plan

> **For agentic workers:** Inline execution in this session. No delegation or commits over the existing dirty worktree.

**Goal:** 保留完整兔熊造型、自然眨眼和现有点击响应，移除其他页头动画。

**Architecture:** 完整 plate + 开闭眼 SVG；可取消计时器代替 ambient Animator；点击仍使用现有单实例捏压 Animator。

**Tech Stack:** ArkTS / ArkUI，Node regression harness，HTML preview。

**Spec:** docs/plans/2026-10-17-companions-blink-only-design.md

## Global Constraints

- 不改造型、固定 44vp 槽和 100/112vp 宽度；按用户追加要求整体下移 3vp。
- 不加新设置、声音、震动、权限，不触碰云链路。
- 保留用户已有修改，不删除历史素材，不自动提交。

### Task 1: 原生完整造型与精简控制器

**Files:** CompanionActor.ets、CompanionScene.ets、CompanionsDuo.ets、tools/test/companion-motion-regression.mjs。

- [x] 用真实控制器加假时钟检查：待机不创建 Animator，眨眼自动睁眼；隐藏/销毁/点击取消旧回调，快速连点和辅助点击保持正确。
- [x] 执行 `node tools/test/companion-motion-regression.mjs`，先因旧叙事依赖失败，替换实现后通过。
- [x] Actor 只显示完整 plate 和 face 0/3；Scene 固定位置；Duo 双计时器调度并清理。
- [x] 重跑控制器回归和资源回归。

### Task 2: 原型与交付验证

**Files:** docs/prototype/companions-layered-2026-10-17.html、docs/validation/2026-10-17-companions-blink-only.md。

- [x] 原型改为同样完整底图、眨眼和点击，移除四故事及呼吸，保留窄屏/深色检查。
- [x] 运行 ArkTS 技能 `scripts/run.ps1`（配置本地 ohpm/hvigor PATH），执行离线验证；记录真实结果及设备验证边界。
