# 共同计划隔离前置验证

准备于 2026-10-04；**不是正式共同计划功能**。用户随后回报已部署并完成身份／错误令牌／事务三个按钮，测试完全通过，记为用户执行回执；AI 未代跑，原始回包尚未归档。

下一批新增独立 dateplan 和安全共同计划测试页，见 `docs/validation/2026-10-04-secure-dateplan-acceptance.md`。不要重新部署已通过的探针来覆盖它的环境变量。本文后面的“已准备、未部署”是第一批交付时的历史状态，新业务绑定／跨表提交仍需新验收。

## 当前有的内容

`cloudfunctions/sharedplanpreflight` 提供 `verifyIdentity(accessToken)`：调用 Server SDK 的签名／撤销验证后，检查固定项目、主体和有效期。成功只返回 16 位主体指纹，`sharedPlanReady` 永远为 false。不会查配对、写 CloudDB、注册 Push token、派发通知或触碰 HUKS。

函数参数必须是 AGC 认证服务签发的访问令牌；不是设备 uid、配对码、Push token 或 clouddevelopproxy.debugToken。没有客户端认证测试入口的当前正式应用不能直接执行此探针。

`runRace(accessToken)` 在认证通过且服务端 `FORTWO_ENABLE_CAS_PROBE=true` 时，向 **FortwoPlanProbe / PlanCasProbe** 插入一条随机主键的测试行，再同时执行两个 SDK 事务。探针用有界读屏障确保两个请求都读到 version=1，验证只能一方提交 version=2。屏障只是测试仪器，不是生产锁；普通 query＋upsert 即使最终只剩一行也会被判失败。SDK 异常或没有观察到重叠读取只判未确认，不假算竞争失败方。

每次测试留一条非业务测试行，便于控制台核对。测试完成后关闭 `FORTWO_ENABLE_CAS_PROBE`，并由用户清理隔离测试行／探针服务。不操作生产表和任何已有配对。

## 已接入已有隔离工程

2026-10-04 已将探针源码放入 `E:/desktop/Code/harmony/CloudDevSpikeOfficial/CloudProgram/cloudfunctions/sharedplanpreflight`，其依赖已安装（Server SDK 1.0.5）；新对象定义放入该工程 `clouddb/objecttype/PlanCasProbe.json`。**没有改已有 db-config 的默认存储区，也没有部署。**

测试客户端加入该工程 `Application/entry/src/main/ets/pages/SharedPlanPreflightPanel.ets`，首页增加“共同计划前置验证”独立入口。复用已有匿名认证初始化和已安装的客户端 Auth SDK **1.1.0**，不改认证配置、不重新登录已有非匿名账号。

客户端用 `(await user.getToken(true)).getString()` 取得认证令牌，仅用于 HTTPS 云对象参数，不保存、不显示、不记录日志。只显示经过挑选的回包字段；旧云函数／直连拒绝测试入口保留。测试客户端已 `assembleHap` 编译成功，不代表设备或云端通过。

## 本机验证

在项目根目录运行：

```powershell
node experiments/shared-plan-preflight/test/auth-probe.mjs
```

runner 复用相邻 FortwoCloud/CloudDevSpikeOfficial 或 DevEco 已安装的 TypeScript；严格 noEmit 检查实际 Server SDK 声明，然后用注入验证器测试生产入口。没有联网、不安装依赖、不写任何运行产物。离线测试不能证实 SDK 对真实认证令牌的行为。

## 后续隔离部署的前提

1. 隔离客户端和新对象源码已准备，不用复制文件；在已有 CloudDevSpikeOfficial 打开／刷新 CloudProgram 树。
2. 用户部署 **sharedplanpreflight** 新云对象，不覆盖正式 pairing 或旧 spike-db。
3. 在隔离服务端设置 `FORTWO_AUTH_PROJECT_ID`，值是可信 AGC **项目 ID**，不是 appId；同时提供 Server SDK 所需的服务端认证配置。仅设置环境变量不能替代 SDK 凭据配置。
4. 服务端凭据仅放平台安全配置，不写客户端、不提交 Git、不贴聊天。代码不读取本机正式凭据、不记录令牌或 SDK 原始异常。
5. 两设备合法令牌返回不同指纹；错误项目、失效令牌与无令牌被拒绝。不要将原始令牌粘贴到日志或聊天。
6. 部署新对象类型，并在 AGC 建立独立存储区 **FortwoPlanProbe**；开启 CAS 探针环境开关后执行第三个按钮。只有两请求确实同时读到 1、一成一败、最终版本 2 与胜者一致才通过。

原三个按钮的真实调用现按用户回执通过；错误项目与真实撤销令牌不在这三个按钮内，仍待专门验证。探针的 `sharedPlanReady` 永远为 false。新增 dateplan 的服务端实现及隔离测试页已准备；正式 App 的页面、加密存储、活动投影及推送尚未接入。

`authFlag=true` 保留应用网关签名校验，不能将它当成认证主体的替代品。Region.REGION_CN 遵循当前隔离路线；不同区域项目需重新核对，而不是把区域作为客户端参数。

## 边界

通过身份探针仍不表示配对成员绑定安全，更不表示可以接收共同计划。“旧 uid 直接认领为认证主体”、简单 JWT 解码、普通 query＋upsert 伪装事务都禁止。完整门槛见 `docs/superpowers/plans/2026-10-03-shared-plan-confirmation.md` 与对应设计文档。
