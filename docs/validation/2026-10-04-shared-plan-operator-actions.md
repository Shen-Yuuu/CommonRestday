# 共同计划与计划通知：用户操作步骤

日期：2026-10-04。代码、离线与编译已完成，不代表云端已部署或手机已收到通知。
本清单只需要你操作账号、部署和设备；没有让你清空珍贵数据的步骤。破坏性测试仅用可丢弃实例。

## 先认清三个 ID（本机配置核对结果）

| 用途 | 应用 ID | 项目 ID |
|---|---|---|
| 正式主 App，包名 `com.common.fortwo` | `6917617383543050045` | `101653523865149102` |
| ForTwoCloud 的“两人份云”应用 | `6917617526333646177` | `101653523865149102` |
| CloudDevSpikeOfficial 的“云测试” | `6917617474592896110` | `101653523865155672` |

主 App 的 `AppScope/resources/rawfile/agconnect-services.json` 和 ForTwoCloud 目前同项目。
**接正式 App 时用 ForTwoCloud，不要把主 App 改成测试项目，也不要搬运测试连接或匿名身份。**
CloudDevSpikeOfficial 仍可验证隔离协议，但那里的通过记录不能代替正式项目验收。
若你后续主动改了 AGC 关联，上表须重新核对，不能照抄旧 ID。

## 1. 更新正式云数据库定义

1. 在 DevEco 打开 `E:/desktop/Code/harmony/FortwoCloud/Application`。刷新 CloudDev/CloudProgram 节点，确认关联项目为“两人份”。
2. 部署源码已同步到 `CloudProgram/clouddb/objecttype`，新增/更新五个对象：
   `PairMemberBinding`、`PairDatePlan`、`PairPlanRequest`、`PairPlanOutbox`、`PairPushTarget`。
3. 右键 `clouddb` → Deploy Cloud DB（以你安装版本的同义菜单为准）。
4. 若原来已有五个模型，重点核对 `PairMemberBinding` **增量增加** `creatorLink`、`recipientLink`：Text，默认空，权限保持仅 Administrator。
   新模型也不能给 World、Authenticated、Creator 开读写权限，客户端只调用云对象。
5. 不删除原 `PairSession` / `PairSnapshot`，不改 `db-config.json` 的原默认区来绕过问题。
   如果部署要求删区、清表或重建，停止，给我看提示。
6. 在正式项目的 AGC「云数据库」中确认/建立独立的 `FortwoPlans` 存储区，中国大陆数据处理位置；
   确认五个对象在该区可由服务器使用。保留旧班表区 `FortwoPair`。
   区名只用英文字母和数字，不加中划线。若你已有专用区，用它的准确名称，不再新建。

成功判据：五个对象已发布，新增字段存在，权限没有放宽，原班表数据仍在，专用区名记录明确。

## 2. 开通认证并部署 dateplan

1. AGC → 开发与服务 → “两人份” → 认证服务 → 认证方式，启用匿名认证。
   **不需要华为账号登录页，也不是拿本机设备 UID 当认证身份。**
2. 在 DevEco 的 ForTwoCloud 中右键 `CloudProgram/cloudfunctions/dateplan` → Deploy。
   源码和五个模型已与仓库同源；部署整个目录，不只复制入口文件。
3. 在正式项目的 `dateplan` 配置里设置：

   | 环境变量 | 值 |
   |---|---|
   | `FORTWO_AUTH_PROJECT_ID` | `101653523865149102`，不是任一 appId |
   | `FORTWO_SHARED_PLAN_ZONE` | 第 1 步的准确区名，如 `FortwoPlans` |
   | `FORTWO_ENABLE_SHARED_PLAN_V1` | `true` |
   | `FORTWO_ENABLE_PLAN_PUSH` | 通知配置完成前 `false`，完成后 `true` |

4. 保留/核对 Server SDK 的本项目服务器凭据（现有 CloudDev 通道可能自动提供）。
   `agconnect-services.json` 是客户端配置，**不是** Server SDK 的 API 客户端凭据，也不是 Push 私钥。
5. 部署后核对超时、环境变量、触发器和版本。如果原批准超时是 20 秒，确认没有被部署重置为 60 秒。
   `dateplan` 保留原系统签名的客户端网关鉴权；不为了排错关闭鉴权。

