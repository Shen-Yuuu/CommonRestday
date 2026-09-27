# 两人份 · 云侧工程（pairing / snapshot 云对象）

> 本目录是**云侧源码与部署说明的落档处**，不是可构建工程：这里没有 `CloudProgram/`、没有
> `cloud-config.json`、没有 `node_modules`。原因见改造文档 §0.3 与实验 #3 的结论
> （`SEPARATE_CLOUD_REPO`：多 HAR 扁平根目录不能直接挂向导产物，硬塞会污染 App 侧构建）。
>
> 线上契约的唯一事实源是 `docs/cloud/pairing-protocol-v1.md`。本目录只回答两个问题：
> **文件放哪儿**、**按什么顺序部署、怎么确认部署对了**。

## 1. 目录形态

```
cloud-backend/
├── clouddb/
│   ├── db-config.json                 # 区名 + 存储地（CN）
│   └── objecttype/{PairSession,PairSnapshot}.json
├── cloudfunctions/
│   ├── pairing/    contract.ts  pairing.ts  PairSession.js  PairSnapshot.js  function-config.json  package.json
│   └── snapshot/   contract.ts  snapshot.ts PairSession.js PairSnapshot.js  function-config.json package.json
└── tsconfig.check.json                # 仅类型检查用，不属于部署形态
```

`contract.ts` 与两份 `*.js` 对象类型文件在两个云对象目录里是**同一份字节的副本**：云对象部署包
只含自己那个目录，共享代码不能跨目录 import。副本一致性由 §4 的命令核对，不许手工只改一边。

## 2. 放置位置（一次配对流程要用到的复制动作）

前提：DevEco Studio 里对**正式应用**执行一次 `New > CloudProgram`，
向导会在工程根生成 `CloudProgram/`（含 `cloud-config.json`，里面是 projectId/appId/teamId）。
向导产物与凭据**永不进 git**，所以复制目标目录在仓库外。
`[实测 2026-09-27]` 实际落点是 `E:/desktop/Code/harmony/FortwoCloud/CloudProgram/`——
注意向导把示例**应用**也叫 `com.common.fortwocloud` 并把它绑进了 `cloud-config.json`，
与产品包名 `com.common.fortwo` 是同项目下的两个应用记录（运维手册 §2.4 第 8 行）。

复制对照：

| 来源（本仓库） | 目标（向导 `CloudProgram/`） |
|---|---|
| `clouddb/db-config.json` | `clouddb/db-config.json` |
| `clouddb/objecttype/*.json` | `clouddb/objecttype/` |
| `cloudfunctions/pairing/`（整目录） | `cloudfunctions/pairing/` |
| `cloudfunctions/snapshot/`（整目录） | `cloudfunctions/snapshot/` |

复制后在 `CloudProgram/` 里 `npm install`（会装 `@hw-agconnect/cloud-server@1.0.5`，版本已在
两个 `package.json` 里钉死），**不要**在本仓库目录下装依赖。

凭据边界（改造文档 §0.3、spike §1）：服务端凭据由 AGC 运行时注入（`PROJECT_CREDENTIAL`），
调试凭据是 `ForTwoPrivate/agc-apiclient-*.json` 之类文件，二者都只经由环境变量
（`AGC_CONFIG`）使用，**不放进展品目录、不入库、不回显**。

## 3. 部署顺序

0. **先删向导自带的样本，再部署**：`clouddb/objecttype/Post.json`、`clouddb/dataentry/d_Post.json`、
   `cloudfunctions/id-generator/`。`[实测 2026-09-27]` `Deploy Cloud DB` 是把 `objecttype/` **整个目录**推上去的，
   样本 `Post` 表因此一起上线，而它的 `permissions` 四个角色全是 `Read/Upsert/Delete`——
   同区里等于躺了一张公网可写表，`d_Post.json` 还会往里塞示例数据。
