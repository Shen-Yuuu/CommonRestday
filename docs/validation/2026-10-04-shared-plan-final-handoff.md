# 共同计划与通知：本机收尾交接

日期：2026-10-04。对应用户要求“将所有能做的事情做完，再列需要我操作的步骤”。

## 1. 结论

**本轮批准方案的本机实现与门禁通过，可以进入正式项目联调；不判公开发布就绪。**

已完成 App、云对象、通知发送器、独立补送 worker、离线回归和部署源码准备。没有登录控制台、部署云资源、操作模拟器、卸载或清空数据、修改签名，也没有上传隐私政策。工作区包含其他人的未提交改动，本轮没有替他们提交、撤销或合并。

用户此前报告通过的双端测试属于隔离测试项目。正式页面、伴侣对应证明和通知是本次新增，不能继承旧“全部通过”的设备结论。

## 2. 已完成的功能与用户可见效果

| 链路 | 本轮结果 |
|---|---|
| 发起计划 | 云配对且共同计划通道核实后发送邀请，保存为待对方确认；不提前占用时间、不提前写系统日历；未建立通道明确提示，不偷偷变成本机已确认计划 |
| 对方处理 | 计划页显示待我确认，提供同意／暂不安排；发起方可撤回，操作按本人角色及当前版本开放 |
| 已确认 | 两端读取云端权威状态后，以稳定 ID 各投影一条本机活动日程，参与今天／周历／空闲计算；与普通本机计划分区展示，不重复显示 |
| 改期 | 新修订待确认，原确认时间继续占用；对方同意才切换，拒绝／撤回只取消新修订，不取消原约 |
| 取消 | 已确认计划走共同计划取消，不允许用普通本机删除入口绕过对方状态 |
| 待确认提醒 | 计划 tab 持续显示玫红圆点，待确认结束后消失；区分等我和等对方，不把已经看过当作确认 |
| 不确定结果 | 保留原请求与原密文；用户点核实／重试先只读查原回执，明确未提交才检查冲突并重发，不自动生成新计划 |
| 通知 | 用户主动开启后登记本人的 Push Token；通用邀请／确认／改期／状态提醒，不包含计划标题、时间、姓名或配对标识；点击只导航计划页并读取最新状态，不代用户同意 |
| 回前台 | 只读核实已激活连接并刷新计划；对方解除后撤销本机活动投影，不自动重放未知的创建／加入／确认请求 |
| 解除与清空 | 原班表解除先核实共同计划解除；云拒绝不丢现有凭据。清空保留最小原身份补删账，已知连接和未知创建可补删，未知加入／身份丢失保留人工核实，不谎报已删除 |
| 本机密钥 | 创建会话密钥前先记录已知连接；晚到响应不能复活清空状态。云已撤销但本机密钥删除失败，单独保留本机密钥清理账，不继续称为云端残留 |

### 伴侣对应不能靠两个配对 ID 猜

新计划连接使用匿名认证与独立 HUKS 密钥，旧班表配对继续存在。两端用原班表配对密钥验证新公钥的密文证明，必须属于同一对伴侣才接入共同时间。两个不同项目或缺少证明的旧测试连接不能自动接管。

这次没有把旧班表协议整体升级成新认证协议，也没有迁移或覆盖旧快照。正式联调仍需一次新通道短码初始化，操作步骤中已说明如何保留原班表配对。

## 3. 关键实现位置

- 云端：`cloud-backend/cloudfunctions/dateplan/{dateplan,service,identity,protocol,push,dispatch}.ts`、五个 `clouddb/objecttype` 定义与模型反射。
- 安全通道：`cloud/src/main/ets/api/{DatePlanCloudApi,PlanPartnerLink,SecurePlanKeyStore}.ets`，`feature/src/main/ets/usecase/{SecurePairingUseCase,SecureSharedPlanGateway,SharedPlanUseCase,SecureCleanupUseCase,SecureLifecycle}.ets`。
- 存储与清理：`data/src/main/ets/repo/{SharedPlanRepo,SecurePairingRepo,ScheduleRepo}.ets` 及对应数据库迁移。
- 正式 UI：`entry/src/main/ets/component/{SharedPlansPanel,SecurePairingSetup,WindowDetailSheet,CapsuleSegment}.ets`、`view/{PlansView,CoTimeView}.ets`、`feature/.../{SharedPlanPresentation,SharedPlanViewService}.ets`。
- 通知接线：`entry/src/main/ets/util/PlanNotifications.ets`、`entryability/EntryAbility.ets`、`module.json5`；worker 构建入口 `tools/build-dateplan-push-worker.mjs`。

## 4. 本机实际证据

顺序运行，未并发运行共享输出目录的 runner，没有提高 `tools/verify-baseline.json`。

```powershell
node tools/verify.mjs --steps=offline,debug,release,ohostest,perf
node cloud-backend/test/dateplan-contract.mjs
node cloud-backend/test/dateplan-contract.mjs --es5
node tools/build-dateplan-push-worker.mjs
```

