# 共同计划双向确认与系统通知 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 云配对双方确认后才生成活动计划，并通过系统通知覆盖应用未打开及锁屏。

**Architecture:** 可信认证成员＋独立加密共同计划协议＋事务状态机＋本地已确认投影＋服务端推送事件账；不以快照回包代替确认。

**Tech Stack:** ArkTS/ArkUI API 26、RDB、HUKS、CloudDev 云对象、CloudDB Server SDK 1.0.5、Push Kit。

**Spec:** `docs/plans/2026-10-03-shared-plan-confirmation-design.md`。用户已同意产品方案；账号、云部署和设备破坏性动作仍需逐项授权。上述执行子技能若当前不可用，按本清单单代理逐任务执行，不凭空调用、不擅自委派。

## Global Constraints

- 保留工作树所有既有 WIP，不自动提交；不操作模拟器、不卸载、不清库、不解除现有配对。
- 无账号操作、生产部署、凭据读取／输出；用户自行完成控制台和设备步骤。
- 保持班表 CRD1 schemaVersion=2。新的共同计划 protocolVersion 独立。
- 未确认不计算；未收到服务端成功不显示已确认；按钮手动重试，不恢复次日自动重试。
- API 声明、离线测试、真实云端和真机通知分别记录，任何前一层不能替代后一层。
- Task 0 两个云端前置未证实前，不开放 Task 1–5 的生产写入／接通状态；可以继续准备离线纯模型。

## Task 0：隔离身份与事务预检（先过门槛）

**Files:** 新建 `experiments/shared-plan-preflight/cloudfunctions/sharedplanpreflight/{authProbe.ts,sharedplanpreflight.ts,package.json,function-config.json}`、`experiments/shared-plan-preflight/test/auth-probe.mjs` 与 `README.md`。此工程不读写生产配对表，不导入生产 HUKS 别名，不注册推送 token。

- [x] 编写 `inspectVerifiedToken(accessToken, expectedProjectId, verify)`：空配置／空令牌在 SDK 调用前拒绝；调用 SDK 验签及撤销校验后再校验项目、主体和过期时间；只返回脱敏主体指纹，不返回令牌／完整主体。
- [x] 云对象方法 `SharedPlanPreflight.verifyIdentity(accessToken)` 只读服务端环境变量 `FORTWO_AUTH_PROJECT_ID`；公开方法不依赖 this，兼容云对象提取方法的执行方式。
- [x] 注入验证器测试缺配置、空输入、验证异常、错误项目、空主体、过期／无效 exp、合法输入、不同主体、敏感错误不回显，以及 checkRevoked=true。
- [x] 使用已安装 SDK 进行 TypeScript noEmit 类型检查，不能只 transpile 后声称类型通过。

生产形态依据，且要校验返回的 getAud/getSub/getExp：

```ts
const auth = cloud.createInstance(undefined, 'fortwo-plan-preflight', Region.REGION_CN).auth();
const verified = await auth.verifyAccessToken({ accessToken, checkRevoked: true });
```

- [x] 隔离 CloudDev 对象及真实客户端入口完成；用户于 2026-10-04 回报两台不同主体、错误令牌与事务探针“测试完全通过”。此为用户执行回执，不是 AI 代跑或原始截图归档。
- [ ] 错误项目、真实过期／撤销令牌仍需独立真实用例；原三个按钮没有覆盖它们，离线负向用例不替代云端证据。
- [x] 编写隔离 `PlanCasProbe` 对象定义及真实 SDK 事务调用探针：PK id、整数 version、state、createdAt；初值 version=1/state=PENDING。增加有界重叠读取仪器，不用它代替云数据库 CAS。
- [x] 用户部署新对象类型、创建隔离存储区 FortwoPlanProbe，回报真实事务探针通过。
- [x] 原事务探针竞争结果按用户“完全通过”回执确认；重复 requestId 由 Task 1 的业务请求账另测，原探针不含业务幂等接口。

事务调用依据如下；query 为该表 PK 的 CloudDBZoneQuery，nextRow 为该表真实生成模型实例，均不得用无类型对象替代：

