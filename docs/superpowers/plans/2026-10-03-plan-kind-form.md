# Plan Kind Form Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 扩展六项固定计划分类，并将标题标签与输入框同排。

**Architecture:** 修改 feature 的展示选项表和 ArkUI 表单布局，保留兼容表及既有草稿切换行为。计算、云协议和数据库不变。

**Tech Stack:** ArkTS、ArkUI、Hypium、Node 离线回归。

**Spec:** docs/plans/2026-10-03-plan-kind-form-design.md

## Global Constraints

- 不改云端双向确认、通知、数据库结构、日历授权、计划计算。
- 保留当前工作树中的其他改动，不提交混合 WIP。
- 不操作模拟器；设备观感由用户验收。

### Task 1: 固定分类、表单与兼容验证

**Files:** 修改 feature/src/main/ets/model/PlanKinds.ets、entry/src/main/ets/component/WindowDetailSheet.ets、entry/src/test/PlanKindsTest.ets、docs/prototype/index.html；新增 tools/test/plan-form-regression.mjs 并接 tools/test/run.mjs。

**Interfaces:** 沿用 PLAN_KINDS: PlanKindOption[]、planKindLabel(kind: string): string、pickKind(idx: number): void、onTitleChange(v: string): void。

- [x] 更新用例并先验证旧实现失败。

```ts
expect(PLAN_KINDS.length).assertEqual(6);
expect(PLAN_KINDS[0].label).assertEqual('吃饭');
expect(PLAN_KINDS[5].key).assertEqual('custom');
```

- [x] 更新固定分类和历史兼容表。

```ts
export const PLAN_KINDS: PlanKindOption[] = [
  { key: 'meal', label: '吃饭' }, { key: 'movie', label: '看电影' },
  { key: 'walk', label: '散步' }, { key: 'shopping', label: '购物' },
  { key: 'trip', label: '出游' }, { key: OTHER_PLAN_KIND_KEY, label: '其他' }
];
```

- [x] 将标题 Column 换成 Row({ space: 12 })，标签不再 width('100%')，输入框 .layoutWeight(1)，保留 minHit 下限及原 onChange；行 .alignItems(VerticalAlign.Center)。原型对应改为 row，输入框 min-width:0、flex:1。
- [x] 运行真实 pickKind/onTitleChange 提取回归：默认标题切换、其他空白、自填后不覆盖、同排布局接线；挂入离线入口。
- [x] 执行 `node tools/verify.mjs --steps=offline,debug,release,ohostest`；这里只编译 ohosTest，不声称设备运行通过。
- [x] 检查本轮增量仅在本次范围；`git diff --check` 通过，保留已有 WIP。
- [ ] 用户设备检查换行、同排、键盘、旧标题；不把未验证的观感打勾。

Git 提交不在本轮：工作树包含大量已有 WIP，保持未提交以供用户统一处理。

## 执行结果（2026-10-03）

- 红灯：旧实现下定向 planKinds 为 3 passed / 2 failed，分别失败于选项数量与吃饭标签。
- 修复后：offline closed/open 两档均 typecheck 0 errors、300 passed / 0 failed、exit 0；包含新的 plan-form-regression。
- debug/release/ohostest 编译均 BUILD SUCCESSFUL；WARN 分别 287/287/267，未抬基线。
- 完整 verify: ALL PASS，exit 0。没有模拟器渲染、安装或云部署证据。
