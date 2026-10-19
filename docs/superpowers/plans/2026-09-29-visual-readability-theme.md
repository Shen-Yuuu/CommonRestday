# Visual Readability and Live Theme Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking. If those skills are unavailable, keep the same test-first and review gates inline.

**Goal:** 修复浅色档重要文字低对比度和 D-65 实时换档后筛选芯片留在旧主题的问题，不改变已确认的暖色编辑气质。

**Architecture:** 把信息文字与装饰性粉色分开判定：需要阅读的普通文字以对比度门槛和语义优先级选墨，品牌粉保留为底色、标记或足够大的强调。实时换档从应用级配置回调发出单一颜色模式信号，`CoTimeView` 消费它并重新绑定五颗 `ChipV2Options` 的 `ColorMetrics`，选中筛选项不变。

**Tech Stack:** ArkTS、ArkUI `ChipV2`/`ColorMetrics`、资源色、`AppStorage`、项目静态对比度审计。

**Spec:** `docs/design/date-plan-coedit-2026-09-28.md` §8.32④/⑥、§8.33④；原型 `docs/prototype/index.html` 只用于视觉对照，不当成代码指令。

## Global Constraints

- 正常大小的重要文字以 4.5:1 为最低目标；禁用控件与纯装饰可按语义另判，`CycleEditor` 的“序列为空”不是禁用控件。
- 不直接修改用户未提交的原型、`ScheduleOverviewQueryService.ets` 或其它 WIP。
- `D-65` 的最终通过必须有同设备同页“应用在场时切深色”与“深色冷启动”两帧；代码、静态测试、出包绿均不能替代。
- 现有 5555 可承担不改业务数据的界面 A/B；云端解绑、清空、卸载和全量 ohosTest 仍只用可丢弃实例。

---

### Task 1: 给浅色文字阶梯确定语义与颜色

**Files:**
- Modify: `entry/src/main/resources/base/element/color.json` 中信息文字令牌。
- Inspect: `entry/src/main/resources/dark/element/color.json`、`entry/src/main/ets/theme/DesignTokens.ets`。
- Test: 项目对比度审计与资源色逐项配对表；更新 `docs/design/date-plan-coedit-2026-09-28.md` 的 D-64 判据。

**Interfaces:** 输出一张“文字用途→背景→浅/深色墨→对比度→是否装饰”表；普通信息文本不得再落到 3.98、2.71、2.01 一族的浅色低对比度组合。

- [x] **Step 1: 冻结用途。** 将正文/说明/操作反馈与眉标、图标、不可用按钮分开；品牌粉仅可在满足相应文字对比度时当小字墨，否则用深墨传递信息、粉色保留为装饰或容器色。
- [x] **Step 2: 选浅色令牌。** 针对页面实际底色计算每一对，而非只拿白底计算；调整信息文字令牌使普通字达到 4.5:1，保留 `text_primary` 与次级文字的层级差。深色令牌无证据缺陷的不连坐改色。
- [x] **Step 3: 跑静态反例。** 把一组信息字临时改回低于 4.5:1 的旧配对，审计必须失败；复原新值后通过。计算脚本只读取令牌和实际背景，不用圆角芯片整框像素推断字色。
- [x] **Step 4: 跑完整门禁。** `node tools/verify.mjs --steps=offline,debug,release,ohostest,perf`；生成浅色对照页供用户选型。此时仍只判“代码与算术通过”。

### Task 2: 单独修 D-64 的行动提示

**Files:**
- Modify: `entry/src/main/ets/pages/CycleEditor.ets:216`。
- Test: 同一对比度表与构建门禁。

**Interfaces:** “序列为空”是保存前必须读到的信息；它使用 Task 1 已通过的普通信息墨，不再用 `text_disabled`。

- [x] **Step 1: 锁定旧反例。** 记录当前浅/深色约 1.50/2.02 的字底配对与页面截图证据。
- [x] **Step 2: 更换唯一调用点。** 保留原句和布局，仅将 `fontColor($r('app.color.text_disabled'))` 改为 Task 1 定下的信息文本令牌。
- [ ] **Step 3: 核对其他 `text_disabled` 用点。** 禁用按钮、装饰 chevron、线条不按本条批量改色；跑静态审计与三档出包，设备上复看同一位置。

### Task 3: 建立实时颜色模式信号并刷新 ChipV2

**Files:**
- Modify: `entry/src/main/ets/entryability/EntryAbility.ets`。
- Modify: `entry/src/main/ets/view/CoTimeView.ets:99-153`。
- Inspect: `entry/src/main/ets/theme/DesignTokens.ets:357-374`；`entry/src/main/ets/component/CapsuleSegment.ets:26-33` 作为已正常跟随的对照组。
- Test: 配置回调的纯状态断言、三档出包、5555 上安全的 live-flip/cold-start A/B。

**Interfaces:** 能从系统配置变化拿到颜色模式并写入一个应用级状态；共同页监听该状态，刷新五颗 Chip 的颜色配置。现有 `filterKey`、选中态、横向滚动位置和页面数据不因换色被重置。

- [x] **Step 1: 先在本机 SDK 核实回调签名。** 优先核对 `UIAbility.onConfigurationUpdate` 或 `ApplicationContext.on('environment', ...)` 的 API 26 声明；只选一个入口，初始化时同步写当前颜色模式，退出时注销订阅（若采用订阅式）。
- [ ] **Step 2: 写状态用例。** `LIGHT→DARK→LIGHT` 只更新颜色信号，不调用 `ScheduleUseCase.onScheduleChanged()`、不改筛选条件、不发快照；五颗 Chip 的 `activated` 与原 `filterKey` 一致。
- [ ] **Step 3: 最小接线。** `CoTimeView` 以 `@StorageProp`/`@Watch` 消费颜色信号；变更时重新取 `DesignTokens.chipText/chipTextOn/chipBg/chipBgOn()`。先验证能否更新现有 `@ObservedV2` 选项；若 SDK/渲染不响应，重建选项并用主题修订键触发五颗节点重绑，避免常规重算重建整行。
- [ ] **Step 4: 静态与设备两级验证。** 出包和离线门禁通过后，在现有 5555 不按业务保存键地切深色、切回浅色：live-flip 与同模式冷启动的芯片颜色逐字节相同，胶囊仍正常，筛选状态与滚动位置不变。失败则 D-65 不勾。

## 完成定义

信息字的用途/对比度表、D-64 的单点修复、D-65 的颜色模式信号各可单独审查；深浅色两档无新增告警与静态违规。D-65 只有设备 A/B 同过后才结案。全程不借用可丢弃实例，也不碰 5555 的配对数据。

> 无设备回执：Task 1 的四步已完成，旧 `text_secondary` 被副本负例拦下；对比表在 `docs/validation/2026-09-29-offline-handoff.md`，独立样张在 `docs/prototype/contrast-specimen-2026-09-29.html`。Task 2 的改色与静态门禁通过，设备复看未做。Task 3 已按 API 26 声明接 `UIAbility.onConfigurationUpdate`、`AppStorage` 与 `ChipV2Options` 的 `@Trace` 颜色字段；只凭编译不能证明运行时渲染跟手，Step 2–4 保持未勾。五步门禁通过，不等于 D-64/D-65 设备结案。