| 项目 | 结果 | 证据边界 |
|---|---|---|
| offline closed / open | 两档各 0 type error，337 passed / 0 failed，exit 0 | 同一组 337 用例跑两档，不是 674 个不同用例；编译副本切档不改源码开关 |
| 纯安全通道适配回归 | 20 passed / 0 failed | Node 适配器，不是设备 HUKS／认证 SDK／线上 AGC 证明 |
| 配对编排回归 | 23 passed / 0 failed | 包含只读前台检查、未知流程不重放、原关系证明、身份／连接栅栏 |
| 清理生命周期 | 29 条生产策略／清理用例通过 | 包含未知创建补删、未知加入保留、云端成功后密钥删除失败；不是设备卸载验收 |
| 数据库 | 实际 SQLite 迁移／回滚／原请求密文／原子投影／撤销等回归通过 | 非设备 ArkData 运行时，不能替代旧包覆盖安装 |
| 服务端 ES2020 / ES5 | 两档各 strict/noEmit PASS，47 passed / 0 failed | 实际 SDK 类型与事务存储桩；CAS 反事实会产生两个胜者，不把缺行自动锁住 |
| 隐私与静态接线 | copy、landing、press、对比度等审计通过 | 政策三处同源，不代表在线托管内容已发布；静态接线不代表观感 |
| clean debug | BUILD SUCCESSFUL，WARN 278，基线 289 | 编译不是启动／渲染证据 |
| clean release | BUILD SUCCESSFUL，WARN 276，基线 289 | 不是最终商店签名和提审通过 |
| clean ohosTest | BUILD SUCCESSFUL，WARN 258，基线 269 | 编译测试包，没有在设备执行测试包 |
| 性能 | 开发机预算通过，paired 120d P50 13.9ms | 开发机下界，不外推真机尾延迟、后台或锁屏 |

完整验证最终输出 `verify: ALL PASS`。日志在 `E:/desktop/Code/harmony/.crdtest/verify-*.log`。最后一处 App 调整只分离清理账的真实文案，另补 clean debug 复验；最后一处 worker 调整防止非 ASCII scheduler 密钥引起异常，ES2020／ES5 合同测试及 ZIP 重新生成。

本轮出现过红门禁，均改实现在原规则下转绿：

- ArkTS 结构化对象／未类型化字面量编译错误：改为明确接口与类型。
- 新计划面板未接既有 LatestLanding：接入真实读数归属栅栏，不新增豁免。
- 测试 barrel 未导出共享展示模型：补真实生产导出，不删用例。

## 5. 部署源与配置状态

已逐文件比较源码 SHA-256：**两个云工程各 16/16 文件逐字节一致**，含 dateplan 的 11 个部署文件及五个模型定义。

- 隔离：`E:/desktop/Code/harmony/CloudDevSpikeOfficial/CloudProgram`。
- 正式：`E:/desktop/Code/harmony/FortwoCloud/CloudProgram`。
- 未改：两个工程的凭据、`cloud-config.json`、现有默认存储区、旧 pairing/snapshot 部署文件。
- 独立通知部署包：`E:/desktop/Code/harmony/.crdtest/dateplanpush.zip`；入口 `dispatch.handler`，传统 Node.js callback 返回，timer 专用且要求服务器 scheduler 密钥，无客户端广播入口。

ZIP 结构复查通过：入口代码在根目录，Server SDK 依赖存在，835 个条目中未发现客户端配置、云项目配置或 PEM／P12／P7B／PFX 等凭据形态文件。这是本机打包检查，不替代云端秘密管理和实际执行。

正式主 App 项目 `101653523865149102`，隔离测试项目 `101653523865155672`。不要为沿用旧测试结果而搬身份或把主 App 改到隔离项目。

源码新开关 `securePairing=false`、`sharedPlan=false`；旧班表 `cloudPairing=true`。通知未部署不阻断本机日程，开关保持关闭不是“已经上线”。两个新开关只在正式部署准备完成后出联调包开启。

## 6. 仍需用户操作的清单

详细菜单、环境变量、验收步骤和成功判据均在 [用户操作步骤](./2026-10-04-shared-plan-operator-actions.md)。顺序：

1. 正式 ForTwoCloud：增量部署五个模型，保留班表区，在正式项目确认专用计划区。
2. 启用正式匿名认证，部署整个 dateplan 并复核项目／区／开关／超时。
3. 正式主 App：Push WORK 权益、同项目服务账号密钥，仅配置到服务器。
4. 上传独立通知 worker ZIP，配置服务器 SDK 凭据（若未注入）、scheduler 密钥和 cron；不暴露 HTTP。
5. 发布 AGC 托管隐私政策 v1.2，填真实主体、联系方式、生效日期；不恢复首启隐私弹窗。
6. 开新开关，签名并覆盖安装双端联调包；保留原数据，建立与原伴侣匹配的计划连接。
7. 在正式计划页验邀请／确认／改期／撤回／取消／断网原请求；两台真机补后台／正常关闭／锁屏通知。
8. 可丢弃实例补解除／清空／身份变化／卸载／备份／第三台拒绝与 ohosTest；贵重数据设备不做破坏性测试。

遇到控制台没有 timer 输入参数、环境变量放不下密钥、模型部署要求删库等提示，停止并提供无密钥截图。不要为继续测试关闭鉴权、删活动行或硬塞凭据到 App。

## 7. 没有被本轮“做完”消除的发布门槛

- 每连接仍限 50 个计划／200 个业务请求／400 个事件。安全拒绝 BACKLOG_FULL，不截断数据；公开运营需要容量、历史归档与有审计的分批清理方案，不能承诺长期无限使用。
- 墓碑三十天只是运维标记，尚无自动物理删除任务；删墓碑可能使旧请求重建，不擅自加定时删行。
- 未知 JOIN 结果和原匿名身份丢失，不能通过猜连接／重建身份安全补删；保留最小记录供开发者核实。
- 一小时窗口、最多三次是通知补送代码边界；SENT 只表示平台接受。已经进入网络或平台离线缓存的旧消息不能强制撤回，点开重新核实。
- 正式账号、权益、timer 事件格式、配置安全、签名、备案、成本、隐私托管发布和真机证据仍待外部操作。

以上是明确边界，不用额外功能扩张来冒充验收通过。本机可完成项已交接，后续先正式联调、再按外部结果修正，不对线上资源和用户数据做推测性操作。