```ts
await collection.runTransaction({
  async apply(transaction) {
    const rows = await transaction.executeQuery(query);
    if (rows.length !== 1 || rows[0].getVersion() !== expectedVersion) return false;
    transaction.executeUpsert([nextRow]);
    return true;
  }
});
```

- [ ] 归档原始真实回包／最终行截图；目前只有用户通过声明。新业务跨表事务、身份绑定、推送仍逐项验收，不以旧探针通过替代。

## Task 1：安全配对绑定与独立云计划

### 2026-10-04 执行细化

用户回报隔离身份、错误令牌、事务竞争测试完全通过，按“用户执行回执”解除开发前置；原始截图未归档，错误项目／真实撤销令牌仍需独立取证。先实现并在隔离工程部署新的 `dateplan` 云对象，不重部署生产 pairing/snapshot，不自动认领旧配对。

- 新安全配对在独立 `PairMemberBinding` 保存服务端验证主体的项目内哈希、双方公钥和确认凭据哈希。创建／加入／确认只接受认证 token，不接受操作者 uid。旧接口与新模型分区分表，旧 uid 无法解除或写入新会话。
- `PairDatePlan`、`PairPlanRequest`、`PairPlanOutbox`、`PairPushTarget` 与绑定在同一存储区。每次写计划事务读取并更新既有绑定的 revision，序列化同一会话内竞争，不能依赖对“不存在记录”的读校验。
- 所有事务先读后写；状态＋幂等结果＋通知事件同提交。在 `(pairId, authenticated actor, requestId)` 作用域内相同 requestId 不同载荷拒绝；不同会话独立，不能用一个无锁全局请求行互相覆盖。SDK 异常返回结果不确定，不谎报成功。历史幂等回执不覆盖更高版本客户端缓存。
- 独立测试客户端仅用随机不含个人信息的密文格式夹具验证服务端元数据，不能称为端到端加密验证，也不在正式应用生成计划。
- 文件：新增 `cloud-backend/cloudfunctions/dateplan/{identity.ts,protocol.ts,service.ts,dateplan.ts,models.js,models.d.ts,package.json,function-config.json}`、五份对象定义、`cloud-backend/test/dateplan-contract.mjs`；新增隔离客户端 `SecureSharedPlanPanel.ets`。已有生产源码不改。
- 验证：真实 SDK strict/noEmit、注入事务存储的安全／并发／回滚／幂等回归，既有配对契约回归，隔离客户端编译。用户部署新增模型与 dateplan 后再测试双端安全配对／邀请／确认，通知发送和本地活动投影另批。

**Files:** `cloud-backend/cloudfunctions/pairing/{pairing.ts,contract.ts}`；新建 `cloud-backend/cloudfunctions/dateplan/` 的 handler、contract、状态机、models 与 function-config；新建对应 CloudDB 对象类型定义、导出模型和 `cloud-backend/test/dateplan-contract.mjs`。先确认现有生成模型文件存放方式，不能覆盖现有 PairSession/PairSnapshot。

- [ ] 先写并跑红服务端测试：伪造 uid、非成员、另一方推送目标、旧接口解除新安全会话、跨 pairId、重复 requestId、相同 requestId 不同内容、版本竞争。
- [ ] 在新 create/join 流程验证认证主体后绑定角色；旧 pairId＋uid 禁止懒绑定。旧会话保留原功能，新共同计划能力返回不可用；安全升级另外取证。
- [ ] 定稿 PairMemberBinding、PairDatePlan、PairPlanRequest、PairPushTarget、PairPlanOutbox 的主键、索引、期限、读取权限和删除关系，再生成真实模型。
- [ ] dateplan 提供 propose/read/respond/withdraw/cancel/amend/capabilities；respond 动作为 ACCEPT/DECLINE，所有写入携带 requestId 和期望 stateVersion。
- [ ] 状态、幂等账及通知事件放在同一真实事务；服务端决定对方角色，忽略客户端所谓操作者身份。
- [ ] 密文 AAD 使用 contentRevision 而非 stateVersion；接受只改状态，改期才改内容版本。密文坏了客户端拒绝投影，服务端不解密、不假验时间冲突。
- [ ] 发布前完成新安全会话解除的级联删表及旧接口防绕过。身份／云部署不通过时不启用入口。
- [ ] 用户先部署新增隔离对象及模型验收，再依据部署差异清单部署正式服务；核查部署后超时配置，不能随手重新部署覆盖现有配置。

