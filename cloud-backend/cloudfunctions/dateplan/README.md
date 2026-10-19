# 安全共同计划云对象 v1（正式联调准备）

## 2026-10-17 Long 读取兼容修复

Server SDK 1.0.5 会把 CloudDB Long 读成十进制字符串。additional-models.js 已在 Long getter 边界严格转为非负安全整数，修复计划写入 mutate.tx.plans 的 BAD_COUNTER，也覆盖增量游标、双方 ack 和 wake 时间戳。字段/索引不变，不清零或重建存储。诊断版本为 2026-10-17-counter1。

重新部署整个 dateplan 目录（不要只覆盖入口）；已部署的两个 worker 也更新为本轮重建 ZIP，保持环境变量和触发器。主 App 覆盖后用「核实 / 重试」恢复原请求，不重新配对或新建重复邀请。完整步骤见主仓库 docs/validation/2026-10-17-plan-storage-long-fix.md。

## 2026-10-14 一次配对更新

主 App 不再展示第二套共同计划短码流程。新增认证方法 publishLink / discoverLink，仅发现使用现有班表 HUKS 密钥加密的交接信封；route 只是公开定位哈希，不是成员凭据。原 create/join/confirm、认证身份、密钥、公钥伴侣证明与逐计划双方同意规则保留。

先给 PairMemberBinding 增量部署 bootstrapRoute:String、bootstrapOffer:Text（默认空）及 bootstrapRoute 索引，再部署包含 bootstrap.ts 的整个 dateplan 目录，双方覆盖安装。原有 ACTIVE 连接沿用；只有班表的旧用户双方点“完成连接”，新用户一次输码/一次确认后自动交接。失败暂停自动续接，保留原进度供手动继续。通知仍需另行开启；不改 Push 异步发布门禁。

详细步骤：主仓库 docs/validation/2026-10-14-unified-pairing.md。源码与本地包不是云部署或真机验收凭证。

## 2026-10-14 增量同步 / 密文归档 / 独立通知更新

本目录现在同时包含兼容 v1 与默认关闭的 storage-v2、签名唤醒功能。上线前阅读主仓库
`docs/validation/2026-10-14-cloud-latency-capacity-operator.md`。先更新模型/索引，再部署整个目录；不得只替换入口文件。

- 新增七个模型：PairPlanSyncState、PairPlanChange、PairPlanArchive、PairPlanArchiveVote、PairPlanReceiptArchive、PairPlanEventArchive、PairPlanWake。
- PairMemberBinding 增量增加 storageVersion=1、cleanupPending=false；PairDatePlan / PairPlanRequest / PairPlanOutbox 增加索引。
- FORTWO_PLAN_STORAGE_V2、FORTWO_PLAN_ASYNC_PUSH 均默认关闭。已迁移连接保持 storageVersion=2，关闭开关不回退其归档保护；不要回滚旧服务器。
- 新方法 readChanges(token,pairId,cursor)、acknowledge(token,pairId,cursor,candidatesJson)。双方同步指定结束版本后才移出活动表；密文历史与原请求响应仍保留。
- 新 worker dateplanwake（wake.handler，数据库触发器）与原 TIMER worker dateplanpush（dispatch.handler）互相独立。自动数据库触发/定时补送未经平台实测前，不开启异步投递。
- 两份 worker 都依赖 additional-models.js / storage-v2.js / protocol.js，不能复用此前不包含这些文件的旧 ZIP。
- CLEANUP_PENDING 表示连接已经停止，但删除仍未完成；保留认证/重试凭据，分批继续清理。OK 才代表所有该连接活动/归档子记录已清理。

下面内容保留原 v1 协议、认证、Push 配置与测试说明；历史“只有五个模型/一次删除”的描述不适用于 storage-v2。

