# OhosTest Fixture Isolation Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking. If those skills are unavailable, keep the same test-first and review gates inline.

**Goal:** 让设备测试的副作用可审计、尽可能可回收，并明确全量测试只能在可丢弃实例运行。

**Architecture:** 先静态审计 `entry/src/ohosTest` 对真实 Preferences、RDB 和系统日历的写入，再补齐测试自身的恢复逻辑。恢复逻辑降低失败后污染，但不能保证进程崩溃或卸载时恢复，因此不解除“可丢弃实例”门槛。

**Tech Stack:** ArkTS、Hypium、RDB、Preferences、API 26 ohosTest。

**Spec:** `docs/testing-checklist.md` §0.1、`entry/src/ohosTest/ets/test/UpgradeMigrationTest.ets`、`entry/src/ohosTest/ets/test/Ability.test.ets`。

## Global Constraints

- 现有 `127.0.0.1:5555` 带有真实配对和班表，不运行全量 ohosTest，不清数据，不卸载。
- 不把 `assembleHap`/`assembleHap --test` 的构建成功写成“设备测试通过”。
- 无设备阶段只改测试代码、验证出包和静态审计；真实执行等独立 API 26 可丢弃实例。
- 不提交用户未完成的 `AppScope/app.json5`、签名、原型、legal 与其它 WIP。

---

### Task 1: 修复配对恢复用例的真实设置污染

**Files:**
- Modify: `entry/src/ohosTest/ets/test/UpgradeMigrationTest.ets:290-323`。
- Test: 同文件 `pairing_reset_lands_on_real_preferences`。

**Interfaces:** 测试进入前读到的 `pairId`、`pairState`、`partnerUid`、`partnerSnapVer`、旧残留键，在 `finally` 中恢复；不能凭测试断言通过就假设恢复已发生。

- [x] **Step 1: 记录失败判据。** 当前用例保存了 `hadState/hadUid/hadVer/hadKey`，却将 `pairId` 写成 `pair-from-the-old-device` 后清空，`finally` 没有恢复原 `pairId`。在测试说明中列明进入和退出时 `getPairId()` 必须相等。
- [x] **Step 2: 加入真实恢复。** 在写入之前读取 `const hadPairId: string = SettingsStore.getPairId();`，并在 `finally` 中恢复：

  ```typescript
  await SettingsStore.savePairId(hadPairId);
  await SettingsStore.setPairState(hadState, hadUid);
  await SettingsStore.setPartnerSnapVer(hadVer);
  ```

- [x] **Step 3: 扩展恢复断言。** `finally` 后核对这三个读数与运行前一致；同时盘点 `setPairState` 顺带清除的一次性标记，若不能逐字恢复，在测试说明与设备计划中记为残留副作用。
- [x] **Step 4: 编译 ohosTest。** 使用现有 `node tools/verify.mjs --steps=offline,debug,release,ohostest`；构建绿只能说明可安装，不勾设备用例。
- [ ] **Step 5: 独立提交测试文件并记录基线。** 不把现有 5555 当作运行目标。

### Task 2: 给全量套件做副作用清单

**Files:**
- Modify: `docs/testing-checklist.md` §0.1 或新增同目录的设备执行附录。
- Inspect: `entry/src/ohosTest/ets/test/List.test.ets`、`Ability.test.ets`、`UpgradeMigrationTest.ets`。

**Interfaces:** 输出“测试名→写入对象→退出残留→可否在珍贵数据实例执行”四列；最后一列全量套件固定为“不可以”。

- [x] **Step 1: 枚举所有设备用例。** `List.test.ets` 当前装配 `Ability.test` 与 `UpgradeMigrationTest`；逐条标出 `savePairId`、`setPairState`、`saveTemplate`、`upsertShiftType`、`upsertPlan`、`setMeta` 等真实写入。
- [x] **Step 2: 标出非完全回收项。** 例如 `Ability.test.ets` 的计划标题说明写明取消后以 `CANCELLED` 留库；`UpgradeMigrationTest.ets` 曾不恢复 `pairId`。把“测试通过但数据有变”与“测试中断导致 finally 未跑”分列。
- [x] **Step 3: 写执行前后快照判据。** 在可丢弃实例记录 `pairId` 指纹、RDB 行数、测试包版本，运行后核对；发现残留只能清理可丢弃实例，不能在 5555 试探。
- [x] **Step 4: 对照当前 release/testing 文档。** 将“ohosTest 构建通过”与“ohosTest 设备全量执行通过”拆为两个独立复选项。

## 完成定义

`pairId` 恢复缺口关闭，副作用清单可审计，ohosTest 出包通过；设备执行仍停在可丢弃实例前置，不因静态修复而提前勾选。

> 无设备回执：Task 1 的 Step 1–4 与 Task 2 均完成，五步门禁 270/0、debug/release 289、ohosTest 269、perf 通过。Task 1 Step 5 的“独立提交”未做，变更仍在工作树。当前 `setPairState()` 只写状态和伴侣 uid，并不清一次性标记；旧用例注释所说的顺带清理不是今天的实现，真实残留与中断风险见 `docs/validation/2026-09-29-ohostest-side-effects.md`。设备执行未发生。
