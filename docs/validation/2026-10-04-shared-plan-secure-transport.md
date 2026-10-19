# 共同计划第四批：可信身份与持久密文传输

日期：2026-10-04。范围：主应用真实 Auth 提供器、独立 HUKS 计划密钥、dateplan 加密 Gateway 与持久密文重试。正式安全配对 UI、共同计划卡和 Push 不属于本批完成项。

## 1. 已落地的逻辑

- 安装 `@hw-agconnect/auth` 1.1.0。应用启动只登记上下文，不初始化匿名登录；只有显式创建身份的调用才允许匿名注册。已有安全会话取凭据时不悄悄补建身份，不替换非匿名用户，不登出、不删除用户。
- 使用真实 SDK 的 `getToken(true)` 刷新，并在取令牌后、能力核验后和云结果返回后检查身份是否仍一致。令牌不存入业务表，也不打印到诊断日志。
- 安全成员来自 dateplan 的已认证 ACTIVE 回包，并核验双方成员、协议与投影语义。旧配对的 Preferences UID 不作为可信成员；不同身份、不同代次、未知能力、缺密钥均阻止请求或丢弃回包。
- 计划使用独立 `ft-plan-id-*`／`ft-plan-pair-*` HUKS 别名，槽位经 SHA-256 派生；不复用、不删除旧 `crd-*` 班表密钥。只导出公开点，计划正文由 HUKS AES-GCM 加解密。
- 空认证 UID 不得生成身份别名；加密 finish 失败时 abort 会话并返回固定错误，不泄露 SDK 错误正文。共享 GCM 机械过程因此也补齐了旧快照加密的失败释放，不改变密钥、AAD 或正常密文格式。
- 计划密文 AAD 绑定 pairId、planId、contentRevision 和协议版本，不能绑定会随着同意动作改变的 stateVersion。改期待确认同时读取旧已确认修订和新提案修订，不把旧约抹掉。
- 新增 `shared_plan_wire`，数据库从 v5 增量升至 v6。先保存原草稿，再生成并保存首份密文，最后发云请求。相同 requestId 手动重试沿用同一密文（含 nonce）、动作和期望版本，不重新加密。
- 存储竞争时第一份密文获胜；不同草稿、过期会话不能覆盖。完成请求时草稿账与密文账在同一事务清理；失败整体回滚。清库、恢复和会话代次变更清理对应账，旧个人计划及历史日历句柄遵循原有规则。
- PROPOSE／AMEND 才带正文密文；同意、拒绝、撤回、取消不夹带正文。坏信封、解密失败、错误成员或不合法状态使整批读取失败，不返回部分可投影列表。
- 服务端真实终局码 `REQUEST_REUSED`／`BAD_ENVELOPE`／`VERSION_LIMIT`／`INVITE_EXPIRED` 已接入请求收口；不确定结果保留原请求，不能用新编号假装重试。
- `FeatureFlags.sharedPlan=false` 有实际 Gateway 读者。关闭态直接拒绝，不取认证、不发共同计划云请求；真实适配器的构造本身没有副作用。

本批补齐了传输端口，而非完整产品入口。现在页面仍没有“发送共同邀请／待我确认／玫红圆点”的正式闭环；现有配对和班表同步未自动迁移。

## 2. 主要文件

| 范围 | 文件 |
| --- | --- |
| Auth／独立 RPC | `cloud/src/main/ets/api/AnonymousIdentity.ets`、`DatePlanCloudApi.ets`；`EntryAbility` 只 attach |
| 独立 HUKS 密钥和信封 | `PairKeyStore.ets`、`SecurePlanKeyStore.ets` |
| 成员、密文与代次验证 | `feature/src/main/ets/usecase/SecureSharedPlanGateway.ets`、`SecurePlanAdapters.ets` |
| 持久发送与终局收口 | `SharedPlanUseCase.ets`、`data/src/main/ets/repo/SharedPlanRepo.ets` |
| v6 增量表／恢复 | `SharedPlanSchema.ets`、`MigrationRunner.ets`、`ScheduleRepo.ets` |
| 回归 | `shared-plan-secure-regression.cjs`、`shared-plan-storage-regression.cjs`、`SharedPlanUseCaseTest.ets`；加入 `tools/test/run.mjs` |

现有 WIP 未提交、未清理；没有操作模拟器、部署云端、读取签名私钥或让用户重新配对。

## 3. 验证过程和边界

新增反例先红：缺少 wire 存储方法、能力核验期间身份改变未被拒绝。实现对应存储及核验后通过。补测改期曾因测试夹具使用不存在的 `AMEND_PENDING` 状态而失败，核对服务端及本地规则后更正为 `ACCEPTED` 加 pending 修订；没有改生产状态机来迁就测试。

第一次 ArkTS 出包暴露结构类型赋值错误，调整为共享会话接口和显式 RDB 映射。后续一轮虽然编译成功，但 WARN 322 超过原 289 门禁，仍判失败；补齐计划行读取的异常／finally 关闭边界、摘要 API 异常边界并复用公钥参数后复跑。未修改供应商 SDK，也未放宽或修改 `tools/verify-baseline.json`。

