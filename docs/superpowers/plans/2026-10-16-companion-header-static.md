# Companion header static preview Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 提供布布/休休双角色透明静态稿与共同休时页头实际占位预览，供用户确认后再制作动画。

**Architecture:** 新建命名分组 SVG；独立 HTML 引用它，在手机示例页头中展示，并提供日夜/尺寸评审。文件仅在 docs/prototype 下，正式 ArkTS 页面不变。

**Tech Stack:** SVG、HTML/CSS、小范围页面内 JS、agent-browser 本地独立会话。

**Spec:** docs/plans/2026-10-16-companion-header-static-design.md

## Global Constraints

- 本轮静态稿，不接正式 App，不制作动画或云端联动。
- 角色占位 112×56；标题、角色同排，三个 Tab 保持下一行。
- 现有布布暖杏 #FFE3C2、轮廓 #D9A06B；休休白 #FFFFFF、轮廓 #E890A8；五官 #5C4750、腮红 #FFC7D8。
- 无矩形底框、滤镜或图片节点投影；保留用户原文件，不自动提交。执行子技能不可用，在当前会话执行。

## Task 1: 静态稿与预览

Files: docs/prototype/assets/shared-companions-v1.svg、docs/prototype/shared-companions-2026-10-16.html。

- [x] 新增 SVG，按 `bubu` / `xiuxiu` 角色和耳朵/脸/眼睛/身体/手臂命名组；绘制并肩小手轻碰的静态姿态，保存透明背景。
- [x] HTML 手机预览宽 390，页头标题与角色同行、Tab 下面；评审栏显示 SVG 放大图、112×56 实际尺寸、深浅背景切换和 360 宽检查，不新增真实业务功能。
- [x] 用 agent-browser 独立会话打开本地文件，验证深浅背景切换、图片加载、390/360 框及 360 浏览器视口无溢出和重叠；截图并查看。PowerShell 的 @ref 需引号，已更正命令后验证交互。
- [x] 记录 HTML 预览边界到 docs/validation/2026-10-16-companion-header-static.md；Codex 独立 browser 打开请求 queued，并交付预览文件。等待用户确认造型再进入动画阶段。
