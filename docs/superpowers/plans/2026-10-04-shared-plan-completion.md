# 共同计划剩余链路 Implementation Plan

> **For agentic workers:** 按任务内联执行并逐项核验。本仓库存在多人未提交工作，不自动提交；不操作模拟器、账号、部署或签名。原计划提到的执行子技能未安装，使用当前会话执行。

**Goal:** 补齐已批准的共同计划方案中能在本机完成的客户端、服务端与验证，交付准确的人工操作清单。

**Architecture:** 服务端以认证成员和事务为权威；客户端先持久化原请求，只把已确认版本投影到本机日程。推送只提示状态变更，不承载明文计划或替代云端核实。

**Tech Stack:** API 26 ArkTS / ArkUI、RDB、HUKS、CloudDev / CloudDB、Push Kit、Node 离线测试。

**Spec:** `docs/plans/2026-10-03-shared-plan-confirmation-design.md`

## Global Constraints

- 新能力开关默认关闭；旧班表云同步不退场。
- 待确认计划不占用时间；改期待确认时保留旧确认时间。
- 原请求、原密文重试，不重建身份、连接或密码学随机数来猜结果。
- 不把旧 pairId / Preferences UID 当作认证身份；不默认认定两个独立配对指向同一伴侣。
- 密钥不出 HUKS，通知不包含标题、时间、昵称或计划明文。
- 编译、离线、部署、双端、锁屏证据分别登记；不把编译成功称为发布可用。

## Task 1：原请求只读回执

**Files:** `cloud-backend/cloudfunctions/dateplan/{service,dateplan}.ts`、`cloud/src/main/ets/api/DatePlanCloudApi.ets`、`feature/src/main/ets/usecase/{SecureSharedPlanGateway,SharedPlanUseCase}.ets`、对应服务端与客户端测试。

**Interfaces:** `requestStatus(token, commandJson)` 读取本人原请求；`SharedPlanGatewayPort.resolve(ctx, command)` 返回 `SharedPlanReply`，不存在回执返回 `REQUEST_NOT_COMMITTED`，查失败保留队列。

- [x] 写离线断言：查询无副作用、请求摘要不符拒绝、非成员拒绝、提交后丢响应可核实。
- [x] 实现先查询回执再做冲突重检与原请求重发；未提交不等同于撤销，也不删除幂等锚点。
- [x] 跑 ES2020 / ES5 服务端用例、客户端与真实 SQLite 回归。

```ts
const resolved = await gateway.resolve(ctx, command);
if (resolved.code === 'OK') { /* 应用权威版本后结束原请求 */ }
// 只有明确 REQUEST_NOT_COMMITTED 才允许进入原请求重试分支。
```

## Task 2：清理未知连接与本机密钥生命周期

**Files:** `dateplan/{service,dateplan}.ts`、`SecureCleanupUseCase.ets`、`SecurePairingUseCase.ets`、`SecurePairingRepo.ets` 与生命周期回归。

**Interfaces:** `cleanupCreate(token, flowId)` 根据认证成员派生原创建 ID，只删不建；未知加入保留审计信息，不扩大到删除该身份的任意连接。已知连接清理仍调用 `unpair`。

- [x] 补创建丢回包后清理、不匹配身份不清理、密钥删除失败保留记录断言。
- [x] 在建立会话密钥前先保存已知 pairId；正常解绑后本机密钥失败也进入持久清理路径。
- [x] 不能自动核实的旧加入 / 恢复身份在交接文档明确账号侧处置，不冒充已删除。

```ts
// 原创建 ID 的算法保持与 createPair 一致；缺失仅是一次只读观察。
const pairId = 'sp-' + digest([authenticatedMember, originalFlowId]).slice(0, 32);
```

## Task 3：正式计划页面和创建分流

**Files:** 新增 `SharedPlansPanel.ets` / 读模型，修改 `PlansView.ets`、`CoTimeView.ets`、`WindowDetailSheet.ets`。

**Interfaces:** 本机读模型提供记录、本人角色、待确认数、未决请求；写操作只经 `secureSharedPlans()`。正式页面可读旧缓存，关闭档禁止云写；共同计划的配对关系未核实时禁止自动接管旧班表关联。

- [x] 构造待我确认 / 待对方确认 / 已确认 / 改期待确认 / 已撤回等展示与动作矩阵用例。
- [x] 在计划 tab 显示待确认圆点，列表提供同意 / 暂不安排 / 撤回 / 取消与显式改期；接线避免整页重建，真实观感仍待设备。
- [x] 云配对创建不先落本机已确认计划；未建立安全连接明确阻止并指向设置，不静默降级。

## Task 4：通知端云接线

**Files:** 独立 Push 适配、EntryAbility 路由、通知设置、服务端 outbox 发送器、测试。

**Interfaces:** 用户主动授权后注册本人 token；场景化通知由服务端发出，点击仅导航共同计划并刷新。发送器权限仅来自服务端凭证，不能通过客户端随意调用广播。

- [x] 查本机 API 26 声明与官方推送 REST 文档，校验请求字段、授权与点击入口。
- [x] 构造固定泛化通知文案；不在消息载荷放明文计划。注册、解绑、失败恢复都有身份栅栏。
- [x] 发送失败不回滚已提交计划；未知送达不能声称恰好一次；权限 / 签名 / 后台 / 锁屏待用户，矩阵已交付。

## Task 5：总门禁、部署源与用户步骤

**Files:** `docs/validation/2026-10-04-shared-plan-final-handoff.md`、operator-actions、隐私披露与 cloud README。

- [x] 顺序执行全门禁，不同时启动多个 runner。
- [x] 核对 CloudDevSpikeOfficial 与正式 FortwoCloud 部署源；不同应用的认证、Push 项目不混用，不覆盖凭证。
- [x] 列出已完成、实现阻断、待设备、待账号四类，提供按先后可操作的步骤与成功判据。
- [x] 全部本轮代码可完成项做完后交接；外部条件不能靠本机模拟通过来关闭。

## 2026-10-04 本机执行回执

全门禁 ALL PASS：两档离线各 337/0；debug/release/ohosTest WARN 278/276/258，未上调基线；开发机性能预算通过。
服务端 ES2020 / ES5 各 47/0，SDK strict/noEmit 通过；两个云工程各 16 个文件同源，独立 worker ZIP 已构建。
新增回前台只读撤销检查，不重放未知的连接请求；清理账区分云残留与本机密钥欠账。

以上勾选只关闭本机实施任务，**不关闭云部署、正式双端、锁屏、签名或发布门禁**。当前 securePairing/sharedPlan 仍关闭。
具体证据和仍未实现的运营边界见 [交接](../../validation/2026-10-04-shared-plan-final-handoff.md)，需用户操作见 [步骤](../../validation/2026-10-04-shared-plan-operator-actions.md)。
