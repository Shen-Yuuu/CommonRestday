# 正式客户端安全配对与恢复 Implementation Plan

> **For agentic workers:** 按已批准设计单代理逐项执行。执行类子技能未提供，当前会话采用内联实施；不操作设备、不部署、不提交其他 WIP。

**Goal:** 生成短码、输码加入、邀请方确认及断网／进程重建恢复形成可测试的正式客户端流程，独立于旧班表配对。

**Architecture:** `SecurePairingUseCase` 消费认证、云对象、公钥／确认密封与本地 CAS 端口。`SecurePairingRepo` 持久保存单一操作意图及密封确认凭据，ACTIVE 才原子装配 `shared_plan_session`。界面沿用现有品牌组件，开发开关默认关闭；不能由旧 pairId 自动认领安全身份。

**Tech Stack:** ArkTS API 26、Auth 1.1.0、HUKS AES-GCM、RDB v7、独立 dateplan 云对象与现有 CloudDB 五模型。

**Spec:** `docs/plans/2026-10-03-shared-plan-confirmation-design.md` §4–8；第四批验收 §4。

## Global Constraints

- 不修改 CRD1 schemaVersion=2，不自动解绑、迁移旧快照或更换 TA。
- 新入口 `securePairing=false`；共同计划 `sharedPlan=false`。前者只允许测试安全连接，不宣称产品共确／Push 已就绪。
- 连接／激活时认证 UID、设备公钥和本机旧配对锚点变化均拒绝晚到结果；恢复不创建新匿名身份或新身份密钥。显式清理仍要求原认证 UID，但不把遗失的本机密钥或已变化的旧配对锚点作为云删除前提。
- 本机确认凭据 HUKS 独立密封，不明文进表／日志／UI；报码不是确认凭据。
- 新模型字段先部署再部署 dateplan；本轮只改源码与可复制清单，不实施云操作。
- 新安全连接与旧班表连接没有自动可信映射，正式计划开关继续关闭。生命周期、隐私及设备验收完成前不得用于发布。

## Task 1：补加入回包丢失的服务端恢复

**Files:** `cloud-backend/cloudfunctions/dateplan/{service.ts,models.js,models.d.ts,README.md}`、`clouddb/objecttype/PairMemberBinding.json`、`test/dateplan-contract.mjs`。

- [x] 加反例：`joinPair(B, code, key, 1)` 已提交，A 确认并使 code 清空，B 使用原参数重试仍得到同一 ACTIVE pair；C 或改 key 不能取得该绑定。
- [x] 增量字段 `recipientJoinDigest:String`，默认空，管理员专用；值为 `digest(['join-v1', who, code, publicKey, projectionVersion])`，不返回客户端。
- [x] 加入时同事务保存摘要；恢复先按摘要及认证成员查最多两行，多行拒绝 `CODE_COLLISION`。重新读取绑定并验证成员、公钥及有效状态；解绑时清摘要。
- [x] `node cloud-backend/test/dateplan-contract.mjs` 和 `--es5`，实际 SDK strict/noEmit 与模型一致性必须通过。

## Task 2：操作意图与密封证明

**Files:** `data/src/main/ets/repo/SecurePairingRepo.ets`、`db/{SharedPlanSchema,MigrationRunner}.ets`、`ScheduleRepo.ets`；`cloud/src/main/ets/api/{PairKeyStore,SecurePlanKeyStore}.ets`。

接口：`SecurePairingRepo.load():Promise<string>`、`save(expected:string,next:string):Promise<boolean>`、`activate(expected:string,next:string,session:SharedPlanSession):Promise<boolean>`。使用 `shared_pairing_setup(id=1,flow_id,data_json)`，不能将流程 JSON 改成裸 uid 认证。

- [x] v6→v7 创建独立表，清库和恢复时删除它，旧计划／星期列保留。回归注入 DDL 失败要求版本及表一起回滚。
- [x] 空表插入与旧 JSON 更新均 CAS；ACTIVE 流程与 session 同事务落地，旧回包不能复活清空后的流程；读连接不在事务中查询。
- [x] `sealProof(uid,flowId,secret):Promise<string>`／`openProof(uid,flowId,envelope):Promise<string|null>` 使用 `ft-plan-proof-*` 独立 AES 别名，AAD 绑定 UID 与 flowId；读取不能生成替代密钥。
- [x] Node 密码学回归篡改 flowId／UID、缺密钥与明文证明未落业务表；生产 SQL 回归 CAS、重复激活及清理。

## Task 3：客户端编排与关闭态界面

**Files:** `feature/src/main/ets/usecase/SecurePairingUseCase.ets`、`SecurePairingAdapters.ets`、`FeatureFlags.ets`、Index；`entry/src/main/ets/component/SecurePairingSetup.ets`、`view/MeView.ets`。

流程状态：`CREATING/JOINING/WAITING/PENDING_CONFIRM/ACTIVE/REVOKED`；失败返回独立 code，不把未知结果当成功。接口 `create()/join(code)/resume()/confirm()/disconnect()` 均 `Promise<SecurePairingResult>`，`local()` 只读本机。持久 intent 包含 flowId、role、authUid、publicKey、create requestId／joinCode、pairId、actor／peer、revision、anchor、sealedProof。

- [x] 先测试关闭态 0 认证／云请求、先落意图、同一 create 编号重试、进程重建加入恢复、确认凭据密封、双击提交闩、UID／锚点／CAS 变化拒绝、ACTIVE 后重复检查不换 generation。
- [x] 恢复调用 `credential(false)`／`publicKey(...,false)`，比对持久身份、公钥；创建／加入首次动作才允许生成身份。
- [x] `WAITING` 不能激活；加入方 `PENDING_CONFIRM` 不能自确认。确认必须邀请方显式点击，解封本机证明；ACTIVE 后协商 key 成功及双方能力明确才激活 session。
- [x] 手动检查／重试，不建轮询和次日任务。云端解绑失败保留进度及凭据；成功／已撤销后才原子清 session 并收口本机证明。
- [x] 在“我的 → 伴侣与同步”放开发开关控制的新连接块，不改旧按钮流程；清楚说明该连接不改变旧班表配对、共同计划与通知尚未开放。默认包不可发起新流程。

## Task 4：完整门禁与交付

- [x] `node tools/verify.mjs --steps=offline,debug,release,ohostest,perf`；原 WARN 基线不放宽，不把编译当设备运行。
- [x] 更新主计划与本批验收，列出需要用户部署的一个增量模型字段、新 dateplan 源码、部署后环境变量／超时复核；没有设备证据的行保持未勾。
- [x] 逐项写明尚欠旧连接可信映射、生命周期补删、正式计划 UI、隐私及 Push；保持两个开关关闭，保留全部 WIP。

## 执行记录

2026-10-04：本计划所列代码／离线／编译任务完成；方格仅指这些层级，不涵盖真实设备或云部署。最终机器证据、ArkTS 初跑失败及修复、关闭态清理边界与后续欠账见 `docs/validation/2026-10-04-secure-pairing-recovery.md`。原认证身份丢失、未知无 pairId 请求过期、完整清库补删等属于后续生命周期，不通过本批单独解绑替代。