## Task 2：本地缓存、状态机和活动投影

**Files:** 新建 `feature/src/main/ets/model/SharedPlanFlow.ets`、`feature/src/main/ets/usecase/SharedPlanUseCase.ets`、`data/src/main/ets/repo/SharedPlanRepo.ets`、`cloud/src/main/ets/api/SharedPlanApi.ets`；修改对应 Index、`data/src/main/ets/db/{Db.ets,MigrationRunner.ets}`、`ScheduleRepo.ets`、`ScheduleUseCase.ets`、PresentationModels 及测试 runner。

类型至少包含：pairId、planId、contentRevision、stateVersion、state、解密后的 title/kind/start/end、有效已确认修订、待确认改期。用独立待发送队列，不能拿 PENDING 当“还没发”。UseCase 提供 propose/respond/withdraw/cancel/refresh。

- [ ] 先红：待确认不入活动表、离线确认不落地、重复刷新只一行、旧版本结果不回滚新状态、换会话旧请求不写新会话、改期拒绝保留旧时段。
- [ ] 迁移版本从当前真实版本增量推进（现为 v4，实施时再次核对）；新缓存／发送账独立表，活动 plan 增加 shared_pair_id/shared_plan_id/shared_content_revision 或等价来源映射。
- [ ] 使用 `shared:<pairId>:<planId>` 稳定映射，缓存更新与活动投影本地事务化；仅有效已确认修订参加计算。
- [ ] 快照生成在合并前排除共同计划来源，保留个人计划。加入双方能力／投影语义标记，未知语义不可直接采用。禁止从合并忙碌区减去计划区间。
- [ ] 同意前校验最新本机日程和时间是否已过；冲突与已同意状态分开，不自动取消承诺。
- [ ] SQL 回归测试旧 DB 升级、已有循环列、旧计划保留、迁移失败、相同 shared ID 幂等、真实班次与共同计划重叠仍报告冲突。
- [ ] 所有异步请求回写复核当前 pairId／认证主体；身份丢失停止写入并显示重连状态。

## Task 3：创建入口、待确认卡、圆点和状态反馈

**Files:** `entry/src/main/ets/component/WindowDetailSheet.ets`、`entry/src/main/ets/view/{PlansView.ets,CoTimeView.ets}`、新 SharedPlanCard、feature PresentationModels／查询服务、`docs/prototype/index.html`。

- [ ] 云配对且能力通过时使用“发送邀请”；本机代录／单人保持“创建计划”；能力不可用明确说明，不静默降为本地共同计划。
- [ ] 三组卡片与手动重试，动作提交闩；邀请发送成功与计划确认成功使用不同提示，不让用户以为发送即占用。
- [ ] 圆点由持久 pending 数量推导，查看列表不清零；待发送与读取失败另标，不丢缓存。
- [ ] 新接收卡显示清楚的跨天日期和本机 TA 名字；只有本人角色相应动作可点。
- [ ] TodayAgenda、Home、周历与共同空闲各补反例测试，证明 PENDING 确实没有参与。
- [ ] 原型镜像与实际 UI 同步，不重做本轮已完成的计划类型／标题行／动效。
- [ ] 执行离线门禁及 debug/release/ohosTest 编译；设备渲染与点击仍单独列待验证。

## Task 4：Push 系统通知及点击路由

**Files:** 新建 `entry/src/main/ets/integration/PlanPushGateway.ets`；修改 `EntryAbility.ets`、白名单路由、通知入口与必要配置；新建服务端推送发送器／目标登记接口／事件处理器测试。