成功判据：正式 `dateplan` 存在，认证/区/项目匹配，不再返回 FEATURE_DISABLED、CONFIG_MISSING 或签名拒绝。

## 3. 开通 Push 与获取服务账号密钥

1. 对 **主 App“两人份”（`com.common.fortwo`）** 开通 Push Kit，申请/确认 **工作事项提醒 WORK** 权益。
   计划邀请/确认是日程状态通知，不冒充即时聊天。不要申请后台消息来替代锁屏通知。
2. 在华为开发者联盟的 **API Console** 选择同一个正式项目，启用推送服务 API，创建并下载“服务账号密钥”。
   文件应包含 `project_id`、`key_id`、`private_key`、`sub_account`。核对 `project_id=101653523865149102`。
   操作参考[华为官方服务账号 JWT 指南](https://developer.huawei.com/consumer/cn/doc/harmonyos-guides/push-jwt-token)。
3. 完整 JSON 能保存时，使用 `FORTWO_PUSH_SERVICE_ACCOUNT`。用户确认精简后仍超限，2026-10-10 已新增分段配置：
   `FORTWO_PUSH_SERVICE_ACCOUNT_PARTS=N` 和 `_1` 至 `_N`，每段最多 512 字符，不能与非空旧单变量混填。
   使用本地工具生成，不手动删私钥内容或换行。详细操作见 [分段配置与 worker 部署](2026-10-10-push-worker-setup.md)。
4. 设置 `FORTWO_ENABLE_PLAN_PUSH=true`，发布该配置。
5. **私钥、Server SDK API 凭据和 scheduler 密钥都不发给我、不贴聊天、不放仓库、不放 AppScope 或 HAP。**
   Push 服务账号和 AGC Server SDK 项目凭据是两套不同用途的凭据。

当前实现使用鸿蒙 Push v3、PS256 JWT、WORK 通知，直接由服务器发出；不是旧 Android OAuth2 流程。
端侧没有新增定位、通讯录或相册权限；通知授权在用户点“开启计划通知”时由系统询问。
签名应用标识必须对应主 App；若 AGC 开通能力后要求更新 Profile，按控制台提示重新生成对应开发/发布 Profile，
不随意更换开发者证书、不改包名、不把测试包的 Profile 拿给正式包。

## 4. 部署通知补送 worker（独立传统云函数，不是新云对象）

代码和部署 ZIP 已准备：`E:/desktop/Code/harmony/.crdtest/dateplanpush.zip`。
重建命令：在主仓库运行 `node tools/build-dateplan-push-worker.mjs`。包中包含编译代码及 Server SDK 依赖，没有业务凭据。

1. AGC 正式项目 → 云开发（Serverless）→ 云函数 → 创建函数，名称可用 `dateplanpush`。
2. 选**事件调用**，Node.js 20.x 或平台提供的兼容运行时，上传上述 ZIP，入口填 **`dispatch.handler`**。
   ZIP 根部直接有 `dispatch.js`、`push.js`、`models.js`、`node_modules`，不能多包一层目录。
3. 环境变量填写与 `dateplan` 相同的五项（认证项目、专用区、共同计划开关、Push 开关、Push 服务账号）。
4. Server SDK 使用平台注入的项目凭据。**2026-10-10 纠正：`PROJECT_CREDENTIAL` 是系统保留变量，不能手动新增。**
   SDK 支持读取它，不等于控制台允许创建它；若未注入，暂停 worker，需适配平台允许的凭据提供方式。
   不要拿 Push 服务账号 JSON 或 App 的 agconnect-services 代替，也不要把凭据塞进部署 ZIP。
5. 另生成一个仅服务器知道的随机密钥（32–128 个英文字母/数字/`_`/`-`），配置 `FORTWO_PLAN_DISPATCH_SECRET`。
   在该函数控制台测试时输入 `{"dispatchSecret":"你的密钥"}`。没有正确密钥返回 DISPATCH_REJECTED 且不发请求。
6. 创建 **定时/CRON 触发器**，先采用每 5 分钟执行一次，输入上述仅服务器知道的 JSON；
   支持包装在 `data` / `userData` 中，也支持 JSON 字符串包装。
   **如果控制台没有传入数据的选项或事件格式不同，不要猜、不删鉴权、不公开 HTTP 入口；发无密钥截图给我核对。**
   平台触发格式与权限是账号侧验收，不由本机测试替代。
7. 不给此 worker 添加客户端 HTTP/API 网关触发器。仅 cron 和授权管理员控制台测试能调用。
8. 函数超时先设 20 秒（每趟最多两条、每条外部请求最多 5 秒）；超时实测失败应核实原因，不能仅提高超时掩盖失败。
9. 查看函数日志的 `FORTWO_PLAN_PUSH` 摘要，并在云数据库核对事件状态。

投递规则：新操作先即时尝试一条；失败由已部署 cron 再处理，每事件最多三次，只在创建后一小时内尝试。
`SENT` = 华为平台接受，不是手机收到；`FAILED` / `SKIPPED` 不回滚计划。
系统使用稳定通知 ID 和消息 ID 降低重复，仍不承诺恰好一次。撤销时已进入网络的请求不能撤回，
已被 Push 平台接受的旧消息也可能在离线缓存一小时内出现；点击必须重新核实，不执行旧邀请。
即使不开 worker，即时发送仍能测试，但不能把失败补送判通过。

回退时先关闭两端云函数的 `FORTWO_ENABLE_PLAN_PUSH` 并暂停 cron，再关闭客户端的新开关。
只关闭客户端 UI 不等于已经停止云端待发通知；关闭共同计划服务器总开关也会影响清理授权，应先完成原连接清理。

注意费用：5 分钟 cron 一天有 288 次调用，并非免费承诺。上线前在 AGC 复核套餐、项目级配额和告警；
测试结束后没有启用通知的需要就暂停 cron。用户端不恢复“明天自动重试”，也不后台轮询。

## 5. 同步托管隐私政策并出联调包

1. 使用仓库 `docs/legal/privacy-policy.md` 的 **v1.2 待发布稿**更新你已建立的 AGC 托管协议。
   重点是匿名认证、共同计划密文、Push Token、通知权限、保存与删除边界；填真实主体、联系方式与生效日期。
   仓库随包全文、MD、HTML已同源，但**在线协议没有被我更新**。
2. 预览/发布后，打开原托管 URL 确认内容已更新。不新加首启隐私弹窗。
3. 仅供联调时，将 `feature/src/main/ets/config/FeatureFlags.ets` 的 `securePairing` 和 `sharedPlan` 两个值改为 `true`。
   `cloudPairing` 保持当前 `true`。源码默认仍关闭；“代码完成”不是发布开闸许可。
   你也可以完成部署后告诉我，由我改这两行并重跑门禁。
4. 两台设备安装同一份签名的最新主 App 测试包。**覆盖安装，不卸载、不清数据**。
   新 API 26 可丢弃模拟器能验证 UI/协议；锁屏和应用关闭通知最终需要真实鸿蒙手机。
5. 主 App 和云端项目配置/签名必须匹配。代码没有引入必须通过华为账号登录才能使用的门槛。

## 6. 双端从现有班表配对走正式流程

设 A 为邀请方，B 为接收方。不要在隔离测试页“改期夹具”里验正式页面。

1. 确认主 App A/B 班表短码配对成功，修改一条日程能同步，双方是同一对伴侣。
2. 两端打开「我的 → 伴侣与同步 → 共同计划连接」。如果出现旧“测试连接”，只解除该共同计划连接，**保留班表配对**。
   旧测试连接缺少新密文对应证明，不自动接管，也不搬测试项目的连接。
3. A 点生成短码；B 输入这里的新短码并申请加入；A 检查连接、核对 B 后确认；B 检查连接。
   两端显示“共同计划连接已确认”。这是一次性的安全通道初始化，不用 QR 或链接。
4. 双方在「共同 → 计划」点“开启计划通知”，各自同意系统授权。拒绝一侧也应能使用计划页。
5. A 选未来空闲时间创建计划：按钮应为“发送计划邀请”，保存后是待对方确认。
   A/B 的计划 tab 出现玫红圆点；B 刷新可见“待我确认”；**双方今天/周历/共同空闲不应提前占用**。
6. B 同意，A 回前台或刷新：两端变已确认，只产生一条活动计划，共同空闲扣掉同一时间；圆点清除。
7. A 申请改期：新时间待确认，旧确认时间仍占用。B 暂不安排 → 保留旧时间；重发新改期后 B 同意 → 只切换到新时间。
8. A 撤回未确认邀请、任一方取消确认计划：终态同步；取消后空闲恢复。系统日历导出各自选择，不因一方授权强制另一方授权。
9. 断网发送/同意后恢复网络：用“核实 / 重试”查询原回执并按原请求继续，不重复建计划。
   如果原操作已提交后日程又产生冲突，不能误报未提交并重建；已有确认按冲突事实展示。
10. 检查“大字体、浅色/深色切换、滚动、新列表和弹窗高度”，本机编译不能替你判断观感。

## 7. 通知真机矩阵（需两台真实设备，或至少分别替换模拟器补证）

每格使用一条新计划，避免通知去重/折叠误判。开启手机“允许通知”、锁屏通知和横幅；记录免打扰状态。

| B 的状态 | A 的操作 | 期望 |
|---|---|---|
| 前台 | 发邀请 | 系统通知，计划页刷新后待我确认 |
| 后台 | 发邀请 | 通知栏提示，点开到共同·计划 |
| 正常划走/应用未打开 | 发邀请 | 系统通知；打开后才拉取和投影 |
| 锁屏 | 发邀请 | 通用提醒，不包含标题/时间/姓名 |
| A 锁屏 | B 同意 | A 收到确认提醒，打开后确认状态 |
| 拒绝通知授权 | 发邀请 | 不强制弹权限；手动查看仍正常 |
| 旧邀请已撤回/改期 | 点旧通知 | 只导航并拉最新状态，不替用户同意 |
| 暂停 Push 开关/网络异常 | 发邀请 | 计划提交不受影响，事件留下或按规则结束 |

“设置中强制停止”是不同状态，不拿它来要求推送必达；通知受网络、签名、权益、系统电源策略和免打扰影响。
失败反馈请给：设备状态、操作、是否有 `PairPlanOutbox` 行及其状态、脱敏错误码；不要给 token/私钥/计划明文。

## 8. 只在可丢弃设备做的生命周期验收

先记录两个实例身份和数据可丢弃，别按端口号认设备。

- 云端拒绝解除时本机凭据不丢；成功后计划、请求、通知目标、事件删除，撤销绑定留下最小 tombstone。
- “清空全部”保留准确的原身份补删队列，恢复网络后补删；已删除本机没有重试句柄的系统日历如实提示手工检查。
- CREATE 回包丢失后清空不会重新生成邀请；未知 JOIN 或原匿名身份丢失不谎报删除，需开发者核实。
- 卸载/恢复备份后的 HUKS 别名、日历句柄和新连接隔离；第三台不能读、同意或删该对的计划。
- 关闭新开关后不发共同计划或 Push 请求，已有缓存可读；原有授权凭据的清理入口仍有专用路径。

## 9. 发布前不能跳过

目前仍有每连接 50 个计划、200 个业务请求、400 个通知事件的安全上限；没有无限历史归档/自动到期物理删除。
到限不会吞数据，返回 BACKLOG_FULL。公开运营前必须安排容量、历史归档和有审计的清理流程，不能靠手工删活动计划/回执解除限制。
未知加入补删和身份丢失交给开发者核实，不授权删除该账号的所有连接。
保留的绑定 tombstone 用于阻止旧请求重建，不随意删行；政策中的三十天是运维标记，未部署自动清理任务。
这些是公开发布的门槛，不是本轮小范围联调必须清空的数据。

还需：正式签名 release 包、备案/商店材料、两台真机、通知权益、云成本告警、真实客服联系方式、托管政策更新。
上述外部步骤没有由本机离线/编译代跑。

参考：[AGC 创建函数](https://developer.huawei.com/consumer/cn/doc/AppGallery-connect-Guides/harmony-api6-create-and-config-func-0000001665128304)、
[Node.js 回调入口](https://developer.huawei.com/consumer/cn/doc/AppGallery-connect-Guides/develop-func-nodejs-0000001713076049)、
[定时触发器](https://developer.huawei.com/consumer/cn/doc/appgallery-connect-Guides/agc-cloud-function-call-via-crontrigger-0000001563388769)、
[Push Kit](https://developer.huawei.com/consumer/cn/hms/huawei-pushkit/)。菜单随控制台版本变化，以你看到的正式项目界面为准。
