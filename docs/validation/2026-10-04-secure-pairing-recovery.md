# 第五批：正式客户端安全配对与恢复回执

日期：2026-10-04。范围：接第四批可信密文通道，新增可持久恢复的安全连接流程及关闭态测试入口。不是共同计划／锁屏推送已完整交付，也不是重新验收用户之前运行的独立测试 App。

## 1. 本批实现

- 生成六位短码 → 对方申请加入 → 邀请方明确确认 → 双方分别手动检查并协商 HUKS 密钥 → 本机装配安全计划会话。WAITING／PENDING_CONFIRM 不激活，加入方不能代替邀请方确认。连接 ACTIVE 不等于计划已确认，更不等于通知已送达。
- 创建／加入在云调用前持久保存原请求、认证 UID、设备公钥及旧配对锚点。重建客户端对象后仍使用同一创建编号／加入短码；恢复仅读现有匿名身份和身份密钥，不能暗中换一个 UID 或公钥。
- 邀请方确认凭据采用独立 `ft-plan-proof-*` HUKS AES-GCM 别名，AAD 同时绑定认证 UID 与 flowId；表中只有密封信封。确认必须显式点击，不把短码当确认凭据。
- 加入已提交但回包丢失，邀请方随后确认并清空短码的恢复缺口已修：新增 `recipientJoinDigest`，只允许原认证加入方、原设备公钥和原短码恢复。摘要不返回客户端；重复匹配拒绝而非任取一行，解绑清摘要。
- 数据库 v6→v7 增 `shared_pairing_setup`。操作意图与 ACTIVE 会话同事务落地；CAS、防晚到回包、重复激活、解绑事务失败回滚、不覆盖另一条安全连接均有生产 SQL 回归。迁移及恢复清理沿用现有事务入口，不重写旧表。
- 新连接块位于“我的 → 伴侣与同步”，沿用现有配色，仅开发开关开放时可建立连接；关闭后若已有进度，仍保留本机只读与手动解除入口。打开面板只读本机，不登录、不查询云；没有轮询／次日自动重试。
- 单独解除连接：云端失败保留全部进度；只有明确撤销后才清本机安全会话并作废相应共同活动，系统日历句柄仍留为 CLEANUP_PENDING。本机密钥丢失不阻止原认证 UID 发起云清理；认证身份丢失仍不伪造成功。

保持 `FeatureFlags.securePairing=false`、`sharedPlan=false`；旧 cloudPairing 档位及班表配对不变。无旧 pairId／裸 UID 认领、无自动解绑、无 CRD1 版本变化、无华为账号登录 UI。

## 2. 验证过程

服务端先加加入回包丢失反例，得到 CODE_EXPIRED 而非预期 OK；增量摘要与重读成员校验后通过。另加摘要重复匹配拒绝测试，避免引入任意挑会话的旁路。

客户端编排先加测试，初跑因实现文件尚不存在退出 1；实现后逐项通过。这里单列该先红的性质，不将文件缺失称为“已经复现业务漏洞”。真实 Node P-256／AES-GCM 专项追加密封证明跨 UID／flow、篡改、缺密钥不再生和删除后不可读；真实 SQLite 专项追加 v6→v7 回滚、CAS 激活／撤销及其他会话保护。

第一次完整出包失败：离线 TypeScript 没拦住 ArkTS 构造器字段声明及结构类型赋值限制。改成显式字段赋值和适配器映射；RDB 读结果用异常边界及 finally 释放。未改供应商声明、未放宽 WARN 上限。追加关闭态保留查看／清理与页面晚到回执保护后，最终门禁结果登记在下节。

这些测试不操作模拟器、真实 AGC 数据或应用数据库；ohosTest 只编译。HUKS 实际导出形态、Auth 网络刷新及进程重建设备效果仍须实测。API 签名以本机 SDK 与已安装 Auth 1.1.0 声明为准，不把浏览资料或测试适配器当设备证据。

## 3. 最终机器门禁

最终执行 `node tools/verify.mjs --steps=offline,debug,release,ohostest,perf`，exit 0，`verify: ALL PASS`。追加关闭态界面保护后重跑三档，以下为该最终命令结果，不引用上一批数字冒充本批验证。

| 检查 | 本批最终结果 |
| --- | --- |
| offline 云关／云开 | 两档各 typecheck 0 errors、331 passed / 0 failed；专项脚本均 exit 0 |
| 新客户端编排专项 | 18 passed / 0 failed，单列，不混入 331 条 Hypium |
| 真实 Node 密码学专项 | 20 passed / 0 failed；Node 适配器，不是实际 HUKS 设备证据 |
| 生产 SQL／RDB 专项 | PASS；v4／v5／v6→v7、恢复清理、操作意图 CAS、原子激活／撤销、回滚与其他会话保护 |
| debug | BUILD SUCCESSFUL，ArkTS:WARN 277，原门禁 289 |
| release | BUILD SUCCESSFUL，ArkTS:WARN 275，原门禁 289 |
| ohosTest | BUILD SUCCESSFUL，ArkTS:WARN 257，原门禁 269；仅编译，没有设备执行 |
| dateplan 离线契约 | ES2020／ES5 各 38 passed / 0 failed；实际 Server SDK strict/noEmit 和模型／管理员权限一致性 PASS |
| 开发机 perf | exit 0；paired 120 天 P50 14.3ms，列表 61／1000 行 P95 0.105／0.900ms，在原预算内 |
| 格式／源码同步 | git diff --check exit 0；隔离工程 service／models.js／models.d.ts／PairMemberBinding.json 与仓库副本 SHA256 一致 |