2026-10-04。不替换现有 pairing/snapshot，不认领旧 PairSession。用户此前回报隔离双端协议验证通过；本次完成正式页面、可信伴侣对应、清理与通知代码，并同步源码到 CloudDevSpikeOfficial 和 FortwoCloud。**本次没有部署、操作账号或测试设备。** 正式主 App 与 FortwoCloud 属于同一项目，隔离测试项目不能替代正式项目验收。

## 服务端配置

| 环境变量 | 配置口径 |
| --- | --- |
| FORTWO_AUTH_PROJECT_ID | 当前部署项目 ID，不是 appId；正式为 101653523865149102，隔离为 101653523865155672 |
| FORTWO_SHARED_PLAN_ZONE | 当前项目的独立计划区；正式建议 FortwoPlans，隔离此前为 FortwoPlanProbe |
| FORTWO_ENABLE_SHARED_PLAN_V1 | true；未配置／false 时在数据库调用前关闭 |

保持客户端网关鉴权。dateplan 云对象保持现有平台凭据注入，不修改保留前缀变量，不跨项目复制凭据。独立传统通知 worker 也先使用平台注入的项目凭据；`PROJECT_CREDENTIAL` 是系统保留变量，不手动创建。若平台未注入，需要适配允许的凭据提供方式，不能与 Push 服务账号混用。部署单位是 dateplan 整个云对象目录，handler=dateplan.DatePlan。模型与定义必须同时部署，Server SDK=1.0.5。

## 公开协议

全部用 `{method, params}` 调用，第一个参数均为 AGC accessToken，SDK 验签、撤销校验后检查固定项目、主体、有效期。actor 为 SHA256(project,sub) 的项目内不透明标识；不接收自报操作者 UID。参数不能存入日志。

| 方法 | token 后的参数 | 功能 |
| --- | --- | --- |
| createPair | requestId, publicKey, projectionVersion=1, linkEnvelope="" | 建立独立安全会话、返回六位短码与仅创建者可取的证明；正式端提供旧班表关系的密文证明 |
| joinPair | inviteCode, publicKey, projectionVersion=1, linkEnvelope="" | 绑定真实认证接收主体，停在 PENDING_CONFIRM；正式端核实双方属于原班表配对 |
| confirmPair | pairId, confirmSecret | 仅认证创建者确认，将会话置 ACTIVE |
| pairStatus / capabilities | pairId | 本人／对方不透明标识、对方公钥、状态、协议及投影语义 |
| mutate | commandJson | PROPOSE/ACCEPT/DECLINE/WITHDRAW/AMEND/CANCEL |
| requestStatus | commandJson | 只读本人原请求回执；查不到不等于已撤销 |
| closeRequest | commandJson | 用户明确关闭未提交请求；同一绑定 CAS 写入负回执阻止迟到重放；若已提交则返回原回执，不取消计划 |
| read | pairId | 返回该安全会话的密文计划、版本；按服务端七日待确认期限处理过期 |
| registerPush | pairId, pushToken, enabled | 仅登记调用者自己的目标；不接受收件人 UID，不表示 token 已通过推送联调 |
| unpair | pairId | 同事务清理子记录，保留已撤销绑定墓碑阻止旧写复活 |
| cleanupCreate | flowId | 按认证主体与原创建流程撤销未知结果，不生成邀请 |

commandJson 精确包含 pairId, planId, requestId, action, expectedVersion, envelope，不接受 actorUid 等多余字段。PROPOSE 的 expectedVersion=0；AMEND 必须使用当前 contentRevision+1；其他动作 envelope=""。

密文信封精确包含 protocolVersion=1、contentRevision、algorithm=AES-256-GCM、12 字节 base64 IV、16 字节 base64 tag、至多 8192 字符的规范 base64 ciphertext。只验证结构，不宣称服务端验证 GCM tag、日期、明文或日程冲突；客户端以 FT_DATEPLAN|pairId|planId|contentRevision|1 验证 AAD／解密后再投影。

## 原子与幂等