- [ ] 用户完成正式应用 Push 服务、分类权益、签名配置后，按本机 API 26 声明编写 token 和通知权限接口；不假设 wearable tokenUpdate 事件适用于手机。
- [ ] 用户主动开启共同计划通知时再申请通知权限；拒绝不影响计划同步。通过认证登记本人 token，不把 token 回给伴侣。
- [ ] 前台与冷启动 Want 分别处理，只收白名单业务类型和必要 ID，查询服务端状态后定位卡片。未经校验的 Want 不直接确认计划。
- [ ] 服务端凭据来自安全配置，鸿蒙 Push v3；事件账按稳定 eventId 处理，发送失败不回滚已确认。若需要定时补送，明确部署频率、上限、到期和项目配额，不凭空声称会重试。
- [ ] 前台去重不整页闪动，锁屏默认无具体标题／时间。解除／清库／恢复／token 更新后使旧目标无效。
- [ ] 离线测试通知端口桩与路由校验；真机分别测前台、后台、正常划走、锁屏、权限拒绝、免打扰。只观察符合系统设置的结果，不承诺强杀后的可靠投递。

## Task 5：清理、政策、发布和最终验收

**Files:** ProfileSettingsService、Backup 生命周期、待补删账／新安全删除能力、legal 三处与随包文案、copy-audit、release 清单、cloud operations-runbook、testing-checklist。

- [ ] 补删凭据能够被新服务端安全认证；旧裸 uid 不作为新安全会话授权。无法补删时仍有用户可读欠账，不谎报成功。
- [ ] 清库／解除／恢复并发时取消未完成 UI 请求；旧 token 与旧计划投影不重新冒出来。破坏性验证仅在用户明确指定的可丢弃设备进行。
- [ ] 更新认证与推送的隐私披露、保存／删除期限，三处全文一致后跑 copy-audit；用户同步发布 AGC 托管全文。
- [ ] `node tools/verify.mjs`＋独立后端契约用例＋真实云端探针＋两台真机矩阵分别留证，不把 ohosTest 编译当执行。
- [ ] 记录正式签名、云区域、服务端秘密管理、配额、旧版本策略及回滚；客户端功能开关必须有实际读者并严格阻止未就绪写入。
- [ ] 仅当设计文档 §9 全部满足，才标记共同计划及系统通知“已接通”。

## 执行记录

2026-10-04：方案落文档，隔离身份预检代码完成。`node experiments/shared-plan-preflight/test/auth-probe.mjs` 实测 exit 0，真实 SDK noEmit 类型检查通过，12 个离线用例通过。第一次测试暴露测试桩用默认参数把 undefined 主体补成合法主体，改用显式 getter 后负向用例正确拒绝；未改变生产验证规则。

现有生产配对／班表／计划功能未改。本轮未重跑主应用出包（没有主应用源码变化），未部署或操作设备。Task 0 的真实认证与事务仍未完成，Task 1–5 未实施；Push 显示未验收。

已有 `node cloud-backend/test/pairing-contract.mjs` 回归通过；文档改动 `git diff --check` 通过。无提交、无现有数据清理。

### 2026-10-04 后续实施批次

- 已在主项目新增 `SharedPlanFlow.ets` 并导出、加入 runner 和 Hypium：17 项纯规则测试，覆盖角色、状态版本、活动投影、改期保留旧约、稳定 ID、终态不复活、去重、内容 AAD 与深拷贝。这只是 Task 2 的基础规则，不是完整 UseCase/RDB 或实际页面接线。
- 隔离探针扩展为身份＋事务竞争，20 项离线用例及真实 Server SDK noEmit 检查通过；有意移除 CAS 的测试桩会返回 RACE_FAILED，普通网络异常不冒充合法冲突。
- 已将新云对象源码与 PlanCasProbe 定义写入既有 CloudDevSpikeOfficial；仅新增文件，没有改默认区、旧函数或任何凭据。新函数依赖安装完成。
- CloudDevSpikeOfficial 首页新增独立测试入口，Auth SDK 实际安装版本 1.1.0；客户端 assembleHap BUILD SUCCESSFUL，保留原来测试入口。没有运行设备、部署云端或开通账号服务。
- 真实身份、错误项目／撤销令牌、真实 CloudDB 竞争及系统推送均待用户操作。Task 1、Task 3–5 未实施；不把纯规则测试和客户端编译作为这些任务完成证据。