1. 右键 `clouddb` → **Deploy Cloud DB**（先建表和区，云对象一跑就要读写它们）；
2. 右键 `cloudfunctions/pairing` → **Deploy 'pairing'**；
3. 右键 `cloudfunctions/snapshot` → **Deploy 'snapshot'**。
4. `[实测]` 部署会在 `CloudProgram/build/target/<hash>/<对象>/` 留下 `<对象>.zip` 与 `template.yaml`，
   **后者就是线上描述符**（`runtime`/`timeout`/`memorySize` 都在里面）。但**别用它判断"部署过没有"**：
   每次部署新建一个 `<hash>` 目录、成功后删掉上一个，磁盘上永远只剩最后一次。要核对成败看 DevEco 日志
   （`idea.log` 里的 `DeployService - query deploy status response`，`"name"` 是对象名、`"reason"` 是结果）。
   在 AGC 控制台把 `runtime` 从向导默认的 `nodejs14.x` 改成 Node.js 20、`timeout` 从 60 改到 20
   （60s 同时撞穿"同步调用上限 55s"和端侧 30s 超时，会造成"客户端先断、服务端还在写"的假不一致）。
5. `[实测]` **`Deploy Cloud DB` 报 success ≠ 存储区存在**：本次三个云对象方法一读写库就是
   `2002037: CloudDBZone does not exist`，日志里 `createDataBaseResource` 先报 `206766192`
   （Failed to decode response body）再报 `206766200`（AuthenticationError），第三次"成功"其实只把
   对象类型/schema 登记上。所以下面 §6 的第 0 步必须先跑。

区名 `FortwoPair`：**不能含下划线**（AGC 实测报 `invalid CloudDBZone name`）。
`db-config.json` 里的 `defaultCloudDBZoneName` 只是向导显示值——spike 实测过该字段写着
`"default"` 而实际部署出的区叫 `FortwoSpike`，真正生效的是云对象 `createInstance(...).database({zoneName})`
里那个字符串（`contract.ts` 的 `ZONE`）。两处保持一致是为了不误导后来的人，不是为了生效。

## 4. 防漂移核对（改完云侧必跑）

```bash
# 4.1 三份副本字节一致
cd cloud-backend
for f in contract.ts PairSession.js PairSnapshot.js; do
  diff -q cloudfunctions/pairing/$f cloudfunctions/snapshot/$f || echo "DRIFT: $f"
done

# 4.2 类型检查（复用同级 spike 工程已装的 SDK 与 @types/node，见 tsconfig.check.json）
cd ..
node ../CloudDevSpikeOfficial/CloudProgram/node_modules/typescript/bin/tsc \
  -p cloud-backend/tsconfig.check.json
```

4.3 **参数顺序对照**：端侧 `cloud/src/main/ets/api/CloudApi.ets` 按**位置**传参，云端按位置收参，
所以方法名相同、顺序不同就是静默错位。逐条读一遍下表，任何一侧改动都要同时改另一侧并升 `schemaVersion`：

| 端点 | 位置参数（两侧必须完全一致） |
|---|---|
| `pairing.create` | `uid, publicKey, schemaVersion` |
| `pairing.join` | `code, uid, publicKey, schemaVersion` |
| `pairing.confirm` | `pairId, uid, confirmToken` |
| `pairing.status` | `pairId, uid` |
| `pairing.unpair` | `pairId, uid, requestId` |
| `pairing.heartbeat` | `uid, pairId` |
| `snapshot.put` | `pairId, ownerUid, version, shareLevel, envelope, requestId` |
| `snapshot.get` | `pairId, uid, sinceVersion` |

`envelope` 是 `{schemaVersion, algorithm, iv, authTag, ciphertext}` 五个字段的名字段。

4.4 **包络保留名**：`code`、`message`、`retryable`、`serverTime` 四个键是响应包络的，**业务字段不得占用**。
`ok()` 现在把四键放在合并**之后**钉死，所以同名不再顶掉语义码，但会静默丢掉业务字段——两种都是事故。
新增回包字段前先对照这张表；顶不掉不等于不冲突，端侧按名字取值，冲突要在设计期消掉。

| 保留名 | 占用者 | 曾经的事故 |
|---|---|---|
| `code` | 语义码（`OK`/`BAD_REQUEST`/…） | `sessionBody` 把 6 位邀请码放在 `code` 里，`code:"OK"` 被数字串顶掉，端侧 `unwrap()` 把每一次成功 `create` 判成失败 ⇒ 报文键改名 `inviteCode`（库里列名不变），协议 §3.2 |

## 5. 四条会影响部署成败的写法约束