五个对象同区，仅 Administrator 可读写。所有查询先于写入，每个变更读取并写入既有 PairMemberBinding.revision，包含计划尚不存在、请求账尚不存在的情况；不依赖 SDK 对缺行的验证。同一事务提交绑定 revision、计划、请求回执、通知事件。

幂等键是 **(pairId, authenticated actor, requestId)**。同一作用域相同请求返回原回执，不同载荷 REQUEST_REUSED；不同会话是独立作用域，不能共享一个无锁全局 requestId 行，否则两个会话并发可覆盖回执。回执可能比当前计划旧，客户端仍须以 stateVersion 防回滚；收到回执不代表通知已发。

实际事务冲突最多按原请求即时重读三次，非跨日任务；版本已变即 VERSION_CONFLICT。SDK／网络错误 RESULT_UNKNOWN，客户端保留原 requestId。随机短码若碰撞导致多个候选，CODE_COLLISION 拒绝，不任取一条；创建请求重试保留 pairId，但轮换证明，只存证明哈希，旧证明作废。

加入时新增管理员专用 `PairMemberBinding.recipientJoinDigest:String`，默认空；摘要绑定认证主体、原短码、设备公钥和投影版本。加入已提交但回包丢失，邀请方随后确认并清掉短码时，原加入方仍可用原参数找回同一 ACTIVE 会话。不同认证主体或公钥不能恢复；多个匹配拒绝 CODE_COLLISION，解绑清摘要。旧行默认空，不自动推断或补造历史摘要，也不承诺把旧包早已丢失的加入回包找回来。

部署顺序：先增量部署五个 clouddb 定义，确认只有新增字段且保留原区和数据；再部署整个 dateplan 目录。若工具要求清表／删区／重建，停止，不用破坏数据绕过。环境变量和超时部署后重新复核。主 App 新开关保持关闭，完整操作清单见 [用户步骤](../../../docs/validation/2026-10-04-shared-plan-operator-actions.md)。

已确认的改期仍保留 acceptedEnvelope／acceptedRevision；同意才切换。拒绝／撤回改期清除 pending，不取消旧约。七日过期是服务端保留期限，不是从密文中读取的实际约会开始时间。读取时惰性处理：初次邀请置 EXPIRED，改期清 pending 保留已确认。没有部署定时清理任务。

## 本批限制（必须保留发布门禁）

### 2026-10-04 本机收尾更新（下列新记录优先于后面的历史批次描述）

已接正式计划 UI、待确认圆点、最新本机日程冲突检查、原请求回执查询、清空补删账、HUKS 别名清理和 Push 发送器。
`PairMemberBinding` 新增 `creatorLink` / `recipientLink` 两个 Text 字段，默认空。正式客户端用旧班表配对的 HUKS 密钥
校验对端新公钥的密文证明，不能把隔离测试连接或另一位伴侣接进共同时间。旧的无证明测试连接需显式解除后重建，班表配对保留。

新增 `requestStatus(token,commandJson)` 只读本人原请求回执；`cleanupCreate(token,flowId)` 只撤销认证主体的原创建，不再生成邀请。
未知加入或原匿名身份丢失仍需人工核实，不能靠重建身份、猜 pairId 或重新加入来声称删除成功。

Push 采用鸿蒙 v3 / PS256 服务账号 JWT / WORK 分类。仅服务器持有凭据；通知不含计划标题、时间、昵称或配对标识。
事务事件账由 `push.ts` 领取，两分钟租约；每事件至多三次发送、仅一小时内尝试，每趟最多两条（计划写入后的即时发送最多一条）。
稳定 `appMessageId` / `notifyId` 与离线折叠减少重复，但不承诺恰好一次或必达。`SENT` 仅指平台接受。
代码包含独立 timer 入口 `dispatch.handler`；构建命令 `node tools/build-dateplan-push-worker.mjs`，不使用 CloudDev 云对象的 HTTP 触发器冒充 timer。
worker 的 AGC 部署与 TIMER 触发器仍须用户操作；未部署时不能声称应用关闭后的失败补送已启用。
传统 Node.js 入口使用 `callback(object)` 返回结果。worker 另需 `FORTWO_PLAN_DISPATCH_SECRET` 和相同的 scheduler 输入；缺失或错误在调用 SDK 前拒绝。不要配置公开 HTTP 触发器。

