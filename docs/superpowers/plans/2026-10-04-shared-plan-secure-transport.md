# 共同计划可信身份与密文传输 Implementation Plan

> **For agentic workers:** 依照已批准设计单代理逐项实施；执行类子技能不可用时采用当前会话执行，不部署、不操作设备、不提交其他 WIP。

**Goal:** 把本地共同计划端口连接到真实 Auth、dateplan 调用和独立 HUKS 计划密文能力，保证重试不改变密文。

**Architecture:** 可信身份提供器、独立云调用、密文编解码与成员核验、RDB 密文请求账分离。只有显式完成新安全会话才允许装配 Gateway；不自动认领旧 pairId。正式页面与 Push 另批。

**Tech Stack:** ArkTS API 26、@hw-agconnect/auth 1.1.0、CloudFoundationKit、HUKS、RDB、Node SQLite／密码学测试。

**Spec:** `docs/plans/2026-10-03-shared-plan-confirmation-design.md` §4–8。

## Global Constraints

- CRD1 schemaVersion=2 不变；本轮共同计划协议版本 1、投影版本 1。
- 不以客户端 UID 证明操作者，不用旧裸 UID 建安全绑定，不自动解除现有配对。
- token 只进认证调用，不写日志、计划请求账或 UI；确认凭据不明文持久保存。
- AAD=`FT_DATEPLAN|pairId|planId|contentRevision|1`；状态版本不得替代内容版本。
- 密文请求账在第一次云发送前落地；同 requestId 重试沿用同一密文、动作、期望版本。
- 密钥缺失／成员错误／能力未知时失败关闭。关闭功能时 0 次认证／云请求。
- 本批不安装正式页面入口，不承诺 Push 可达；不操作模拟器、不部署、不读取签名秘密。

## Task 1：持久密文请求账

**Files:** `SharedPlanSchema.ets`、`MigrationRunner.ets`、`SharedPlanRepo.ets`、`ScheduleRepo.ets`、SQL 回归。

- [x] 给现有 schema v5 增量升 v6，新表 `shared_plan_wire` 保存 pair/actor/generation/requestId/draftJson/wireJson；不是修改明文草稿使原编号失去幂等性。
- [x] SQL `INSERT OR IGNORE ... SELECT ... WHERE` 同时复核当前会话与原始待发送草稿，竞争时读取并沿用先落地的密文；身份变化或草稿变化拒绝。
- [x] 完成请求、清库、恢复、会话代次变化时清理对应密文账；旧个人计划不动。
- [x] 回归验证迁移失败回滚、v5→v6、密文持久重试、旧代次与不同草稿拒绝。

## Task 2：可信身份与独立密钥

**Files:** `cloud/oh-package.json5`、`AnonymousIdentity.ets`、`DatePlanCloudApi.ets`、`PairKeyStore.ets`、`SecurePlanKeyStore.ets`、`cloud/Index.ets`。

- [x] 安装精确版本 Auth 1.1.0；attach 只记上下文，用户显式开始安全配对才允许匿名登录；已有会话读取禁止悄悄创建新身份。
- [x] `getToken(true)` 后再核对当前匿名 UID 没变；不删除用户、不主动登出、不把 token 保存进业务表。
- [x] 用独立哈希别名保管设备身份和计划密钥，复用已实测的 HUKS GCM 参数；旧 `crd-*` 别名保持原行为（共享加密机械过程另补失败 abort）。
- [x] 严格转换 P-256 公开点形态（64 字节坐标／65 字节非压缩点）；其他格式拒绝，不猜测 DER。设备运行仍待实测。
- [x] dateplan 云调用带 30 秒超时；仅传 token＋业务参数，保留业务拒绝码；异常不打印正文。

## Task 3：加密 Gateway 与安全会话装配边界

**Files:** 新 `feature/src/main/ets/usecase/SecureSharedPlanGateway.ets`、真实端口适配文件、`FeatureFlags.ets`、编排测试。

- [x] 注入身份／云／密钥／会话／密文账端口；context 从 dateplan 的服务端成员回包取得 actor/peer，不采纳旧 Settings UID。
- [x] 在真实发送前检查 ACTIVE、双方协议语义与当前本机代次；发送结果返回后再核对身份和代次。
- [x] PROPOSE/AMEND 加密一次并先保存 wireJson；其他动作不携带内容密文。重试不重加密，不从刷新后更高版本重新生成旧请求。
- [x] 完整验证密文成员、ID、修订、信封与解密内容；任一失败不返回部分可投影的成功列表。
- [x] 用 Node 真 AES-GCM 测试 AAD 篡改、修订、身份切换、关闭态、持久重试与云端回包错误，不以桩测试声称设备 HUKS 已通过。
- [x] 三档编译＋离线门禁，记录未装配正式 UI／未升级旧配对／未发送 Push 的边界。

本批验收不关闭主计划 Task 1–5。下一批再接显式安全配对页面流程、旧会话升级策略和正式计划卡；所需用户账号配置和双端动作随入口交付时给出。

## 执行回执

2026-10-04：本批三项代码任务及离线／编译门禁完成。最终 verify 五步 ALL PASS；offline 两档各 331 条，密文专项 19 项，SQL 回归通过；debug／release／ohosTest WARN 277／275／257（基线未改），perf 在开发机预算内。dateplan 两个编译目标各 36 条离线回归通过。实际 HUKS／Auth／RDB 设备验证、正式入口和 Push 保持待实施／待验证，不扩展方格的证据含义。详见 [验收回执](../../validation/2026-10-04-shared-plan-secure-transport.md)。
