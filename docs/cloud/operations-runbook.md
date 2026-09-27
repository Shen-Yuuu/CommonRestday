# 云侧运维手册 v1

> 配套：`docs/cloud/pairing-protocol-v1.md`（协议，唯一事实源）与 `cloud-backend/README.md`（代码放哪、怎么部署）。
> 状态：**云端链路已全线跑通**（2026-09-27 第三轮部署后，24 步全生命周期探针 `not_clean=0`，§2.4 第 14 行）——
> 存储区在、两个云对象是 `this-free` + `inviteCode` 那一版、状态机与权限与幂等级联删除逐条对上。
> 历次卡点（存储区不存在 / `this` 被摘 / 包络保留名顶掉语义码）全部已解，实测记录在 §2.4 第 11/12/13 行。
> **剩下的都不是云端代码问题了**：① §2.4 第 14 行已坐实"重新部署会把控制台手改的超时推回向导默认 60s"，
> 所以**函数超时现在需要再改回 20s 一次**（§1 第 7 步，且必须在最后一次云端部署之后）；
> ② 协议 §11 的端侧与双设备证据一条没勾，那才是 `cloudPairing = true` 的闸门。
> 已实测过的路径会标 `[实测]`，只有文档依据的标 `[文档]`，
> 需要账号持有者本人在 AGC 控制台点的都标 `[需你操作]`。
> 2026-09-27 依实现回写：删掉了"8 个云函数""三份对象类型""云数据库安全规则"这三处从未成立的前提（§2.2、§2.3）。

## 1. 一次性前置（开通前核对，缺一不可）

| # | 事项 | 为什么是硬条件 | 出处 |
|---|---|---|---|
| 1 | 账号已实名认证、注册地为中国境内（港澳台除外）、**账户无欠款** `[需你操作]` | 欠款会连带卡住云开发开通；开通靠 DevEco 勾选协议自动完成 | docs/05 §1 |
| 2 | 数据处理位置只启用「中国」，之后**不再改动** `[需你操作]` | 云开发仅支持中国境内；更改或取消启用**可能自动清理云侧数据且不可恢复** | docs/05 §3.3 |
| 3 | 手动开启**消费提醒 + 余额不足提醒** `[需你操作]` | 免费档"用尽即停"不会自动扣费也不会自动扩容；配额提醒只有互动中心消息是默认有的 | docs/05 §3.1 |
| 4 | 运行时在 **AGC 控制台**显式设成 Node.js 20 `[需你操作]`；不要沿用旧 `@hw-agconnect` SDK 写法 | 2025-11-04 起云函数运行时收窄为仅 Node.js。`[实测]` DevEco 向导给的默认值是 `nodejs14.x`，而且**本地改不了**（`function-config.json` 没这个键，值写死在 IDE 插件里，§2.4 第 3 行）。14 目前跑得起来，云侧用到的三项 crypto 已在 `nodejs14.x` 线上全部证实（§2.4 第 12/14 行）所以这条是**迟早要换**而不是阻塞 | docs/05 §8 |
| 5 | 服务端凭据放在**仓库外**（`ForTwoPrivate/agc-apiclient-*.json`），经环境变量交给探针 | 凭据进仓库＝进 git 历史，删不掉。云对象自身不需要它——AGC 运行时用 `PROJECT_CREDENTIAL` 注入 | `[实测]` spike 的 `server-probe` |
| 6 | 端云工程关联后记下 `CloudProgram/cloud-config.json` 的位置与里面的项目/应用 ID | 这份文件是向导产物，**永不进 git**（含 projectId/appId/teamId） | `[实测]` |
| 7 | **在最后一次云端部署之后**，把 `pairing` 与 `snapshot` 两个对象的函数超时在 AGC 控制台设为 **20s** `[需你操作]` | 端侧统一 30s（协议 §3.3），函数超时必须更小，否则慢请求由端侧先断、把 `QUOTA_EXCEEDED` 那类语义失败压成普通网络失败。**这条排在部署后而不是部署前**：`[实测 2026-09-27]` 手改过的超时会被下一次重新部署推回向导默认 60s（§2.4 第 14 行），所以每部署一次就要重设一次 | §2.4 第 3/14 行 |

**关于 `agconnect-services.json`**（此前本文与 docs/05 §5.1 写作"该文件不存在"，那是不准确的）：
文件名的确有——AGC 控制台添加应用后可下载，官方模板会把它放进 `Application/AppScope/resources/rawfile/`。
但**它不是本链路的必要条件**：`[实测]` 真正跑通端云互通的 `CloudDevSpike/` 工程里根本没有任何
`rawfile` 目录，`cloudFunction.call` 靠的是**签名配置与云工程关联**（模拟器再加一个 debugToken，§2.1 第 4 步）。
本仓库已在 `.gitignore` 里忽略 `AppScope/resources/rawfile/agconnect-services.json`，放置与否都不入库。
**未验证的边界**：以上只在模拟器 + debugToken 路径上成立。真机若报鉴权类失败，第一件事是补这份文件再复测。