环境变量：既有 `FORTWO_AUTH_PROJECT_ID`、`FORTWO_SHARED_PLAN_ZONE`、`FORTWO_ENABLE_SHARED_PLAN_V1`；新增
`FORTWO_ENABLE_PLAN_PUSH=true` 和服务账号云端配置：原单变量 `FORTWO_PUSH_SERVICE_ACCOUNT`，或 2026-10-10 新增的
`FORTWO_PUSH_SERVICE_ACCOUNT_PARTS=N`、`FORTWO_PUSH_SERVICE_ACCOUNT_1` 至 `_N`（1–32 段、每段最多 512 字符）。
两种配置互斥，缺段/额外段/混填/非法 JSON 均拒绝；部署目录和 worker ZIP 必须包含 `push-account` 模块。
worker 在访问数据库前验证配置/项目/签名格式，只输出固定错误码。详细步骤见 `docs/validation/2026-10-10-push-worker-setup.md`；历史步骤见
`docs/validation/2026-10-04-shared-plan-operator-actions.md`。

本机验证并非发布批准：真机、项目/应用/签名、权益、托管政策和正式通知尚待用户验收；每连接 50 个计划 / 200 个业务请求 /
400 个事件的安全上限保持，未做无限历史归档或自动到期物理删除，首发公开运营前必须明确容量与清理策略。

当前证据边界：

- 正式 UI、可信对应与通知已接代码，客户端新开关仍默认关闭。sharedPlanReady 仅描述会话能力，不证明正式云端或手机可用。
- 不自动升级旧 pairId＋uid，不覆盖旧班表快照；现有班表密钥仅用于校验新连接属于同一伴侣，不把旧协议冒充新认证协议。
- 每会话暂限 50 个计划、200 个业务请求、400 个事件，未部署归档／清理策略，达到上限 BACKLOG_FULL。这是保守隔离边界，不是可直接发布的运营策略。
- 级联删除先核对条数和 1.5 MB 安全预算；越界 CLEANUP_REQUIRED，保持凭据与数据，不做截断删除。正式发布前须补可审计分批清理与恢复方案。
- 撤销绑定保留双方主体哈希、创建请求摘要及时间，不再含公钥／短码／证明；字段表达拟保留 30 天，但尚无实际定时删除任务，不能在隐私政策中承诺已经自动到期删除。
- 六位码尝试频控、匿名账户滥用防护、真实撤销令牌、密钥持有／对端确认、HUKS 实际加解密均未由本批测试替代。
- PushTarget 只允许认证成员登记本人目标，端侧主动请求通知许可；真实 token、签名与权益、秘密管理及锁屏送达仍需正式账号与设备验收。
- PairPlanOutbox 已接发送器及有限重试代码，云端部署与 cron 尚待用户执行；不能把构建 ZIP 说成在线定时任务。

## 验证

`node cloud-backend/test/dateplan-contract.mjs`：实际 Server SDK strict/noEmit＋注入事务存储回归。存储桩只验证已存在读行，故意不锁缺行；关掉 CAS 的反事实会出现两个胜者，表明竞争断言不是天然通过。

本批 ES2020 / ES5 各 47 条通过；此测试不能替代云端跨表提交与设备演示。最终本机证据见 [交接记录](../../../docs/validation/2026-10-04-shared-plan-final-handoff.md)，人工步骤见 [操作清单](../../../docs/validation/2026-10-04-shared-plan-operator-actions.md)。
