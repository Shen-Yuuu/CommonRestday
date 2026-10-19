# 第二批：安全配对与共同计划云端验收

日期：2026-10-04。原身份／错误令牌／CAS 三项由用户回报“测试完全通过”，记为用户执行回执；AI 未操纵设备，没有原始回包附件。错误项目及真实撤销令牌仍需独立取证。

## 本批已实现与证据

- 新独立 `dateplan` 云对象：认证主体绑定、安全短码创建／加入／确认、密文邀请与双方角色、同意／拒绝／撤回／改期／取消、幂等回执、同事务通知事件、本人推送目标登记、小规模级联解绑。
- 五个新对象定义／模型均只授予 Administrator 读写；没有修改原 PairSession/PairSnapshot 和生产云对象。既有 WIP 未提交、未暂存。
- 写事务以既有绑定 revision 为冲突锚；同意／撤回与解除／同意竞争、缺行提案竞争、请求回包丢失均离线回归。
- `node cloud-backend/test/dateplan-contract.mjs`：实际 SDK strict/noEmit，通过 32 项离线用例。真实 SDK 声明，不是仅 transpile；含请求积压与超量清理不截断的反例。
- `node cloud-backend/test/pairing-contract.mjs`：PASS，既有邀请码／确认契约未改变。
- `node tools/verify.mjs --steps=offline,perf`：ALL PASS；闭／开档各 typecheck 0，317 passed / 0 failed；perf 在开发机预算内。**本批主 App 源码零修改，不复用上批 debug/release/ohosTest 出包结果冒充本批重跑。**
- CloudDevSpikeOfficial Application：新增“安全配对与共同计划验证”路由，debug assembleHap BUILD SUCCESSFUL；已有 Auth SDK 声明／资源告警保留，不声称零告警。依赖安装完成。

未部署任何云资源，未更新证书／Profile，未安装／启动／清空／解绑设备。当前正式应用仍是原来的本地计划流程，新服务不是已发布能力。

## 1. 你先部署（同一个测试工程）

1. 打开 **CloudDevSpikeOfficial/Application**，刷新 CloudProgram；仍关联 `com.common.fortwo.cloudspike`，不是正式“两人份”。
2. `CloudProgram/clouddb/objecttype` 新增五个定义：PairMemberBinding、PairDatePlan、PairPlanRequest、PairPlanOutbox、PairPushTarget。右键 clouddb → Deploy Cloud DB。既有 db-config 默认区仍为 default，不修改。
3. 到该测试项目 AGC“云数据库 → 对象类型”确认五类已存在、非 Administrator 均无读写权限。使用之前建好的 **FortwoPlanProbe**，不用再建区，不删除任何旧表／区。
4. 右键新增 `cloudfunctions/dateplan` → 云对象部署；只部署 dateplan。**不部署 FortwoCloud 的 pairing/snapshot，不复制到正式工程，不重部署 sharedplanpreflight。**
5. AGC 对应新函数环境变量填写下表，保持客户端网关鉴权，不新增 AGC_ 前缀变量。保存等待 10–20 秒。

| key | value |
| --- | --- |
| FORTWO_AUTH_PROJECT_ID | 与之前身份探针相同的测试项目 ID（不是应用 ID） |
| FORTWO_SHARED_PLAN_ZONE | FortwoPlanProbe |
| FORTWO_ENABLE_SHARED_PLAN_V1 | true |

6. 在两台可丢弃模拟器运行更新的测试 Application：首页 → **安全配对与共同计划验证**。沿用当前有效签名，不卸载、不清数据。已有正式 App 配对完全不动。

如果新模型部署失败，先发具体错误，不要删除已有对象类型解决。函数部署只包含自身目录；models.js/.d.ts 已随包放好，不需要手工复制正式凭据。

## 2. 建立新的隔离安全配对

