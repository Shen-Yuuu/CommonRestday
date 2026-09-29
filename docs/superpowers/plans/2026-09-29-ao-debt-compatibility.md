# AO Cloud Deletion Debt Compatibility Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking. If those skills are unavailable in the execution environment, preserve the same test-first and review gates inline.

**Goal:** 让 AO 的待补删队列在旧包升级和再次清空数据后仍保留全部可核对的云端欠账，并让操作现场的提示与账目一致。

**Architecture:** 保持现有 `SettingsStore` 持久化键和 `ProfileSettingsService` 补删入口。读取端兼容 U·U5 写过的单对象 JSON 与 AO 数组 JSON；清空端先收集不可重试的旧账，再清库并重建合并后的账。测试必须覆盖真实 `SettingsStore`，不能只让离线桩自证。

**Tech Stack:** ArkTS、Preferences、Hypium、项目离线桩、API 26 模拟器。

**Spec:** `docs/cloud/pairing-protocol-v1.md` §4.5、`docs/design/date-plan-coedit-2026-09-28.md` §8.29。

## Global Constraints

- `cloudPairing=false` 时云调用数必须为 0；仍保留删除凭据并说明“开通后再试”。
- 待补删记录只含 `pairId`、原会话 `uid`、`dead`；不留密钥、快照或明文日程。
- `dead=true` 不自动重试，但不能在后续清空中无声消失。
- 不清理现有两台已配对模拟器；设备验证只用可丢弃实例。
- 每一代码任务结束均运行 `node tools/verify.mjs --steps=offline,debug,release,ohostest,perf`，不得上调基线掩盖错误。

---

### Task 1: 兼容旧版单对象欠账

**Files:**
- Modify: `data/src/main/ets/settings/SettingsStore.ets`，`getPendingCloudUnpair()`。
- Modify: `tools/test/run.mjs`，`STUB_DATA` 中的同名方法。
- Test: `entry/src/test/ProfileSettingsGuardTest.ets`；另在可丢弃设备上用真实 Preferences 复核。

**Interface:** 继续返回 `PendingCloudUnpair[]`；旧形状 `{"pairId":"old","uid":"original"}` 应读成一条 `dead=false`，AO 数组形状保持原义。首次写入仍统一存 AO 数组形状。

- [ ] **Step 1: 写失败用例。** 给存储键喂以下旧版原文，断言返回一条 `pairId=old, uid=original, dead=false`；再喂 AO 数组、坏 JSON、空对象，分别断言正常读取或空数组。测试应读取同一生产解码逻辑；若离线只能读桩，额外加一条设备侧真实 Preferences 用例，不把桩通过当作生产已证。

  ```json
  {"pairId":"old","uid":"original"}
  ```
- [ ] **Step 2: 运行离线用例，确认旧对象一格先红。** `node tools/test/run.mjs`；记录失败断言及运行档位。
- [ ] **Step 3: 最小修复。** `JSON.parse` 后用 `Array.isArray` 分辨数组与单对象，再逐条校验非空 `pairId`／`uid`；缺失的旧 `dead` 按 `false` 读。不能把有效旧对象当“非数组脏值”丢掉，也不要在读取时主动发云请求。核心分流是：

  ```typescript
  const parsed = JSON.parse(text) as Object;
  const rows = Array.isArray(parsed)
    ? parsed as Array<Record<string, Object>>
    : [parsed as Record<string, Object>];
  ```
- [ ] **Step 4: 测“读旧、写新、重启再读”。** 调用一次现有 `addPendingCloudUnpair` 后，存储应成为数组，旧 `uid` 不变，重启后的补删仍使用这个 `uid`。
- [ ] **Step 5: 跑完整门禁并独立提交本任务文件。** 出包编译不可由离线 TypeScript 检查替代。

### Task 2: 再次清空时保住终局欠账

**Files:**
- Modify: `feature/src/main/ets/usecase/ProfileSettingsService.ets`，`clearAllData()`。
- Test: `entry/src/test/ProfileSettingsGuardTest.ets`。

**Interface:** `dead` 记录仍不进 `cloudUnpairTargets()`；但它必须进入清库后的账目重建。按 `pairId` 去重，保留原 `uid`，不把 `dead` 改回可重试。

- [ ] **Step 1: 写失败用例。** 预置以下两条旧账，模拟云网络失败后调用 `clearAllData()`；断言清库后两条仍在、终局条仍为 `dead`、旧 `uid` 逐字相同、终局条没有产生云调用。再测只有终局条且当前未配对的形状。

  ```json
  [{"pairId":"cannot-delete","uid":"uid-a","dead":1},{"pairId":"retry-later","uid":"uid-b","dead":0}]
  ```
- [ ] **Step 2: 跑用例确认“终局旧账消失”先红。** 当前 `sweepCloudUnpair()` 不枚举 `dead`，而 `clearAllSettings()` 会清掉整键；此处是待修的实际断点。
- [ ] **Step 3: 最小修复。** 清库前复制既有 `dead` 条目；清库后将它们与 `sweep.kept` 按 `pairId` 合并写回。任何云删除成功的同一 `pairId` 不应再留“删不掉”徽标。不要把快照密文或 HUKS 别名写进队列。顺序不可倒置：

  ```text
  读取旧 dead 账 → 云端 sweep → 本机清库 → 合并旧 dead 与 sweep.kept → 落新队列 → 更新页面计数
  ```
- [ ] **Step 4: 覆盖重复清空与重启。** 连续清空两次，徽标计数不下降也不虚增；重启后计数与队列一致。
- [ ] **Step 5: 跑完整门禁并独立提交本任务文件。** 文档 §8.29 补“修补后设备待验”，不能直接勾设备格。

### Task 3: 操作现场如实展示欠账

**Files:**
- Modify: `entry/src/main/ets/view/MeView.ets`，`doUnpair()`／`askClearAll()`／相关状态刷新。
- Test: `entry/src/test/ProfileSettingsGuardTest.ets` 中的文案或状态断言；设备截图在验收计划中采。

**Interface:** `undeletableCloudSnapshots()` 仍只计终局条；待补删条和终局条在清空确认文案中分别说明，关闭态不承诺立刻联网删除。

- [ ] **Step 1: 写状态判据。** 模拟 `unpair()` 收到终局拒绝后不离开“我的”页，数据卡应立即显示新增的终局计数；关闭态或已有待补删记录时，点“清空全部数据”应看到云端未清义务，而不是只有本机删除说明。
- [ ] **Step 2: 修复刷新与确认文案。** `doUnpair()` 的成功、失败回调都刷新欠账读数；确认文案依据实际 `pairId` 与队列状态，而不是仅凭 `FeatureFlags.cloudPairing && pairState` 判断是否有云端欠账。
- [ ] **Step 3: 校验三种话术。** 当前可删除、等待开通后补删、终局无法由本机删除，三者不得统一写成“云上已删”；对应隐私/发布文案若有变化，同步 `copy-audit` 管辖的三份文本。
- [ ] **Step 4: 跑完整门禁并独立提交。** 随后执行设备验收计划，不以构建成功代替屏幕证据。

## Self-review 与完成定义

- 三条都可单独审查；生产存储读取、离线桩和设备事实不能互相冒充。
- 旧单对象升级、`dead` 后再次清空、关闭态零云调用、当前页即时显示均有明确断言。
- 无关 WIP、现有配对设备、AGC 已部署对象均不改。

执行时按任务顺序逐条提交；破坏性验收接续 `2026-09-29-ao-device-acceptance.md`。
