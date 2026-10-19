# Plan bunny shadow fix Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 移除计划弹窗小兔子的矩形组件阴影，保留形象及动画。

**Architecture:** 只移除 WindowDetailSheet 中兔子 Image 的 shadow 修饰符，不修改 SVG 或其他节点。

**Tech Stack:** ArkTS / ArkUI、Node 源码回归、DevEco 编译。

**Spec:** docs/plans/2026-10-16-plan-bunny-shadow-design.md

## Global Constraints

- 保留原图、大小、位置和动画；不增加颜色底、边框或图层。
- SDK ShadowOptions.fill 默认 false，不把方框归因为默认内部填充。
- 不操作设备或云端，不自动提交既有修改。执行子技能不可用，当前会话分步执行。

## Task 1: 最小投影修复

Files: tools/test/ui-refinement-regression.mjs、entry/src/main/ets/component/WindowDetailSheet.ets。

- [x] 截取 `Image($r('app.media.mascot_peek_bunny'))` 到 `hitTestBehavior` 的源码，断言不含 `.shadow(`、`.backgroundColor(`、`.border(`，保留 PEEK 尺寸/margin/translate；新增回归先确认失败。
- [x] 删除该节点 `.shadow({ radius: 8, type: ShadowType.COLOR, color: '#245A1E37', offsetX: 0, offsetY: -3 })`，添加矩形投影原因注释，不修改素材。
- [x] UI、反馈动效、时间编辑回归及 ArkTS 技能脚本编译通过；`node tools/verify.mjs --steps=offline,debug,release` ALL PASS，不修改基线。
- [x] 记录静态证据和编译结果、设备待验边界到 docs/validation/2026-10-16-dock-and-bunny.md；`git diff --check` 通过。