WARN 基线未修改。构建日志：`E:/desktop/Code/harmony/.crdtest/verify-{debug,release,ohostest}.log`；两档离线日志同目录 `verify-offline-{closed,open}.log`。日志下次运行可能覆盖，以上为本次最终回执。所有 WIP 保留，未提交 Git。

## 4. 已准备的部署增量（用户操作，不自动部署）

源文件已同步到 `E:/desktop/Code/harmony/CloudDevSpikeOfficial/CloudProgram`：

1. `clouddb/objecttype/PairMemberBinding.json`：只新增 `recipientJoinDigest:String`、默认空、管理员专用，其他四模型不变。
2. `cloudfunctions/dateplan/service.ts`、`models.js`、`models.d.ts`、`README.md`：加入摘要保存、恢复与撤销清理。模型、反射和方法声明需要一起更新，不能只复制 service。

当前已部署的初版服务没有被本轮修改；正式 FortwoCloud 未写入新对象。主 App 新开关关闭，现有用户暂时不会调用该新增路径。

若你希望先部署隔离服务增量，步骤如下；也可以等下一批正式 UI／生命周期完成再联调，当前不需要卸载、清数据或重新配对。

1. 在 DevEco 打开 **CloudDevSpikeOfficial/Application**，刷新 CloudProgram。继续使用隔离测试应用／项目，别切成正式“两人份”，别复制测试项目的凭据到正式项目。
2. 右键 `CloudProgram/clouddb` → **Deploy Cloud DB**。在确认界面检查 PairMemberBinding 是新增一个字段、默认空且保留原权限；区名继续使用现有配置。若提示清表、删区或重建，停止并提供提示，不接受破坏性迁移。
3. 模型部署成功后，右键 `CloudProgram/cloudfunctions/dateplan` → **Deploy 'dateplan'**，部署整个目录。无需部署 pairing、snapshot 或重建其他四个模型。
4. 在 AGC 复核 `FORTWO_AUTH_PROJECT_ID` 仍为已验证的隔离项目 ID（非 appId）、`FORTWO_SHARED_PLAN_ZONE` 仍为 FortwoPlanProbe、`FORTWO_ENABLE_SHARED_PLAN_V1=true`。复核超时与部署前一致；原先若是 20 秒，恢复 20 秒，不把部署重置的 60 秒当新口径。
5. 保留当前测试实例的安装与数据。源码一致性／离线通过不证明已部署成功；不要因为主 App 暂无测试入口而自行把两个开关都打开。

后续正式联调需将主 App 匿名认证和 dateplan 固定鉴权项目对齐，并验证正式签名／项目配置。不能把测试 App 的安全连接搬进正式 App，也不能把旧班表会话当成已验证的新安全连接。

## 5. 下一批的真实欠账

优先顺序：真实日程冲突端口及完整删除生命周期 → 旧班表连接与新安全连接的可信对应 → 正式计划 UI（邀请／同意／改期／红点／手动重试）→ Push → 隐私／真机／发布。

- “清空我的全部数据”目前会删除本批本地表，但还没有对新认证云连接落可靠的补删账；这不等于新云数据已经删除。不能直接启用发布。
- 原认证身份丢失、仅有无 pairId 的未知请求且服务端已过期等终止恢复场景，尚需可审计的清理／终局查询机制。本批保留进度，不借“过期”理由谎称云行已清。
- 本地残留未使用密钥别名的清扫与账号处置尚需完整生命周期；成功解绑后的密钥删除是尽力清理，不承诺设备故障时别名一定消失。
- 现有班表伙伴与新认证成员没有自动可信映射。测试入口单独连接只证明新通道，本批不能将它用于生产共同时间与计划共确。
- 发送／同意／改期重读本机日程，只排除该条旧共同活动；这部分真实端口尚未接入。
- 没有正式计划邀请卡／未确认红点，没有 Push 发送器、通知许可／token 联调或锁屏／未打开通知。本批不扩大既有双端服务测试的结论。
- 开启匿名认证、计划通知前补齐 SDK／身份／推送披露，随包三处与 AGC 托管全文一致；完成真实设备矩阵后才允许放开新功能。

设备验收待办：覆盖升级旧数据保留、进程退出后的创建／加入恢复、实际 HUKS 确认密封、双端 ACTIVE、不成功时保留凭据、切回关闭档仍可读／清理、系统日历遗留句柄。以上均未由本批操作或勾选。