最终补验还发现空 UID 可派生身份别名，以及加密 finish 失败未释放会话；反例先失败，再补输入验证和 abort 后通过。补 abort 时曾把新 `finishSession` 的结果误标成旧 `HuksResult`，本机编译拒绝；改为按实际结果读取 `Uint8Array` 后重新跑三档，不用断言强行兼容旧类型。

Auth 正常联网安装曾因 TLS 连接重置失败；之后使用本机隔离项目已安装的同版本依赖及精确 lock/integrity 信息，通过 `ohpm install --metadata_cache --retry_times 0` 安装成功。没有关闭证书校验；未输出实际 AGC 配置或凭据。

API 签名以本机 API 26 声明及 Auth 1.1.0 实际 `.d.ets`／README 为准，官方资料仅辅助核对：[HUKS 公钥导出](https://developer.huawei.com/consumer/en/doc/harmonyos-guides-V13/huks-export-key-arkts-V13)、[AGC 鸿蒙匿名认证](https://developer.huawei.com/consumer/cn/doc/appgallery-connect-Guides/agc-auth-harmonyos-anonymous-0000001151370310)。未以其他平台或旧版本示例替代本机方法签名。

最终执行 `node tools/verify.mjs --steps=offline,debug,release,ohostest,perf`，exit 0，`verify: ALL PASS`。

| 检查 | 最终结果 |
| --- | --- |
| offline 云关／云开 | 两档各 typecheck 0 errors、331 passed / 0 failed；runner 中专项脚本也都 exit 0 |
| 密文通道专项 | `shared-plan-secure-regression.cjs` 19 passed / 0 failed；此数单列，不混入 331 条 Hypium |
| 存储 SQL／RDB 适配器 | PASS；含 v4／v5→v6 回滚、旧计划／循环保留、恢复清账、首份密文获胜、草稿变更拒绝、清理失败整笔回滚 |
| debug | BUILD SUCCESSFUL，ArkTS:WARN 277，原门禁 289 |
| release | BUILD SUCCESSFUL，ArkTS:WARN 275，原门禁 289 |
| ohosTest | BUILD SUCCESSFUL，ArkTS:WARN 257，原门禁 269；只编译，未执行设备用例 |
| dateplan 后端离线回归 | ES2020／ES5 两档各 36 passed / 0 failed；真实 Server SDK strict/noEmit PASS；本批未改或部署后端 |
| 开发机 perf | exit 0；paired 120 天 P50 14.1ms；列表投影 P95 0.109ms／0.900ms，在预算内 |
| 格式检查 | `git diff --check` exit 0；工作树未提交、未清理 |

日志：`E:/desktop/Code/harmony/.crdtest/verify-offline-closed.log`、`verify-offline-open.log`、`verify-debug.log`、`verify-release.log`、`verify-ohostest.log`；perf 数字来自最终命令回执。日志会被下次同名验证覆盖，本文件记录本次结果。Auth 依赖仍带供应商声明告警；WARN 下降不表示整个仓库零技术债，未人为改写门禁上限。

离线密码学使用 Node 真 P-256 ECDH／AES-GCM 和生产 ArkTS 控制逻辑，但 HUKS／Auth／RPC 是测试适配器。它证明密文往返、AAD、修订与控制流程，不证明实际设备 HUKS 公钥形态、真实 Auth 刷新或网络投递。SQL 使用独立 Node SQLite，不打开应用数据库。

## 4. 下一批必须接通的部分

1. **显式安全配对入口和恢复**：双方明确参与新 dateplan 安全会话；真实匿名身份、公钥交换、创建／加入／确认及失败重试。确认凭据不能明文落业务表；不能仅凭旧 pairId／uid 自动认领旧会话。保留现有班表，不在用户不知情时解绑。独立测试 App 的会话不会自动变成主 App 的会话。
2. **真实日程冲突端口及生命周期**：发送／同意／改期重读本机日程，只排除该条旧共同活动；旧个人班次不能被误排除。新安全会话解除、清库、恢复与新密钥／成员必须统一收口，不沿用旧裸 UID 补删授权。
3. **正式计划 UI**：发送邀请、待确认／已确认／历史卡、红点和手动重试；云端未确认不得作为本地已确认计划。首页、今日安排、周历及共同空闲补端到端反例。
4. **独立 Push**：真实目标登记、服务端发送、事件去重、通知权限与冷启动点击白名单。当前通知事件账 PENDING 不是已送达，也没有锁屏通知。
5. **隐私与发布**：启用身份／通知功能前同步更新随包及 AGC 托管政策，确认正式主应用的认证配置、项目和签名；完成真实双端、真机与权限矩阵后才开新功能。

本批不关闭主实施计划 Task 1–5，不把独立双端服务测试扩大为正式主应用验收。

## 5. 用户现在需要操作吗

本批不需要新部署、换签名、卸载、清数据或重配。先保留当前配对和隔离测试环境，等正式入口交付再按具体脚本联调。覆盖安装时核对旧班表、循环模板、个人计划仍在；数据库若报错保留日志，不以清数据绕过升级问题。
