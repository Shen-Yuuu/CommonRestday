# Plan time and list refinement Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 完成用户确认的五项页面微调，允许先编辑起点再编辑终点，仅提交时校验完整时间范围。

**Architecture:** 原 WindowDetailSheet 保留计划写入链路，增加受草稿代次约束的日期/时间编辑；统计和筛选并入共同列表的普通 ListItem，继续使用原 Refresh/Scroller。命名只改指定显示入口。

**Tech Stack:** ArkTS / ArkUI、Node 生产方法回归、项目 tools/verify.mjs。

**Spec:** docs/plans/2026-10-16-plan-time-and-list-design.md

## Global Constraints

- 编辑时不校验窗口边界和起止先后；点击创建/发送时统一校验。
- 最短计划 15 分钟；快捷调节维持 ±15 分钟；不新增权限、云协议或依赖。
- 不调整共同 Dock 名称；列表/周历/计划切换栏不随列表滚走。
- 保存旧工作区修改，不执行自动提交。执行子技能不可用，采用当前会话内分步执行与自查。

## Task 1: 编辑方法与列表回归

Files: tools/test/plan-time-list-regression.cjs、tools/test/run.mjs。

- [x] 新增生产方法提取测试：`toggleCustomTime(end: boolean)`、`setCustomTime(end: boolean, value: number)`、`pickCustomDate(end: boolean)`、`pickCustomClock(end: boolean)`。执行非法中间态、跨日、取消和迟到回调，再检查 `submitPlan` 的 `planDraftError` 在 `shared.propose`/`PlanUseCase.createPlan` 之前。
- [x] 运行 `node tools/test/plan-time-list-regression.cjs`，先确认缺少新方法而失败。

## Task 2: 命名与列表

Files: entry/src/main/ets/view/HomeView.ets、navigation/AppNavigator.ets、view/CoTimeView.ets。

- [x] 替换 `title: '同休'` / 首页 Dock 文案为 `两人份`，共同页 header 为 `共同休时`。
- [x] 用 `listFilters()` builder 显示 `.fontSize(12)` 段数和 `filterRow()`；将其放到 `ListItem()`，移除 windowBody 外部统计/筛选。空态放入同一 List，不新增外层纵向 Scroll。
- [x] 运行新回归和 `node tools/test/refresh-performance-regression.cjs`。

## Task 3: 自定义日期时间

Files: entry/src/main/ets/component/WindowDetailSheet.ets。

- [x] 引入 `epochDayOf` / `MIN_PER_DAY`，增加 `customTimeEnd = -1`、选择器序列；toggle 只展开原表单，set 只检查有效数字并标记 `timeTouched`，不钳制、不修改另一端。
- [x] 日期选择使用 `showDatePickerDialog({ selected, onDateAccept })`，替换日历日并保留分钟；时间选择用 `showTimePickerDialog({ selected, useMilitaryTime: true, onAccept })`，保留日历日。回调核对 mounted/foreground/saving/draftGeneration/picker 序号及当前展开行。
- [x] 起止行采用可缩放读数与紧凑等高按钮，`+15` 后加 `…`；其后条件展示日期与时间按钮；删除「时间调节」后的括号。
- [x] 保留提交 `planDraftError` 和云端/本地原写入流程；校验失败草稿保留，创建按钮可用。
- [x] 运行新回归及已有 plan-form、反馈动效与共享计划回归。

## Task 4: 编译与交接

- [x] 按 ArkTS 技能脚本编译；使用本地 DevEco 安装路径注入命令，不打印签名信息。首次编译成功。
- [x] 运行 `node tools/verify.mjs --steps=offline,debug,release,ohostest,perf`；最终 ALL PASS，不修改告警基线。
- [x] `git diff --check`，记录实际通过与设备待验项到 docs/validation/2026-10-16-plan-time-and-list.md；不部署云端、不发布安装包。