1. **导出方法签名里不得出现第三方类型。** DevEco 的接口生成脚本 `analyzeDependency()` 会顺着
   handler 的 `.d.ts` 引用链检查导入，一旦发现 `@hw-agconnect/...` 就打印
   `Dependency Error! Can not have third-party dependencies!` 并 `process.exit(100)`，部署直接失败。
   所以 SDK 只在函数体内使用，返回类型一律 `Promise<Record<string, Object>>`，
   数据库句柄走 `contract.ts` 里本地定义的结构化接口（`QueryLike/CollectionLike/ZoneLike`）。
2. **String 字段硬限 200 字符**（Server SDK 的 `MAX_STRING_LENGTH`），Base64 密文远超此值，
   所以 `PairSnapshot.ciphertext` 的字段类型必须是 `Text`；否则写 2 MB 内的合法载荷会撞
   `2060 WRITE_STRING_VALUE_SIZE_EXCEED_LIMIT`。
3. **对象类型 JSON 与 `*.js` 模型字段必须逐字对齐**（名字、类型、主键、notNull）。
   不一致时的表现是读回 `undefined` 或写库报字段不存在，而不是编译错误。
   `getIndexList()` 返回 `[]` 是有意的：SDK 只对它做 `typeof` 检查，真正的索引在 objecttype JSON 里。
   `PairSession` 上 `code`、`creatorUid` 两个非主键列建了索引，因为服务端按它们做 `equalTo` 查询；
   `pairId` 是主键，不需索引。`PairSnapshot` 只有"按主键读写"的用法，故 `indexes: []`。

4. **公开方法里不许出现 `this`。** `[实测 2026-09-27]` 云对象框架按 `func.apply(?, data.params)` 派发，
   方法是被**从实例上摘下来**调起来的，所以 `guarded(() => this.doPut(...))` 每一次调用都在读库之前抛
   `Cannot read properties of undefined (reading 'doPut')`，最后塌成
   `{"code":"INTERNAL","message":"cloud error "}`（尾部没有 dbCode，判据见 §6 第 0.5 步）。
   向导样本 `IdGenerator.randomUUID()` 一个 `this` 都不碰，所以这个坑要到第一次真调用才露头。
   写法：公开方法只留一行转调，业务函数放**模块级**（`pairing.ts` / `snapshot.ts` 已按此收口）。
   编译器不会报，运行期才炸——所以改动后要做一次 detached 复核：把编译产物 require 进来，
   用 `Pairing.prototype.heartbeat.apply(undefined, ['<十六进制形态 uid>',''])` 调，
   期望 `{"code":"OK","paired":false}`；如果回空 dbCode 的 `INTERNAL`，就是新写了依赖 `this` 的路径。

## 6. 首次部署探针

第 0 / 0.5 步**不需要设备**，在 Node 里用服务端凭据直连就能跑完；第 1–3 步要读写库，
所以必须等存储区建好，在 DevEco 的 Node 侧或端上调一次即可。

**第 0 步 · 存储区存在性**：用服务端凭据对 `contract.ts` 里的 `ZONE` 发一次空查询。
拿到 `2002037: CloudDBZone does not exist` ⇒ 区没建，走 `docs/cloud/operations-runbook.md` §4.7，
**后面三步全都会失败，先别往下跑**；拿到 401/403 类 ⇒ 凭据或项目错配，也先解这个。

**第 0.5 步 · 云对象入参形态 + this-free（免设备）**：`@hw-agconnect/cloud-server` 在 Node 里可以直接把
已部署的云对象调起来，所以"形态对不对""handler 有没有依赖 `this`"这两件事不用等真机、也不用等区建好——
选的都是不碰 CloudDB 的分支（`heartbeat` 明确不查库；其余用畸形入参让它在读库前就返回语义码）。

```js
// 凭据只经 AGC_CONFIG 传路径，输出里不出现其内容
const { cloud, Region } = require('@hw-agconnect/cloud-server'); // 从 CloudProgram 下的目录 require
const fn = cloud.createInstance(process.env.AGC_CONFIG, 'fortwo-fnprobe', Region.REGION_CN).function();
await fn.call({ name: 'pairing', version: '$latest', timeout: 30000,
  data: { method: 'heartbeat', params: ['abcdef01-2345-6789-abcd-ef0123456789', ''] } });
```

探针值必须长成 `isUid` 认的样子（`/^[0-9a-fA-F-]+$/` 且 8..128 位）：用 `probe000-…` 这种含
非十六进制字母的串会得到 `BAD_REQUEST`，那是"值不合法"而不是"参数送到了"的证据，会把两件事混成一团。