完整门禁：offline 两档各 317 passed / 0 failed、typecheck 0；debug/release/ohosTest 均 BUILD SUCCESSFUL，WARN 287/287/267，基线未改；perf exit 0；`verify: ALL PASS`。详情见 [本批回执](../../validation/2026-10-04-shared-plan-development.md)。

### 2026-10-04 第二批

用户回报前置测试完全通过后，新增独立 dateplan 服务和五个管理员专用模型；不修改、部署或认领旧 pairing/snapshot。可信认证绑定、版本转换、业务幂等／通知事件同事务、过期修订、小规模解绑已代码实现，32 项离线回归及实际 SDK strict/noEmit 通过。隔离测试页已放入 CloudDevSpikeOfficial 并编译成功，新函数依赖安装完成；尚未部署新业务服务。

主 App 源码本批零修改。只重跑 offline 两档（各 317 全绿）与 perf；不把上批主 App 三档出包计为本批重跑。新增模型／新业务跨表事务及双端流程需用户按 [第二批验收](../../validation/2026-10-04-secure-dateplan-acceptance.md) 部署／验证。Task 1 不判整体关闭：正式兼容、限额归档、频控、真实安全矩阵仍欠；Task 2 的 RDB／密文／投影、Task 3–5 未接通。

### 2026-10-04 第三批：本地持久化与编排

用户回报隔离双端测试全部通过，登记为用户执行证据，原始完整截图仍待归档，不扩展成 HUKS／Push 的验收。

正式应用新增 v5 的安全会话、权威记录缓存、待发送账与计划来源映射；缓存和已确认活动投影在同一事务中保存，旧版本、旧会话回包不能覆盖新记录。新增 SharedPlanUseCase 与实际 RDB 存储适配器，通过注入端口先落请求再发送；失败手动重试原 requestId，不做离线假确认。班表快照在合并前排除来源映射对应的活动，个人计划不排除，本地计算仍包含已确认共同计划。

Task 2 部分完成：纯规则、本地迁移／仓储／编排基础与来源排除已实现；真实身份、加密传输、冲突日程适配器、双端能力语义协商及设备升级仍未接线。不能把全部 Task 2 方格勾上。Task 3–5 未接通。未改 CRD1 schemaVersion，未绑定旧会话，未部署云或操作设备。

实测 verify 五步 ALL PASS；offline 两档各 330 passed / 0 failed、typecheck 0；debug/release/ohosTest 编译 WARN 287/287/267，基线未改；perf 在开发机预算内。真实 SQLite 执行生产 SQL 的迁移／事务／幂等回归通过；dateplan ES2020、ES5 各 36 条离线回归通过。这些不替代真机/设备数据库执行。详见 [本批验收](../../validation/2026-10-04-shared-plan-local-projection.md)。

### 2026-10-04 第四批：可信身份与持久密文传输

主应用加入真实 Auth 1.1.0 的惰性匿名身份提供器和独立 dateplan 调用；启动只 attach，不自动登录。新增独立 HUKS 计划身份／协商别名、P-256 公开点处理和 AES-GCM 信封，旧班表别名与 CRD1 保持兼容。安全 Gateway 核验服务端 ACTIVE 成员、能力、身份和本机会话代次；任一密文／成员／修订不合法均不返回部分可投影列表。

数据库 v5→v6 加 `shared_plan_wire`：PROPOSE／AMEND 在首次发送前持久保存首份密文，手动重试使用同一 nonce、requestId、动作和版本。草稿与密文账同事务清理；存储失败不发未记账的变更。补齐真实 dateplan 终局拒绝码与身份在能力核验期间切换的反例，并补 HUKS 加密失败会话释放。

本批是主计划 Task 2 的真实传输基础，不是所有 Task 2 完成。新功能开关仍关闭且实际控制 Gateway；正式安全配对 UI、生命周期、真实冲突适配器、计划卡、圆点和 Push 仍待开发。没有根据旧 pairId／uid 自动升级，没有操作设备、部署云端或提交 WIP。实际设备 HUKS／Auth／数据库升级仍待专门双端验收。

