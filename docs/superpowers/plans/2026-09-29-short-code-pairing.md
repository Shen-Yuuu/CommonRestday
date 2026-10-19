# 六位短码配对闭环 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 两台设备只分享六位码，在邀请方本机确认后完成配对，不再显示或使用二维码与配对链接。

**Architecture:** 云端在 `create` 而非 `join` 时把一次性确认凭据交给邀请方；邀请方将其用 HUKS 加密后存储。`join` 只登记对方公钥，`confirm` 仍需一次性凭据；页面通过手动检查状态触发邀请方确认框，不建常驻轮询。

**Tech Stack:** HarmonyOS API 26、ArkTS/ArkUI、HUKS、AGC 云对象、离线 Hypium 与 headless hvigor。

**Spec:** `docs/plans/2026-09-29-short-code-pairing-design.md`

## Global Constraints

- 保留已有用户 WIP 和他人正在修改的文件内容；对重叠文件只做定点编辑。
- `cloudPairing=false` 时配对入口不发请求、不创建 HUKS 别名。
- 六位码不能派生长期快照密钥；快照密钥仍由双方 HUKS ECDH 协商。
- 邀请凭据不以明文写入 Preferences、日志、剪贴板或云端状态查询响应。
- 不部署云对象、不安装/操作模拟器；设备证据由用户补齐。

---

### Task 1: 调整云端凭据归属并锁定契约

**Files:** `cloud-backend/cloudfunctions/pairing/pairing.ts`、`cloud-backend/cloudfunctions/{pairing,snapshot}/contract.ts`、`cloud/src/main/ets/api/CloudApi.ets`、对应离线探针。

**Interfaces:** `create` 返回 `confirmToken` 给创建方；`join` 与 `status` 均不返回它；`confirm(pairId, uid, token)` 的一次性语义不变。

- [ ] 增加先红的云侧契约断言：`create` 有非空 token，`join/status` 均无 token，`confirm` 对错误 token 返回 `FORBIDDEN`。
- [ ] 运行云侧类型检查与探针，确认旧实现失败。
- [ ] 把 `newSessionRow` 的 `confirmToken` 赋为 `confirmToken()`；`doCreate` 投影用 `sessionBody(row, uid, true, true)`；`doJoin` 不再生成 token 且投影不带 token。两份 `contract.ts` 保持字节一致。
- [ ] 重跑云侧类型检查、探针及副本一致性检查。

### Task 2: 邀请方本机安全托管与确认

**Files:** `cloud/src/main/ets/api/PairKeyStore.ets`、`data/src/main/ets/settings/SettingsStore.ets`、`feature/src/main/ets/usecase/ProfileSettingsService.ets`、`entry/src/test/ProfileSettingsGuardTest.ets`、`tools/test/run.mjs`。

**Interfaces:** `PairKeyStore.sealInviteProof(pairId, token)` 返回密文信封；`openInviteProof(pairId, envelope)` 恢复 token 或报不可用；`dropInviteProof(pairId)` 删除 HUKS 别名。`SettingsStore` 只保存绑定 pairId 的信封。`ProfileSettingsService.confirmPendingJoin()` 仅在本机持有有效证明时调用云端 `confirm`。

- [ ] 增加先红离线用例：创建时保存密封证明、加入方无证明、无证明不发 `confirm`、确认成功才设 `PAIRED`、取消及清库擦除证明。
- [ ] 运行 `node tools/test/run.mjs`，确认对应新断言失败。
- [ ] 在 HUKS 中为每个待确认 pair 建 AES-GCM 别名，复用项目已有 NONCE/AAD/AE_TAG 调用形态；Preferences 只存 IV、tag、密文和 pairId，不存 token。
- [ ] `createInvite` 校验回包的 token 后密封再写 WAITING；`joinByCode` 不读取 token；`reconcilePair` 对 PENDING 只回待确认；`confirmPendingJoin` 从本地打开证明并完成确认、ECDH 与状态写入；清理路径同步擦除证明。
- [ ] 重跑两档离线用例；检查关闭态云调用计数仍为 0。

### Task 3: 删除二维码/链接交互并交付设备验收

**Files:** `entry/src/main/ets/view/MeView.ets`、`entry/src/main/ets/entryability/EntryAbility.ets`、`entry/src/main/ets/navigation/AppNavigator.ets`、`feature/Index.ets`、`feature/src/main/ets/integration/PairingShareGateway.ets`（若保留复制短码则收窄职责）、`docs/cloud/pairing-protocol-v1.md`、`docs/testing-checklist.md`。

**Interfaces:** 邀请方手动检查状态时若为 `PENDING_CONFIRM`，弹本机确认框；确认后更新本页状态。加入方输码后只显示等待 A 确认，不展示凭据。

- [ ] 静态搜索并钉住 `MeView` 内的 `QRCode(`、链接分享按钮、扫码入口和 `crdpair://` 引导文案，确认改前有命中。
- [ ] 定点移除二维码、链接、扫码、深链确认及相关路由广播，保留复制短码；把「检查配对状态」的 PENDING 分支改为显示确认框，不自动确认。
- [ ] 更新协议和设备测试清单：旧待确认会话须重新生成；云侧需重新部署 `pairing` 并把超时复核为 20 秒。
- [ ] 运行 `node tools/verify.mjs --steps=offline,debug,release,ohostest,perf`；新告警不得高于仓库基线。交付两台模拟器的具体手测步骤，设备格保持待测。

## Self-review

- 每项设计要求已映射到 Task 1–3；Cloud DB 表字段保持不变，避免无关迁移。
- 端云 `confirm` 的形参与返回不改，仅修改凭据发放时机；旧服务端若没有在 `create` 返回凭据，端侧失败关闭。
- 不从 `status` 泄露凭据，不用六码推长期密钥；没有把“已加入”显示成“已配对”。

## 实施回执（2026-09-29）

- 云对象 `create/join/status/confirm` 已按新凭据归属实现；两份 `contract.ts` SHA-256 相同，
  云侧类型检查与 `node cloud-backend/test/pairing-contract.mjs` 均通过。契约测试是实现后补的回归，
  **没有执行本计划中“先红”步骤**，故上面的先红方格保持未勾。
- 邀请方 HUKS 别名与 Preferences 密文信封、加入方待确认、邀请方本机确认、成功/取消/清库清理，
  以及删除二维码/链接/扫码/深链入口均已落地。端侧两档离线用例各 263/0；debug/release
  `ArkTS:WARN` 均 289/289，ohosTest 出包 269/269，perf 在预算内。最后一次小改动之后另跑
  offline+debug 仍全绿；ohosTest **仅出包，未在设备执行**。
- 真实 HUKS 托管、云对象部署后的端到端状态、双端渲染与同步**待用户按**
  `docs/validation/2026-09-29-short-code-pairing-acceptance.md` **补设备证据**，不在此处打勾。
- 仓库同时有另一批未提交的 UI/文档 WIP；本轮未覆盖、提交或清理那些内容。