**免费额度**（按月/按天重置，非一次性试用）：云函数请求 100 万次/月、内存时长 40 万 GB-s/月、出流量 5 GB/月；云数据库存储 1 GB/月、出站 10 GB/月、对象读/写/删 50000/20000/20000 次/**每天**、同时连接 150、每秒操作 10。双人低频场景实测占用量级约为月请求配额的 0.01%（docs/05 §2.1），**容量不是问题，闲置回收才是**。

## 2. 部署

### 2.1 部署顺序（错了会白跑）

1. `[需你操作]` 在 DevEco 里对正式应用（`com.common.fortwo`）走一次 `New > CloudProgram`，
   生成向导工程（仓库外，见 `cloud-backend/README.md` §2）；
2. 把 `cloud-backend/clouddb/` 与 `cloud-backend/cloudfunctions/{pairing,snapshot}/` 复制进向导工程对应位置；
   **只复制，不改**——`contract.ts` 与两份对象类型 `.js` 在两个云对象目录里是同一份字节；
3. **先部署 CloudDB**：右键 `clouddb` → `Deploy Cloud DB`（两张表：`PairSession`、`PairSnapshot`，
   存储区 `FortwoPair`）。区名不能含下划线 `[实测]`（下划线形态报 `invalid CloudDBZone name`）；
4. 右键 `cloudfunctions/pairing` → `Deploy 'pairing'`，再 `snapshot` 同理。
   部署前 `npm install`（SDK 版本已钉死在两个 `package.json` 里）；
5. **免设备先验两件事**（`cloud-backend/README.md` §6 的第 0 / 0.5 步，在 Node 里用服务端凭据跑）：
   第 0 步确认存储区真的在（拿到 `2002037` 就别往下走了，处置 §4.7）；第 0.5 步把云对象调起来，
   一次证掉"入参形态对不对"和"公开方法依赖 `this` 没有"（拿到空 dbCode 的 `INTERNAL` 处置 §4.8）；
6. 端侧：关联签名配置 → 模拟器取 `clouddevelopproxy.debugToken` 注册到 AGC（模拟器无登录态，缺这步必然失败）
   → 按 `cloud-backend/README.md` §6 的第 1–3 步验一次 `create → status → put`；
7. 探针用完 `unpair` 清掉测试行，别在正式项目里留脏数据。

`[实测]` 部署是**本地执行**的（DevEco 把 TS 编译后上传），所以 Windows 上 `snapshot.ts` 与
`function-config.json` 里 `Snapshot` 的大小写差异不阻塞部署——但别依赖这一点，
生成接口时报 `Entry module not found` 就先查文件名。

### 2.2 数据访问口径（不是"安全规则"）

原先这一节写的三条 `request.auth.uid == …` 规则**在 CloudDB 的 objecttype 形态下不存在** `[实测]`：
权限能配的只有对象类型 JSON 里的 `permissions`，四个角色（World / Authenticated / Creator / Administrator），
每个角色给 Read/Upsert/Delete 的组合，**没有表达式**。本项目的配置是：

| 对象 | World | Authenticated | Creator | Administrator |
|---|---|---|---|---|
| `PairSession` / `PairSnapshot` | `[]` | `[]` | `[]` | `Read, Upsert, Delete` |

也就是说：**端侧直连云数据库读写不到任何东西**（预期 `2001015: permission denied`），
一切数据访问都必须穿过云对象，由 `pairing.ts` / `snapshot.ts` 做成员、状态与版本判定。
这不是"默认拒绝的保守配置"，而是本产品的**唯一**访问路径——所以：

- 任何人把 `permissions` 里的空数组放开一格，等于在数据库层面绕开了协议 §4 的全部判定；
- 每次改动 objecttype 后重跑协议 §11 第 10 项（第三设备越权用例）；
- 云对象内部用服务身份访问数据库，因此 `2001015` **出现在云函数日志里**就是部署缺陷（§4.3），不是攻击。

### 2.3 部署单元与资源建议

只有**两个云对象**（不是八个云函数）：`functionType: 1`，部署后不可变更类型。

| 云对象 | handler | 方法 | 触发方 | 频率 | 写库 |
|---|---|---|---|---|---|
| `pairing` | `pairing.Pairing` | create / join / confirm / status / unpair / heartbeat | 用户动作、设置页对账、冷启动+每周心跳 | heartbeat 最高，其余极低 | 会话行；heartbeat 不碰库 |
| `snapshot` | `snapshot.Snapshot` | put / get | 保存后 5s 合并窗口 / 读数路径按需 | 低 | 单对象覆盖写 |

- 内存与超时**只能在 AGC 控制台按对象设**（本地 `function-config.json` 里没有这两个键）：
  `[实测 2026-09-27]` 向导默认 500MB / 60s，内存沿用 500MB（建议值 128MB，
  双人低频场景下省的是月内存时长配额，不是当次体验）；超时**目标值 20s**，但**目前线上是 60s**——
  控制台改到 20s 之后又被一次重新部署推回默认（§2.4 第 14 行），所以这条是开闸前置动作而不是已完成项；
  `unpair` 要给到 15s，它要在一次调用里删完两行快照再删会话；
- 云函数同步调用上限 55s，端侧统一 `timeout: 30000`（协议 §3.3）；**函数内部耗时必须 < 30s**，
  否则客户端先断、服务端还在写，会得到"失败但已写入"的假不一致；
- `put` 的体积阈值按协议 §4.7 的 2 MB 拒绝；云侧**不解密、不解析明文**，所以它的 CPU 与载荷内容无关；
- 版本策略见 §5：端侧写死 `$latest`，这条在 2026-09-27 是个已知限制而不是选择。

### 2.4 首次部署实测（2026-09-27，AGC 项目「两人份」已建）

云侧第一次真实存在了。落点：`E:/desktop/Code/harmony/FortwoCloud/`（向导生成 `Application/` 示例应用
+ `CloudProgram/` 云工程，都在仓库外）；15 份云侧文件复制后与 `cloud-backend/` **逐字节相同**（`cmp` 全过）。
下面是只在真实部署里才看得见的东西：

| # | 实测到的事实 | 影响 / 处置 |
|---|---|---|
| 1 | **`Deploy Cloud DB` 报 success，存储区却根本不存在。** 用服务端凭据直连 `FortwoPair` 读两张表，两次都得到 `2002037: CloudDBZone does not exist`；而 DevEco 日志里同一时段前两次 cloudDB 部署分别以 `206766192`（`createDataBaseResource` → `Failed to decode response body`）和 `206766200`（`AuthenticationError: authentication failed`）失败，第三次才 `Success` 并把 `schemaVersion` 查询到 `1` | `[实测]` 说明"成功"只覆盖到**对象类型/schema**，`createDataBaseResource`（建存储区）那一步没落地。这是当时判定的唯一阻塞（第 11 行又查出第二条）：云对象再对，一读写库就是 2002037。处置见 §4.7——存储区要在 AGC 控制台单独建，名字必须等于 `contract.ts` 里的 `ZONE` |
| 2 | **判断"某个云对象部署没有"要看 DevEco 日志，不能看 `build/target`**：每次部署建一个新的 `build/target/<hash>/`，成功后**上一个会被删掉**，所以磁盘上只剩最后一次的产物（本次 `751be` 已消失、只剩 `daf4c`）。日志里 `[pairing] reason=success` 与 `[snapshot] reason=success` 都在 | 我一度据"只剩 snapshot 目录"误判 `pairing` 未部署——**结论是错的**，两个云对象 16:57:41 / 16:57:54 各部署成功一次。日志行 `DeployService - query deploy status response` 里的 `"name"` 与 `"reason"` 才是准的 |
| 3 | 向导给的默认资源参数是 **`runtime: nodejs14.x`、`timeout: 60`、`memorySize: 500`、`instanceConcurrency: 100`**（读 `build/target/<hash>/<对象>/template.yaml` 得到），**与 §2.3 的建议值无关**。`[实测 2026-09-27]` 这两个值**本地无处可改**：两份 `function-config.json` 只有 `handler`/`functionType`/`triggers` 三个键，整个云工程里出现 `runtime`/`timeout` 的文件只有部署产物 `template.yaml`；DevEco 插件 `PackageCloudFunction.class` 里是写死的 `NODEJS_RUNTIME`/`DEFAULT_TIMEOUT` 常量，"新建云函数"对话框只收名字 | `timeout: 60` 同时超过同步调用上限 55s 和端侧 30s 超时——正好制造 §2.3 警告的"客户端先断、服务端还在写"，**要改到 20s，且只能在 AGC 控制台改**。`nodejs14.x` 按第 11/13 行的实测重排为**降风险而不是阻塞**：`crypto.randomInt`（≥14.10）与 `crypto.randomUUID`（≥14.17）已在线上跑出邀请码并落库，只剩 `toString('base64url')`（≥14.18）要到 `join` 才覆盖；14 已 EOL 且华为 2025-11-04 起新建函数只支持 Node.js，所以迟早要换 |
| 4 | 触发器配置逐字落地：`enableUrlDecode: true / authFlag: 'true' / authType: apigw-client / authAlgor: HDA-SYSTEM`，`functionType: 1` | 与我们写的 `function-config.json` 一致，无需再调 |
| 5 | 打包内容 = 编译产物 + 依赖 + **源文件**：zip 里同时有 `snapshot.js`/`contract.js` 和 `snapshot.ts`/`contract.ts`/`*.js.map`，两份对象类型 `.js` 也在 | 编译与打包形状符合预期（模型 `.js` 没被 tsc 吞掉）；源码随包上传是向导行为，云侧代码里没有凭据，可接受 |
| 6 | **`clouddb/objecttype/` 是整个目录一起部署的**，向导自带的示例表 `Post.json` 因此进入 schema，而它的 `permissions` 是四角色**全开**（World 可 Read/Upsert/Delete），配套的 `dataentry/d_Post.json` 还会写示例行 | 这是 §2.2 那条警告的现成事故：一旦存储区建起来，里面就躺着一张公网可写的表。处置＝删 `objecttype/Post.json` + `dataentry/d_Post.json`（以及示例函数 `cloudfunctions/id-generator/`）后重新 `Deploy Cloud DB`。我们两张表的权限核对无误：World/Authenticated/Creator 全空，仅 Administrator 有 Read/Upsert/Delete |
| 7 | `Deploy Cloud DB` 会在**应用侧**生成 `Application/AppScope/resources/rawfile/schema.json`，`permissions` 从对象类型 JSON 里提到根数组按表分列；索引如实落地（`PairSession` 的 `code`/`creatorUid`，`PairSnapshot` 无索引按复合主键读） | 这份 `schema.json` 是**端侧直连**用的，本产品不直连，因此不需要把它拷进 `cloud/` HAR；但它是一份很好的"云侧 schema 与仓库源码是否一致"的核对材料——本次就是靠它确认 `ciphertext` 真的是 `Text` |
| 8 | 云工程绑到的是**另一个 AGC 应用**：向导的示例应用是 `com.common.fortwocloud`，`cloud-config.json` 的 `appId`（`6917617526333646177`，"两人份云"）≠ 本仓库 `agconnect-services.json` 里 `com.common.fortwo` 的 `app_id`（`6917617383543050045`）；**`projectId` 两边相同**（`101653523865149102`，项目"两人份"） | spike 的结论是"同 bundle name 关联 + 签名 + debugToken"，所以跨 appId 调用会不会 403 **属未知**（华为文档站这一轮只回 1749 字节的 SPA 壳，取不到正文；不作断言）。`[实测 2026-09-27]` **这个绑定改不了**：云工程一旦生成，DevEco 项目结构页里"关联云工程"是灰的，手改 `cloud-config.json` 没有依据说 IDE 会接受。处置＝**先不动**，云资源挂在项目而不是 App 上，用一次真实端侧调用来判定；**只有**回包是 401/403 一类鉴权失败（`2002037` 那类库/区失败不算，判据见 §6 第 0.5 步的表）才回到 §1 第 1 步：在 `CommonRestday` 里 `New > CloudProgram` 生成绑到 `com.common.fortwo` 的新云工程，把 `clouddb/` 与两个函数目录复制过去**只重新部署函数**（同项目同名的存储区不用重建） |
| 9 | 服务端凭据（`ForTwoPrivate/agc-apiclient-*.json`）的 `project_id` 与云工程、与仓库里那份 `agconnect-services.json` **三者相同**，且用它直连能拿到 CloudDB 的业务错误码而不是 401 | `[实测]` 凭据没拿错项目——上面第 1 行的 2002037 是"区不存在"，不是"你没权限"，这条排除了凭据错配这个嫌疑 |
| 10 | **云对象可以用服务端凭据从 Node 直接调起来，不需要设备。** 框架自己解析 `data.method`：缺它回 `Call handler error: cloud object method is empty`，写错回 `Can't find cloud object method X`；`params` 走 `func.apply(?, params)` 按位置展开——把 `params` 换成 JSON 字符串会得到 V8 的 `CreateListFromArrayLike called on non-object` | `[实测]` 两点用处：① 端侧 `{method, params}` 这条契约被线上证实（与 `CloudObjectInterface.js` 里 ImportObject 模板发的 `data: {method: prop, params: args}` 对上），协议 §3.3 不用改；② README §6 的"分派形态"探针从此可以在**没有设备**的时候先跑一遍，不必等真机 |
| 11 | **框架把方法从实例上摘下来调，`this` 不是实例。** 原来的公开方法写成 `guarded(() => this.doX(...))`，于是每一次调用都在读库之前抛 `Cannot read properties of undefined (reading 'doX')`，被 guarded 塌成 `{"code":"INTERNAL","message":"cloud error "}`。拿 `build/target` 里那份**线上编译产物**在本地按同样方式调，复现出逐字节相同的包络 | `[实测]` 这条最容易踩，因为向导样本 `IdGenerator.randomUUID()` 一个 `this` 都不碰，坑被掩盖到第一次真调用。修法＝公开方法只做转调、业务函数放模块级（本次已改两个云对象，**必须重新部署一次**）。判据留下：`INTERNAL` 且 message 尾部**没有** dbCode ⇒ 云对象在读库前就炸；尾部带 dbCode（如 `cloud error 2002037`）⇒ 云对象是好的，问题在库/权限/区，见 §4.7。细则 §4.8 |
| 12 | **第 11 行那版修复已上线，且存储区确实存在了。** 用服务端凭据在 Node 里直连线上云对象：`create` 回 `code:"OK"` 并带出 6 位码与 `pairId`，`snapshot.put` 把 **1776 字符**的密文写进 `PairSnapshot.ciphertext` 成功、`get` 原样读回（长度一致） | `[实测 2026-09-27 18:01 部署]` 第 1 行的"唯一阻塞"就此解除，§4.7 的建区动作被证实有效；`ciphertext` 是 `Text` 而不是 `String` 这条也被线上证明（200 字符硬限没有拦下 1776）。同时 `crypto.randomInt` 与 `crypto.randomUUID` 在 `nodejs14.x` 上跑通＝第 3 行的运行时问题降级为"迟早要换" |
| 13 | **包络的保留名会被业务字段顶掉，而且顶掉的是成功判定本身。** `ok()` 原本先写 `code:'OK'` 再把载荷并进同一个对象，而 `sessionBody(withCode)` 把 6 位邀请码放在键 `code` 里——于是每一次 `pairing.create` 的语义码被 `"403153"` 这种数字串覆盖，端侧 `CloudGateway.unwrap()`（判 `code === 'OK'`）会把**所有成功配对**读成失败。修法＝包络四键在合并**之后**钉死，邀请码在报文里改名 `inviteCode`（库里那列仍叫 `code`），并把这个改名作为 `schemaVersion` 1→2 的全部内容 | `[实测 2026-09-27]` 第 12 行那次"绿"里藏着它：探针当时按 `body.code` 取邀请码，取到的其实是语义码位上的数字串，`create` 判 FAIL 却没拿到 `pairId`，后面 21 步全成 `NOT_FOUND`——**一条根因伪装成 22 条失败**。教训两条：① 探针的验断函数不许挂在上一步的判定后面（跨步状态必须无条件捕获）；② 只要包络是"语义码 + 自由业务字段"扁平合并，就必须把保留名写进协议并让 `ok()` 钉死，见协议 §3.2。**这条改了 wire 字段名，云端与端侧必须一起上**，两份 `contract.ts` 已同步到云工程，函数需再部署一次 |
| 14 | **第三轮部署（18:32）之后，云端契约用 Server SDK 从 Node 侧全线跑通：24 步全生命周期探针 `not_clean=0`。** 逐条对上：`create` 回 `code:"OK"` + `inviteCode` 六位码（第 13 行的改名已生效）→ `status` 不带码不带 token → `join` 回 32 字符 **base64url 无填充** token → 加入方确认 `FORBIDDEN`、错 token `FORBIDDEN`、发起方确认转 `ACTIVE` → `put` 1776 字符写进 `Text` 列并原样读回、重放幂等、异载荷撞 `CONFLICT_VERSION`、版本回退 `BAD_REQUEST`、`shareLevel=9` `BAD_REQUEST`、`schemaVersion=3` `SCHEMA_UNSUPPORTED`、外人 `FORBIDDEN` → `get` 只给"对方"那份且无更新时回空包 → `heartbeat paired=true` → `unpair` 一次清掉两行快照、`status` 随即 `NOT_FOUND`、重放回 `deletedVersions=0` | `[实测 2026-09-27]` 三条副产品：① `toString('base64url')`（Node ≥14.18）也在线上跑通了，第 3 行动手前留的最后一个运行时疑点关闭，`nodejs14.x` 三项 crypto 全部证实；② `snapshot` 拒 `schemaVersion=3` 而收 `2`，说明两个云对象**都**是 U6 那一版（`build/target/` 里只剩 `snapshot` 一个目录，不能用来判断 `pairing` 部署没有——见第 2 行）；③ 探针自己收尾把测试行删干净了，正式项目里没留脏数据。**这 24 步一条也不能顶替协议 §11 的设备证据**：那是端侧行为与双机时序，这里全是服务端视角。**已坐实（2026-09-27 用户核对控制台）**：本轮重新部署把之前手改的 20s **推回了向导默认 60s**——DevEco 的部署描述符取自服务端模板接口（`serverless-tempalte-service/v1/server/ide/template`），每轮部署按默认值重生成 `template.yaml`，**控制台手改的运行期配置不跨部署存活**。所以规则是**改配置必须放在最后一次部署之后**，且这一条已升成 §1 第 7 步的前置动作。端侧 `CloudApi.ets` 头部第 2 条那句"30s 一定是外层"的前提也随之失效，注释已按"当前 60s、不变式破"改写 |

## 3. 日常巡检（每周一次，10 分钟）

| 看什么 | 在哪看 | 触发动作 |
|---|---|---|
| 三项服务的免费额度与已用量 | 项目设置 → 项目配额 | 任一项 > 60% → 查异常调用源（§4.5） |
| 云对象错误率与 P95 耗时 | 云函数监控（按对象看，不再按 8 个函数） | 错误率 > 1% 或 P95 > 3s → §4 |
| `pairing.heartbeat` 调用量 | 云函数监控 | 开闸（`cloudPairing=true`）**之前**恒为 0 是设计值，不要当故障修；开闸之后**有配对用户却连续 7 天为 0** 才是接线坏了。收窄口径见协议 §4.6：**未配对的安装一条都不发**，所以这个计数器反映的是"有多少人在用配对功能"，不是"项目是否活跃" |
| 数据库对象数 | 云数据库 | `PairSnapshot` 行数 > 配对数 × 2 → 解除配对级联删除有漏；`PairSession` 里 `REVOKED/EXPIRED` 堆积 → 正常（码不落库留存，但会话行不删） |
| 项目最后活跃时间 | **AGC 控制台**（云对象响应里没有这个字段，协议 §4.6） | 临近 6 个月 → 手动发一次调用，别等预警 30 日 |

闲置回收是本产品**最容易踩**的运维风险：双人低频意味着一个寒假不打开就可能触发（docs/05 §3.2）。
而**护住项目活跃度的不是心跳，是"有没有人在用"这件事本身**：只要装内有任何一次云对象调用（快照推拉、
配对动作、心跳）项目就不算闲置，所以真正该盯的是上面"项目最后活跃时间"那一行加本表的调用量合计。
心跳（U3b-1 起，只由 paired 安装的回前台带起、7 天节流）做的是**给单个 pair 的两行快照补一次额外保险**，
它挡不住"整个装机量归零"那种情形——那种情形下该发生的是 owner 从 30 日预警里看见它并自己决定要不要留项目。

## 4. 故障手册

### 4.1 端侧 `CloudApiError('LOCAL')`（AGC 未初始化/未开通）

错误码来源：`201`（缺 INTERNET 权限）、`1008210009`/`1008211001`（客户端内部错误 / 服务端错误、
签名与云工程凭据不匹配）。排查顺序：签名配置是否与云工程关联 → 模拟器是否注册 debugToken →
`cloud-config.json` 是否存在且项目 ID 正确 → CloudDB 是否先于云对象部署。
**端侧行为已定：一律降级本机，不重试、不弹窗轰炸。**

### 4.2 `1008210001`（网络连接错误）→ `'NETWORK'`

映射为 `retryable = true` 的网络类错误。用户侧网络问题占绝大多数，不告警；只有**同时段大面积**出现才查云函数可用区。

### 4.3 `2001015: permission denied`

两种可能，必须区分：
- 出现在**端侧直连**路径 → 预期行为，说明 §2.2 那圈空权限生效了，改代码走云对象；
- 出现在**云对象内部**（AGC 日志里） → objecttype `permissions` 被改过或表没建好，属**部署缺陷**，
  立刻按 §5 回滚配置。

新增一条同类：`2060 WRITE_STRING_VALUE_SIZE_EXCEED_LIMIT` 或 `2003 DATA_SIZE_IS_OVERFLOW`
→ `ciphertext` 列被改成了 `String`（限 200 字符）。这张表的这一列**必须是 `Text`**，
协议 §4.7 的 2 MB 阈值才有意义。

### 4.4 `QUOTA_EXHAUSTED` / 配额用尽

免费档用尽即停（不自动扩容、不自动扣费）。处置：
1. 端侧**不会**自动重试（协议 §3.3：没有退避循环），所以配额是被真实调用烧掉的，不是被重试烧掉的；
   U3b-3 之后这一格有了可见形态：配对卡念「云同步待重试」＋"今天的云同步次数已经用完"那一句，
   持久态是 `cloud_sync_state = RETRY|<日序>|QUOTA_EXHAUSTED`，并且**当天不再排推送**（协议 §7 末行）。
   所以用户报"配额烧穿了"时，控制台当天的调用数只该有真实保存那么多；还在持续涨就不是这一条，走 §4.5；
2. 查调用源：最常见是心跳被写成了每次进 App 都发，或 `snapshot.get` 漏传 `sinceVersion` 导致每次全量拉；
3. **不要**为绕过配额而升级按量付费——降级到"今天不同步"对本产品完全可接受（主路径是本机代录）。

### 4.5 异常调用放大（疑似被刷）

症状：云对象请求量突增、数据库对象读暴涨、出现非成员 `FORBIDDEN`。
处置顺序：AGC 侧对两个云对象加限流 → 撤销可疑会话（`pairing.unpair`）→ 通知受影响用户重新配对。
注意：载荷是加密的，被刷的最坏后果是配额耗尽与元数据（uid/pairId/version/shareLevel）暴露，不是日程泄露。
成员**之间**的伪造写入是另一件事，协议 §6.1 第 2 条已经明确本产品不防这一层。

### 4.6 「已配对但看不到对方数据」

第一步先读界面上挂的是哪一句（U3b-3 的三态，`cloud_sync_state`）：「云同步待重试」= 这次失败被判为可重试
（网络、超时、配额、服务端 `INTERNAL`），当天已停止重排；「云同步已停止」= 端侧判定重试也不会变（鉴权类、schema 不匹配、解密/解码炸了），
**这一格换日不放开**，只有某次拉成功才清回「已同步」；两句都没挂 = 本机最近一次云往返是通的，
**或者还没试过**（`cloud_sync_state` 是空串就是后者，别把它当成"通路已验证"）。

按顺序判：`pairing.status` 是否 `ACTIVE` → 对方 `version` 是否 0（对方从没推过）→ 本机是否解密失败
（密钥失配，协议 §7）→ 本机是否把 `snapshot.get` 的"无更新"当成错误 → **HUKS 别名是否还在**
（卸载重装/清数据之后 `isKeyItemExist` 会答 false，此时任何拉到的密文都解不开）。
**禁止的处置**：为了让界面有内容而伪造对方数据，或在解密失败时自动重建密钥。

### 4.7 云对象报 `2002037: CloudDBZone does not exist`

**部署侧缺陷，不是运行期故障**（2026-09-27 首次部署实测 §2.4 第 1 行）。识别方法：云对象日志里出现 2002037，
或 `template.yaml` 显示部署成功但 `createDataBaseResource` 在 DevEco 日志里报
`206766192 Failed to decode response body` / `206766200 AuthenticationError`。

排查顺序（本次就是按这个顺序定性的）：

1. 用**服务端凭据直连**存储区读一次空查询（Server SDK，`AGC_CONFIG` 指凭据路径）：
   拿到 `2002037` ⇒ 区确实不存在；拿到 401/403 类 ⇒ 是凭据/项目错配，先解这个；
2. 核对 `contract.ts` 里的 `ZONE` 与控制台**实际**区名（含大小写、无下划线）是否一致——不一致就只有两种修法：
   控制台把区改成 `FortwoPair`，或改 `ZONE` 重新部署云对象。**别两边都改**，那会让下一次对账失去唯一参照；
3. `Deploy Cloud DB` 的 "success" 只代表 schema/对象类型登记上了，**不能当作区存在的证据**；
   区要在 AGC 控制台 → 云数据库里单独建，并把两张对象类型加进去；
4. 建好后**先复跑第 1 步**（库侧），再跑云对象侧的免设备探针（`cloud-backend/README.md` §6 第 0.5 步），
   最后才是端侧探针——顺序反了会把"区没建"误诊成"云对象写错了"。

端侧不需要为这条做任何事：云对象内部失败会塌成 `INTERNAL` 包络，端侧照 §4.1 静默降级到本机。

### 4.8 云对象回 `INTERNAL` 且 `message` 尾部没有 dbCode

`{"code":"INTERNAL","message":"cloud error ","retryable":true}` ——**尾部那个空位是关键**：
`guarded` 的失败包络固定是 `'cloud error ' + dbCode`，带码（例如 `cloud error 2002037`）说明异常来自
CloudDB，空着说明抛的是**没有 code 的 JS 异常**，也就是云对象在读库之前就炸了。这两种 `INTERNAL` 的
处置完全不同，别混成一条。

读库之前就炸的，本次实测到的只有一种成因：**云对象框架不绑定实例地调用方法**（§2.4 第 11 行）。

1. 定性：拿 `CloudProgram/build/target/<hash>/<对象>/<对象>.js`（就是线上那份编译产物）在本地
   `Snapshot.prototype.get.apply(undefined, [pairId, uid, 1])` 调一次——回空 dbCode 的 `INTERNAL`、
   而 `new Snapshot().get(...)` 回正常语义码，就是这一条；
2. 修法：公开方法只做转调，业务逻辑放模块级函数（`pairing.ts` / `snapshot.ts` 已经这么写了），
   **不要**试图用构造函数里 `bind` 绕过——框架从实例上摘下来调的时候绑不绑得住没保证；
3. 反查自己：以后新增任何云对象方法，第一行之前先确认它不读 `this`。向导样本永远不读 `this`，
   所以它永远给不出这个警告。

改完必须**重新部署两个云对象**再看探针；只改仓库不部署，线上还是旧字节码。

### 4.9 云侧完全不可用

预期表现：本机录入、共同时间计算、计划、冲突全部正常，只有「伴侣与同步」挂出三态里的那一句
（网络/超时/配额这类判为可重试的 → 「云同步待重试」；AGC 未初始化这类判为不可重试的 → 「云同步已停止」，
归类口径在 `CloudApi` 的传输层映射，协议 §3.4 末尾两条实现口径）。
这是验收项（`docs/testing-checklist.md` §9.3），不是事故。真正的事件是"云端故障导致本机功能变慢或崩溃"——那是降级路径有洞，按缺陷处理。

## 5. 回滚

| 对象 | 回滚方式 | 数据影响 |
|---|---|---|
| 云对象代码 | **重新部署上一版代码**（端侧写死 `$latest`，没有"切版本号"这条路） | 无 |
| 云对象版本 | 端侧 `version: '$latest'` 是**已知限制**：想按版本回滚，得先把端侧改成读一个可配版本号并出包 | 无 |
| 云数据库 schema | **禁止破坏性回滚**；只允许向前兼容加字段 | 回滚列删除会丢快照；改列类型（尤其 `ciphertext`）要新建表迁数据 |
| 数据访问口径 | 还原 objecttype `permissions` 为四角色表（§2.2）并复跑越权用例 | 无 |
| 配对能力（总开关） | 端侧 `FeatureFlags.cloudPairing = false` 重新出包 | 云侧数据保留；本机数据不受影响 |

**协议不兼容时 `$latest` 会伤到什么**：`schemaVersion` 是端侧随每次 `create`/`join`/`put` 传上去的，
云侧不匹配就回 `SCHEMA_UNSUPPORTED`（拒绝写入，不静默降级）。所以新旧两端共存的表现是
"老端同步停摆 + 明确提示升级"，而不是数据被写坏——这是当前唯一需要的护栏。

停服＝把 `cloudPairing` 关回 `false`，**不需要**删云数据：删数据是不可逆动作，而关开关已经能让全部用户回到本机代录主路径。确需清除某个 pair 的数据时走 `pairing.unpair`；确需清除全部数据时删除整个项目（不可恢复，需二次确认并先导出配置）。

## 6. 隐私审计（每次改动后必做一次）

对照 `cloud-backend/clouddb/objecttype/*.json` 的字段集（协议 §5.2 的清单就是它，改表必改协议）：

- [ ] `PairSnapshot` 明文列只有 `pairId / ownerUid / peerUid / version / shareLevel / schemaVersion / algorithm / iv / authTag / updatedAt`，`ciphertext` 是密文；
- [ ] `PairSession` 明文列只有 `pairId / status / code / creatorUid / creatorPublicKey / joinerUid / joinerPublicKey / confirmToken / schemaVersion / createdAt / updatedAt / expiresAt`；
- [ ] 两张表里**没有**日程名、课程名、地点、备注、计划标题、昵称、精确定位任何一项；抽样解密 3 份人工核对这些字段根本没进明文体；
- [ ] 云侧日志（含 `console.log`）**不打印** `code`、`confirmToken`、载荷内容、任何密钥或别名——密钥根本到不了云侧，所以这条查的是"有没有人顺手把解密逻辑加进来"；
- [ ] 没有"邀请历史"表：`code` 只在会话行上活到过期/撤销，撤销时被抹成空串（协议 §4.1、§6.1 第 4 条）；
- [ ] 快照只保留每 `pairId + ownerUid` 的**最后一个**版本（`PairSnapshot` 主键就是这两列，物理上存不下历史）。

审计发现任一违规 → 视同密钥泄露处理：批量撤销配对、通知用户重新配对，并在协议文档记录事件。

## 7. 待补（项目建起来后回来填）

- `[已填 2026-09-27]` 云工程落点 `E:/desktop/Code/harmony/FortwoCloud/CloudProgram/`，AGC 项目「两人份」
  （区域 CN）。**ID 一律不写进本文档**：`projectId` 本仓库与云工程一致；但两侧各有一个 19 位 `appId`，
  前缀相同而值不等——云工程绑的是向导示例应用 `com.common.fortwocloud`，不是产品包名 `com.common.fortwo`（§2.4 第 8 行）。
- `[已填 2026-09-27]` 超时**只能在 AGC 控制台改**，本地 `function-config.json` 里没有这个键（§2.4 第 3 行）。
  用户已改过一次 20s，但被随后的重新部署推回 60s，**现值 60s、待重设**（§1 第 7 步）。
  **内存与运行时未报变化**，按向导默认视作 500MB / `nodejs14.x`，以控制台为准。
- `[已填 2026-09-27]` 两轮部署时间：18:01（`this` 修复＋建区后复验，§2.4 第 12 行）、18:32（`inviteCode`
  改名那一版，§2.4 第 14 行；这一版由探针的行为证明两个云对象**都**已更新，不靠 `build/target/` 的目录数）。
  **[已核对 2026-09-27]，原"待核对"关闭**：18:32 那轮重新部署**确实**把手改的 20s 推回了向导默认 60s，
  控制台现值 60s。规则＝改配置必须放在最后一次部署之后；重设动作登记在 §1 第 7 步，不在这里重复。
- 配额水位的历史峰值（用于验证 §1 末的 0.01% 估算）；
- 真机上是否必须 `agconnect-services.json`（§1 末那条未验证边界）；
- 闲置回收预警的实际到达方式与响应流程（是否只有邮件）。
  > 顺带更正一处对心跳作用的误判（§3 表第 3 行，2026-09-27 U3b-1）：本手册曾把
  > "`pairing.heartbeat` 连续 7 天为 0"当成"心跳没接线、立刻修"的告警。实际上按协议 §4.6 的端侧口径，
  > **未配对的安装一条都不发**，所以这个计数器为 0 有两种完全不同的解释（档位没开 / 没人配对）。
  > 盯闲置回收请看"项目最后活跃时间"那一行，别拿心跳当探针。

**已可以删掉的待补项**：HUKS 路线 A/B 的实测结论（协议 §6 已定路线 A，但别名生命周期仍待测，
挂在协议 §11 第 5 项，不在本手册里重复登记）。