1. 两台设备保持在新测试页，不退出、不重启测试应用。A 点“A · 生成安全测试码”，应 code=OK、WAITING、显示六位码。
2. B 输入 A 的码，点“B · 加入安全测试配对”，应 code=OK、PENDING_CONFIRM。这里不会弹二维码／链接。
3. A 点“A · 确认安全配对”，应 code=OK、ACTIVE；B 点“刷新配对状态”，也应 ACTIVE。两端 pairId 相同。
4. 若 A 证明因返回丢失而不可用，在同一页面重新生成，会保留本次创建 requestId 的 pairId 并轮换证明。不要复制证明到聊天。退出页面会丢失测试 UI 临时凭据，新开页面另建测试会话；不能把这个非持久化演示当正式配对体验。

公钥为已知公开曲线点、密文为不含个人数据的格式夹具。此步骤只验证可信角色及事务，不证明设备独立私钥、真实 GCM tag／AAD 或 HUKS。不要在此页录入真实日程或 Push token。

## 诊断补丁（2026-10-04，diag1）

用户设备在 A 同意本人邀请时返回 RESULT_UNKNOWN；原日志只有平台请求记录，不能定位业务异常。现已给 dateplan 增加安全诊断（尚未由本机部署）。日志标记 FORTWO_DATEPLAN_DIAG，build=2026-10-04-diag1，记录方法、执行阶段、固定错误类别、数值 SDK 错误码和仅限本项目文件名/行号的定位信息。不输出原始异常消息、完整堆栈、访问令牌、确认凭据、成员身份、请求正文或计划密文。

返回 message 附诊断编号，现有测试客户端无需重装即可显示。离线 SDK strict/noEmit PASS，34 项通过（新增脱敏与日志失败隔离两项）；不代表原云端问题已修复。

手动复验：保持两台测试页，右键 CloudProgram/cloudfunctions/dateplan → Deploy 'dateplan'；部署后核对三个环境变量与原值一致，并检查超时配置是否被部署重置。无需再次部署 clouddb，不改模型，不卸载、不清库。A 点击一次「按原 requestId 重试」。在 AGC「质量 → 云监控 → 日志服务」按 dateplan、对应时间筛选，搜索 FORTWO_DATEPLAN_DIAG，将与屏上诊断编号一致的一条发回。仍预期 FORBIDDEN；未得到明确结果前不继续 B 的同意步骤。

## 3. 邀请与确认

### diag2 回执（2026-10-04，仍待云端复验）

用户提交 diag1 日志：operation=mutate、stage=auth、code=RESULT_UNKNOWN。核对实际部署产物 `CloudProgram/build/target/2df70/dateplan/dateplan/tsconfig.json`：没有 target，生成 identity.js 使用 ES5 的 `__extends`。本地加载该部署产物验证 `new Rejection('FORBIDDEN') instanceof Rejection` 为 false（instanceof Error 为 true）。因此明确的业务拒绝被 guarded 误分类。这证明了误报机制，但尚不能证明本次鉴权失败究竟是配置、令牌还是 SDK。

修复：Rejection 构造函数显式恢复 prototype；日志 build 升为 2026-10-04-diag2；mutate 的身份校验阶段细分 featureGate/projectConfig/tokenInput/sdkVerify/audience/subject/expiry，仍不打印任何令牌或原始异常。增加部署 ES5 输出下的同套业务回归以及异常类型、鉴权阶段断言；ES2020、ES5 两档分别 36 passed/0 failed，SDK strict/noEmit PASS。源文件已同步至测试工程，不改生成的 build 产物，不操作设备、云资源或现有配对。

下一步只重新部署 dateplan 并保留环境变量。A 原 requestId 重试；FORBIDDEN 才关闭本人同意拒绝这一格；若为 AUTH_REJECTED/FEATURE_DISABLED/CONFIG_MISSING，则以 diag2 的 stage 继续定位。本次不宣称真实鉴权失败已经修复。