判读（每一行都指向不同处置，别合并）：

| 回包 | 结论 |
|---|---|
| `code:"OK"`（heartbeat 正常）或 `BAD_REQUEST`/`SCHEMA_UNSUPPORTED` 等语义码 | 形态成立、handler 不依赖 `this`，可以往下 |
| `Call handler error: cloud object method is empty` | `data` 里漏了 `method`——框架自己解析它 |
| `Can't find cloud object method X` | 方法名与 `function-config.json` 的 `handler` 对不上 |
| `code:180000` + `CreateListFromArrayLike called on non-object` | `params` 不是数组（它是按位置 `func.apply` 展开的） |
| `INTERNAL` 且 `message` 尾部**带** dbCode（如 `cloud error 2002037`） | 云对象是好的，问题在库/区/权限，回第 0 步与 §4.7 |
| `INTERNAL` 且 `message` 尾部**空**（就是 `"cloud error "`） | 抛的是没有 code 的 JS 异常，读库之前就炸了 ⇒ §5 第 4 条 / §4.8 |

`[实测 2026-09-27]` 这一步已经把 `{method, params}` 这条端侧契约在线上证实（与
`build/cache/CloudObjectInterface.js` 里 ImportObject 模板发的 `data: {method: prop, params: args}` 一致），
所以形态对不上时**不要**改端侧 `CloudApi.ets` 去迁就，先核对云端。

**第 1 步 · 分派形态（要读库）**：`call({name:'pairing', data:{method:'create', params:['<uid>','<pubkey>',1]}})`
→ 期望 `code:"OK"` 且回包里带 6 位 `code`。`INTERNAL`/空包按上表分流。

**第 2 步 · getter 读回**：紧接着用回包的 `pairId` 调 `status` → 期望 `status:"WAITING"`、
`peerUid` 为空串。这一步证明 `contract.ts` 的 `toSession()` 用 getter 取值这条路是对的
（`query().get()` 返回的是模型实例，不是普通对象）。
顺带这一步也是 **Node 运行时版本的探针**：`newSessionRow`/`confirmToken` 用了
`crypto.randomUUID()`（≥14.17）、`crypto.randomInt()`（≥14.10）、`Buffer.toString('base64url')`（≥14.18），
向导默认给的 `nodejs14.x` 只要落在 14.17 以下，`create` 就会以 `INTERNAL` 冒出来——
这时先查运行时版本，别去怀疑加密口径。

**第 3 步 · Text 列写入**：`snapshot.put` 塞一份超过 200 字符的假密文（`ACTIVE` 会话下）→ 期望
`storedVersion` 回显；报 `2060` 就是 §5.2 那条字段类型没生效。

探针用完执行 `unpair` 清掉会话与快照，别在正式项目里留测试行。

## 7. 已知缺口（实施时别当成已完成）

| 项 | 现状 | 影响 |
|---|---|---|
| `pairing.heartbeat` | 云端已实现，**端侧无调用点**（`AgcPairingClient.heartbeat` 没有使用方） | 6 个月无调用会触发 AGC 闲置回收预警（docs/05 §3.2）。要在 U3b 冷启动 + 每周定时器里接上 |
| `requestId` | 只回带用于日志对齐，**未参与幂等判定** | 实际幂等由"`(version, iv, ciphertext)` 三者相同即重放"和"删除是收敛操作"达成。协议 §3.3 的措辞已按此修正 |
| `uid` 自证 | 云对象拿不到可验证的用户身份，谁是成员以参数声明为准 | 冒充一个 `pairId` 最多读到密文（读不到日程），代价是 §6.1 的残余风险条目，不是实现缺陷 |
| `CONFLICT_VERSION` | 服务端按 §7 拒绝版本回退 | 端侧 `nextSnapshotVersion()` 单调递增、`pushMySnapshot` 失败只记日志，所以表现为"后推的赢"，不会卡死 |

## 8. 与端侧的关系

端侧只认三样东西：`{method, params}` 的调用形态、§3.2 的包络、§3.4 的语义码。
`docs/cloud/operations-runbook.md` 记的是运维与配额侧的操作路径；本文件记的是"代码放哪、
怎么部署、怎么证明部署对了"。二者都不进包体。
