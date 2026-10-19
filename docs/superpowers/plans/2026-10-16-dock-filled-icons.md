# Dock filled icons Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Dock 选中项从线框切换为同族玫红实心图标。

**Architecture:** NavItem 增加 selectedIcon，SymbolGlyph 依据 activeTab 选择资源，不改变 UI 容器、颜色或导航。

**Tech Stack:** ArkTS / ArkUI system symbols、Node 接线回归、DevEco 编译。

**Spec:** docs/plans/2026-10-16-dock-filled-icons-design.md

## Global Constraints

- 未选中保持线框，选中玫红色实心；图标 22fp，占位不变。
- 底栏背景、文字和粒子效果不变；不新增动画或云端改动。
- 保留既有工作区修改，不自动提交。执行子技能不可用，在当前会话分步实施。

## Task 1: 图标资源与验证

Files: entry/src/main/ets/navigation/AppNavigator.ets、tools/test/ui-refinement-regression.mjs。

- [x] 添加映射断言：`house → house_fill`、`heart → heart_fill`、`person → person_fill`，并断言 `SymbolGlyph(this.activeTab === item.tab ? item.selectedIcon : item.icon)` 与现有颜色接线；执行回归确认先失败。
- [x] 添加 `selectedIcon: Resource`；三项资源映射保持图标同族。仅替换 SymbolGlyph 的资源选择表达式。
- [x] 执行 `node tools/test/ui-refinement-regression.mjs`、`node tools/test/plan-time-list-regression.cjs`，按 ArkTS 技能脚本编译 `assembleApp`，首次成功。
- [x] 执行 `node tools/verify.mjs --steps=offline,debug,release` ALL PASS，`git diff --check` 通过；结果见 docs/validation/2026-10-16-dock-and-bunny.md，设备视觉仍待验。