完整实现、失败修复过程、最终门禁与用户操作边界见 [第四批回执](../../validation/2026-10-04-shared-plan-secure-transport.md)。下一批依次接显式安全配对与恢复、真实冲突／清理生命周期、正式计划 UI，随后接后台及锁屏 Push；这些未完成前不启用新功能、不宣布主应用已双端共确。

### 2026-10-04 第五批：显式安全配对与恢复

接第四批，正式客户端新增持久操作意图、HUKS 独立密封确认凭据、显式创建／申请加入／邀请方确认／手动恢复与单独解除。ACTIVE 与安全计划会话同事务装配，旧回包不能复活清空的进度；恢复不会创建新匿名身份或新身份密钥。关闭档保留已有进度的只读与清理入口，但不可新建／加入／确认，不自动联网。

服务端新增一个 PairMemberBinding 字段 recipientJoinDigest，修复加入成功但回包丢失、随后短码被确认清除时原加入方无法找回会话的问题；绑定认证主体、短码、公钥、投影版本，重复匹配拒绝。已同步隔离 CloudDevSpikeOfficial 源码，未部署，正式 FortwoCloud 未改。

最终五步 verify ALL PASS：offline 两档各 331 全绿、typecheck 0；客户端编排专项 18、密码学专项 20，后端 ES2020／ES5 各 38，全绿且单列；debug／release／ohosTest WARN 277／275／257，原基线不变；perf 在预算内。没有操作设备、卸载、清数据或提交 WIP。

这里只完成默认关闭的安全连接基础与测试入口，不关闭主计划 Task 1–5。原配对与新认证成员可信对应、真实日程冲突适配器、清库补删／身份丢失终局清理、正式计划 UI 和 Push 仍欠；securePairing=false、sharedPlan=false。完整边界与模型先于对象部署的操作清单见 [第五批回执](../../validation/2026-10-04-secure-pairing-recovery.md)。下一批优先真实冲突及完整删除生命周期，然后可信对应／计划页面，最后 Push 与隐私发布。

### 2026-10-04 第六批：真实冲突与安全清理

按用户“无需操作就继续”的授权接本人最新本地日程，复用领域展开并在合并前仅排除当前安全会话的本计划来源。前一晚夜班、课程、通勤／恢复／作息和另一个同时间计划仍阻断。结果未知后的重试也核对原候选；新冲突不重发且保留原请求，旧 ACCEPT 缓存变更时不猜测原内容。

本地 v8 独立最小清理账与进度 CAS 同事务，业务清空转账／删除同事务；旧 v7 进度、重复清空、失败回滚、破损进度、恢复备份都有非授权保留或冻结路径。清空时阻止新操作，进程内代次不写入持久锚点；恢复不新建身份。已知连接仅以现有原 SDK UID 补删，结果未知留账，明确终局留待核实；“我的”显示摘要及手动重试，回前台最多两笔且不设定时器。仍有欠账时不能再加入旧会话，以免补删误伤。

最终无重叠串行五步 verify ALL PASS：offline 两档各 333 全绿、typecheck 0；本地策略／清理专项 26、安全配对编排 20、密码学／传输 20 单列通过；debug/release/ohosTest WARN 278/276/258，基线未改；perf paired120 P50 14.4ms，投影预算内。本批没有云端源码／模型变动、部署、设备操作或提交 WIP。

真实冲突端口及已知身份的清理基础已实现，但**完整删除／未知计划终局回执仍未闭环**：无 pairId／丢身份清理、密钥交错扫尾、原班表成员可信对应、正式 UI／红点／Push、隐私与设备矩阵仍欠。主计划 Task 1–5 不整体关闭，新开关仍为 false。现在没有必须由用户执行的动作；下一批先补认证终局解析／只读请求回执，再接兼容与正式页面。见[第六批验收与操作边界](../../validation/2026-10-04-shared-plan-conflict-cleanup.md)。