1. 两端计划 ID 保持 `demo-plan-1`。A 点“发送测试邀请”，应 PENDING、stateVersion=1、contentRevision=1、acceptedRevision=0。
2. B 点“刷新计划列表”，选择该行，看到同一个 PENDING/v1/已确认修订 0；A/B 的正式 App 今日安排都不应改变（这本来就是独立测试应用）。
3. A 故意点“同意”，应 FORBIDDEN；B 点“同意”，应 ACCEPTED/v2/已确认修订 1。A 刷新后应相同。
4. 在 AGC 数据页选择 FortwoPlanProbe：PairDatePlan 同一行应 v2；PairPlanRequest 两笔（PROPOSE、ACCEPT）；PairPlanOutbox 两笔对应事件，status=PENDING。**PENDING 事件不是设备已收到通知。**

## 4. 改期与取消

1. 已确认 v2 时 A 点“改期夹具”：state 仍 ACCEPTED，stateVersion=3、contentRevision=2、acceptedRevision=1，证明旧约未被新提案提前替换。
2. B 刷新、选择该条，点“暂不安排”：stateVersion=4，acceptedRevision 仍 1，pendingAuthorUid/pendingEnvelope 清空（可在 AGC 查）。
3. A 刷新后再点“改期夹具”，应 v5/contentRevision=3/acceptedRevision=1。B 刷新点“同意”，应 v6/acceptedRevision=3。A 刷新一致。
4. 任一端“取消已确认计划”，双方刷新后 CANCELLED。再次同意返回 STATE_CONFLICT，不复活。

## 5. 拒绝、撤回与竞争

1. A 输入新 ID `demo-plan-2`，发送；B 刷新选择新条、暂不安排，双方刷新 DECLINED/已确认修订 0。
2. A 输入 `demo-plan-3`，发送后撤回，B 刷新应 WITHDRAWN/已确认修订 0。
3. A 输入 `demo-plan-4`，发送；双方先刷新／选中同一条 v1。A 撤回、B 同意尽量同时操作：一端 OK，另一端 VERSION_CONFLICT；刷新后只能一种终态、版本 2。两端都 OK 必须停止，不判通过。
4. 网络故障导致 RESULT_UNKNOWN 或调用无回包时，不生成新请求；点“按原 requestId 重试”。成功后同一计划只推进一次、请求账／事件不重复。不要为造失败卸载或清数据。

本页没有解绑／清库按钮。真实解绑/HUKS/第三主体/撤销 token 的破坏性矩阵另行明确步骤，不能让用户随手删除测试表来模拟应用行为。

## 6. 回传与后续

回传安全配对 ACTIVE、邀请 PENDING、同意 ACCEPTED、改期／竞争回包及对应三表截图；不要发 token、confirmSecret、私钥、Push token 或完整日志参数。完成后将 **dateplan** 的 FORTWO_ENABLE_SHARED_PLAN_V1 暂设 false；不要动正式云开关或其他函数。

这批通过后继续正式客户端匿名身份／安全会话迁移、HUKS 计划密文、本地 RDB 缓存与已确认投影、三组计划卡／持久圆点、班表快照去重语义，再接 Push 发送器和锁屏点击路由。上述未完成前，不发布新功能，不把已有测试 App 的画面当正式产品。

正式发布前还须补：短码尝试频控、匿名账号滥用防护、超量账的分批清理、实际定时保留策略与运维任务、推送许可与发送并发、隐私托管更新、正式签名真机验证。当前保守上限和墓碑到期字段详见 dateplan/README，不能声称这些已自动运行。

## 7. 用户双端通过回执（2026-10-04）

用户明确回报“双端测试完全跑通了，都通过”。据此将上述隔离测试流程登记为用户执行通过，解除下一批正式客户端基础开发前置。VERSION_CONFLICT 的旧版本保护属于预期拒绝，不当成操作已经成功。

证据边界：本回执不是 AI 代跑；全部原始回包和最终 CloudDB 行截图尚未归档。公钥和密文仍为公开测试夹具，不能证明正式设备 HUKS 密钥、真实计划解密、旧配对安全升级或系统通知投递；错误项目和真实撤销令牌的专项矩阵也不因本声明自动关闭。

下一批本地持久化与计算投影已完成，见 [本地基础验收](2026-10-04-shared-plan-local-projection.md)。本批不需要重新部署 dateplan/clouddb，不操作或破坏现有配对。
