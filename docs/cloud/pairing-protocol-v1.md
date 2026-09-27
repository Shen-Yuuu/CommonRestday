# 配对与加密快照协议 v1（已实现，已开闸）

> 状态：**端侧与云侧源码均已落地，2026-09-27 开闸批把产品开关打开了。**
> 落点：端侧 `cloud/src/main/ets/api/`（HUKS 密钥托管 + 传输层）与 `feature` 的配对状态机；
> 云侧 `cloud-backend/`（`pairing` / `snapshot` 两个云对象 + CloudDB 对象类型），部署步骤见其 README。
> `FeatureFlags.cloudPairing` 已为 `true`，与 `ohos.permission.INTERNET`、隐私政策 v1.1
> （全文 + 首启摘要 + 权限用途说明）**同批**出入包，回退方式见 `docs/release/rollout-and-rollback.md` §3.3/§5。
>
> **本文的"已实现"只到代码层**：§11 的实测清单要在开闸后的双设备现场勾，一条都不许凭推断打勾。
> 改协议 = 改本文并升 `schemaVersion`，不允许在代码注释里另立口径。
> **当前 `schemaVersion` = 2**（2026-09-27 从 1 升位，原因见 §3.2 的保留名规则）。
> 它和标题里的"v1"是两个数：v1 是这份文档的版本，`schemaVersion` 是报文里的兼容位。
> 与实际实现不符的地方，以本文为准（本文按实现回写；若二者冲突，先停下来查是哪一侧漂了）。

## 1. 云端承担什么、不承担什么

云端只做两件事：**配对会话**与**加密快照中转**。它不是主库。

| 事实源 | 归属 | 云端角色 |
|---|---|---|
| 班表/课表/循环模板/单日覆盖/计划 | 本机 RDB | 只存"降维后的加密快照"，不存原始数据 |
| 共同时间窗口计算 | 本机 `domain` 引擎 | 云端不参与计算，也不缓存计算结果 |
| 配对状态（本机 `NONE/WAITING/PENDING_CONFIRM/PAIRED` ↔ 云端五态，§8） | 双方各存本机 + 云端会话记录 | 云端是会话生命周期的唯一仲裁者（过期、撤销都只由它宣布） |
| 长期密钥 | **只存在于 HUKS 安全环境** | 云端永不得到密钥明文，因而读不到载荷 |

三条不可让步的边界（来自改造文档 §0.3 与 spike §4 门禁规则）：

1. **邀请码不得直接作为长期快照密钥**，也不得用 `SHA256('crd-v1:' + code)` 这类短码派生长期密钥；
2. **长期密钥不得写入 Preferences、源码、二维码或日志**——Preferences 里只允许存 HUKS **别名**；
3. **云端任何失败都不得阻断本机**：拉取失败、超时、401/403/404、配额用尽一律降级为"沿用最后一次有效快照或本机代录"。

## 2. 标识与凭据

| 名称 | 形态 | 生成方 | 可见范围 | 说明 |
|---|---|---|---|---|---|
| `uid` | 36 位 UUID 字符串 | **本机**（`SettingsStore.getOrCreateUid()`） | 云侧明文、双方本机 | 这台设备在这个配对里的身份别名。**不是云端分配的**——AGC 云对象给不出可验证的用户身份（§6.1 第 1 条），所以它是端侧自证的一个随机串。非个人信息，但**一旦公布就无法再改**：换 uid 等于换一个人 |
| `pairId` | 云端生成的 UUID | 云端（`create` 返回） | 云侧明文、双方本机 | 快照的分片键与权限键；Preferences 可存，别名由它现推（§6） |
| `code` | 6 位数字，**短期凭据** | 云端 | 用户之间口头/分享传递 | 只能用于 `pairing.join`，有 TTL，用过即废（§6.1 第 4 条）。**库列名 `code`，报文里叫 `inviteCode`**（`code` 是包络保留名，§3.2）；`pairing.join` 的**请求**仍按位置传它 |
| `confirmToken` | 32 字符 base64url（**无 `=` 填充**） | 云端（`join` 时生成） | 只给加入方，再由它经安全信道交回发起方 | 一次性：`confirm` 成功即从库里抹掉（§4.3）。长度落在端侧 `PairLink.tokenValid` 的 22–128 白名单里 |
| 长期密钥 | 256-bit | **HUKS 会话协商派生**（§6） | 只在两端 HUKS 内 | 以别名 `crd-pair-<pairId>` 引用，密钥材料不出安全环境；因此**它压根不是协议字段**——不进请求、不进响应、不进数据库列，也不进日志 |
| `version` | 单调递增整数 | 客户端（每台自己维护） | 云侧明文 | 乱序判定用；幂等靠载荷比对而不是它（§3.3、§7） |

`code` 与长期密钥的关系是**单向且经过 HUKS 协商**的：拿到 `code` 不能算出密钥——密钥由双方
**公钥**做 ECDH 得出，公钥在 `create`/`join` 里各带一份（§4.1–4.2），`code` 只是"允许你进这个会话"的门条。
`code` 泄露的最坏后果是"在 24 小时 TTL 内被人抢一次配对位"，而不是历史快照被解密。
这是本协议与旧原型（`SHA256('crd-v1:' + code)` 当密钥）的唯一实质区别。

## 3. 通用包络

### 3.1 传输形态与请求

端云之间**不是** HTTP 端点，而是两个云对象：`pairing`（create/join/confirm/status/unpair/heartbeat）
与 `snapshot`（put/get）。调用体固定为：

```jsonc
// cloudFunction.call({ name: <对象名>, version: '$latest', timeout: 30000,
//   data: { method: <方法名>, params: [按位置排列的参数] } })
{ "method": "join", "params": ["480213", "3f2a…-…-…（本机 UUID）", "<base64 公钥>", 1] }
```

这条形态是从 DevEco 的接口生成脚本里读出来的（它生成的 `ImportObject` 代理就是
`data: {method: prop, params: args}`），不是猜的。由此产生一条比字段名更硬的约束：
**参数的顺序与个数就是线上契约**，方法名对了但顺序错了不会报错，只会静默错位。
逐条对照表在 `cloud-backend/README.md` §4.3，改任何一侧都要同步另一侧并升 `schemaVersion`。

因此本协议**没有**统一请求骨架：`schemaVersion` 只在 `create`/`join` 上作为位置参数传，
`requestId` 只在 `unpair`/`snapshot-put` 上传，且当前只用于日志对齐（§3.3）。
`sentAt` 从未实现，已从协议里删除——服务端一律以自己的时钟为准（`serverTime`）。

### 3.2 响应

```jsonc
{
  "code": "OK",               // 语义码，见 §3.4；成功恒为 "OK"
  "message": "",              // 面向日志的英文短语，不进 UI 文案
  "retryable": false,         // 客户端是否值得退避重试
  "serverTime": 1767225601234,// 服务端毫秒时间戳，客户端据此校准 TTL 判定
  "requestId": "uuid-v4",     // 仅 `unpair` / `snapshot-put` 回带，用于日志对齐
  // ...端点自有字段
}
```

**`code` / `message` / `retryable` / `serverTime` 是包络保留名**，端点自有字段不得占用同名键。
云侧 `ok()` 在合并业务字段**之后**才钉这四个键，所以撞名的业务字段会被静默丢掉而不是顶掉成功判定——
被丢掉的那一份要靠探针断言查，别指望它报错。
这条规则是 `schemaVersion` 1→2 的唯一原因：`pairing.create` 的邀请码原本就叫 `code`，
与语义码撞名之后 `code:"OK"` 被 6 位数字顶掉，端侧 `unwrap` 把每一次配对都判成失败
（`[实测 2026-09-27]`，见 `docs/cloud/operations-runbook.md` §2.4 第 13 行）。字段改名 `inviteCode` 后，
库里那一列仍叫 `code`，只有报文名变了。

### 3.3 超时与重试

- 客户端调用**必须显式传 `timeout: 30000`**。`FunctionParams.timeout` 的 SDK 默认值是 70×1000ms，而云函数同步调用侧上限是 55s，不传就会在慢请求上撞墙（spike §1 已核）。
- **函数超时必须是 20s，而这条约束目前没在生效状态**。`[实测 2026-09-27]` 本地 `function-config.json` 里
  无 `timeout` 这个键、改不了，值写死在 IDE 插件里（runbook §2.4 第 3 行），只能在 AGC 控制台设；
  控制台一度被手动设为 20s，但**随后的一次重新部署又把它推回了向导默认的 60s**（runbook §2.4 第 14 行）。
  **[已坐实]** 重新部署＝按服务端模板重生成部署描述符，手改的运行期配置不跨部署存活。
  **函数超时必须小于端侧 30s**：这样先断的一定是服务端，端侧拿到的是一个**语义回包**而不是自己那侧的超时。
  **当前 60s > 30s，这条不变式是破的**，要说清破了之后坏在哪一层：
  - **不会写坏数据**。快照是本人班表的全量降维投影、版本是本机单调游标、冲突处置是"后推的赢"（§7），
    所以"端侧已断但服务端已写入"最坏只是**多一个版本号被用掉**，下一次保存带着更高版本照常推上去；
  - **坏的是失败语义**。慢请求在 30s 处端侧抛 `NETWORK`/`LOCAL`，而服务端那一版可能已经落库，
    界面于是显示"网络不好，待重试"（假失败）。更要紧的是配额类失败：`QUOTA_EXCEEDED` 本应带
    `retryable=false` 让端侧**当天不再重排**（§7 末行），超时抢先发生就把它压成了一次普通网络失败，
    当天的降级判断与文案都跟着错——这才是必须把函数超时压到 30s 以内的真实理由。
  处置＝**在最后一次云端部署之后**再去控制台把两个对象改成 20s，之后不得再部署；
  任何一次重新部署都必须重设。这条已进 runbook §1 前置清单与 §7 待补。
- **端侧没有自动退避重试循环**，这是实现选择不是遗漏：`retryable` 只决定文案（"今天同步已用完"vs"网络不好"）以及当天是否还重排，真正的再试由 §7 的触发时机（回前台、保存、进入共同时间）自然带起。给一个静默重试循环等于把配额烧在用户看不见的地方。
- **幂等不是靠 `requestId` 达成的**（那是本节此前的说法，与实现不符，现已改成实现口径）：
  - `snapshot-put`：同 `version` 且 `iv` + `ciphertext` 完全相同 → 判为重放，返回首次的 `storedVersion`；同 `version` 但载荷不同 → `CONFLICT_VERSION`；
  - `pairing-unpair`：删除是收敛操作，会话行已不存在也返回 `OK` + `deletedVersions = 0`；
  - `pairing-confirm`：已 `ACTIVE` 时重放返回同一结果。
  `requestId` 保留在参数里，作用是让 AGC 日志能把一次端侧重放和它的两次服务端写入对上号。
- 不做后台常驻、不做定时轮询以外的唤醒（改造文档 §0.3）。

### 3.4 语义码

| `code` | `retryable` | 客户端动作 |
|---|---|---|
| `OK` | — | 正常 |
| `BAD_REQUEST` | false | 记缺陷，降级，不重试 |
| `UNAUTHORIZED` | false | 视为未配对：清 `pairId` 引用、保留本机数据、提示重新配对 |
| `FORBIDDEN` | false | 同上（安全规则拒绝，含"第三设备访问"） |
| `NOT_FOUND` | false | 会话不存在/已被级联删除 → 本机回到 `UNPAIRED`，数据不删 |
| `CODE_EXPIRED` | false | 邀请码过期：提示重新生成 |
| `CODE_TAKEN` | false | 邀请码已被使用：提示重新生成 |
| `CONFLICT_VERSION` | false | 版本回退：丢弃本地待发快照，改为拉取 |
| `SCHEMA_UNSUPPORTED` | false | 端云版本不匹配：提示升级 App，禁止静默降级写入 |
| `QUOTA_EXHAUSTED` | true | 停止本轮同步，提示"今天同步已用完"，本机功能不受影响 |
| `TIMEOUT` | true | 退避重试 |
| `INTERNAL` | true | 退避重试 |

客户端把上述映射收敛为现有的 `CloudApiError`，UI 只消费"已同步 / 待重试 / 已降级"三态。
这一句已落地（U3b-3）：`feature/model/CloudSyncRules.ets` 是唯一的判定与措辞来源，落库形态是
`SettingsStore` 的 `cloud_sync_state` 一条字符串（`结论|日序|语义码`，处置口径见 §7 末行与 §9 第 8 条）。
第三态在端上分成两种结论——`RETRY`（retryable，只压当天）与 `BLOCKED`（不可重试，压到某次云往返
重新证明通路为止），界面上分别念作「云同步待重试」与「云同步已停止」（"降级"是工程词，用户听不懂）。
把它们合成一句就等于向一个不会自愈的失败承诺"明天会自动恢复"。

两点与表格字面不同的实现口径：

- `TIMEOUT` 与传输层失败是**端侧自己归类**的（`NETWORK` = 1008210001，`LOCAL` = 201/1008210009，
  `INTERNAL` = 解包失败），服务端从不产 `TIMEOUT`——一个已经超时的请求不会再有服务端回包；
- 服务端目前**不产 `UNAUTHORIZED`**：AGC 云对象这一路给不出可验证的用户身份（§6.1），
  非成员访问一律以 `FORBIDDEN` 表达。端侧仍把 401/403 字样的传输层拒绝还原成 `UNAUTHORIZED`，
  因为那是网关在请求到达云对象之前挡下来的形态。

## 4. 端点（8 个方法 / 2 个云对象）

`pairing` 云对象承载 §4.1–§4.6，`snapshot` 云对象承载 §4.7–§4.8。响应列里的字段都出现在
§3.2 包络的同一层（扁平，不再嵌一层 `data`）。

调用方身份**由参数声明**：AGC 云对象这条路给不出可验证的用户 uid（§6.1），所以下文凡写
"必须是成员"的地方，实现都是"参数里的 uid 出现在会话的 creatorUid/joinerUid 列里"。

### 4.1 `pairing.create`

发起方生成配对码。

| 请求（位置参数） | 响应 |
|---|---|
| `uid`、`publicKey`、`schemaVersion` | `pairId`、`inviteCode`、`status=WAITING`、`peerUid=""`、`peerPublicKey=""`、`expiresAt`、`serverTime` |

- `inviteCode`（报文名；库列名 `code`，见 §3.2 保留名规则）由**云端**生成（6 位数字，`crypto.randomInt`），端侧 `generateInviteCode()` 那条上传路径已删除；
- `publicKey` 是发起方 HUKS 身份别名下的公钥（不透明 base64，云端不解析、不校验曲线）；
- **重复调用的语义是"整轮重来"**：该 uid 名下所有未完成（`WAITING`/`PENDING_CONFIRM`）会话当场转
  `REVOKED` 并新建一行，因此 `pairId` 会换。原设计写的"复用未过期会话、返回同一 `pairId` + 新码"
  没有实现，理由是复用要"改码不改行"的读改写，而一旦旧链接还挂在对方手里，同一个 `pairId`
  就会同时存在两张码和两个候选加入方——状态机反而更含糊。**`ACTIVE` 会话不受影响**：
  换机重装或误点"重新生成"不该拆散已经配对的一对；
- `ttlSeconds` 未实现：`expiresAt` 已是服务端绝对毫秒，间隔常量固定 24 小时（`SESSION_TTL_MS`），
  再回一个秒数是给端侧多一个会漂的口径。

### 4.2 `pairing.join`

加入方凭码入会。

| 请求（位置参数） | 响应 |
|---|---|
| `code`、`uid`、`publicKey`、`schemaVersion` | `pairId`、`status=PENDING_CONFIRM`、`peerUid`（=发起方）、`peerPublicKey`、`confirmToken`、`expiresAt`、`serverTime` |

- 一次 `code` 只允许一个加入方（第二人 `CODE_TAKEN`）；
- **响应里没有 `creatorUid` 这个字段名**：对端一律以 `peerUid` 给出（加入方拿到的是发起方，
  发起方拿到的是加入方），端侧不需要知道自己在那一行里；
- `confirmToken` 在这一步由云端生成并**只发给加入方**：32 个 base64url 字符（无 `=` 填充），
  满足端侧 `PairLink.tokenValid` 的 22–128 字符白名单，可以直接进分享链接；
- 加入后**不得立即视为已配对**，也不得立即写任何快照——必须等 §4.3；
- `expiresAt` 在这里**重置为"加入时刻 + 24 小时"**：确认这一步也要时间窗，而不是沿用剩下半截的
  建码窗口；
- 同一加入方用同一张码重进（换手机、清过界面）走幂等重放，把凭据再给一次；
- 加入方在此步完成 HUKS 密钥协商的本地准备（§6），协商用 `peerPublicKey`。

### 4.3 `pairing.confirm`

发起方交回凭据后确认，会话转 `ACTIVE`。

| 请求（位置参数） | 响应 |
|---|---|
| `pairId`、`uid`、`confirmToken` | `status=ACTIVE`、`peerUid`、`peerPublicKey`、`expiresAt=0`、`serverTime` |

- `confirmToken` 是 §4.2 下发给加入方、再由加入方通过任意安全信道（二维码/系统分享）交回发起方的一次性凭据；
- **只有发起方能确认**：`roleOf(uid) !== 'creator'` 直接 `FORBIDDEN`。加入方确认等于绕过本节；
- 一次性：**转 `ACTIVE` 的同时把库里的 `confirmToken` 清空**，重放同一份链接不再有副作用。
  幂等重放仍然成功（已 `ACTIVE` 时返回同一状态），但靠的是状态判断而不是留着的那枚凭据；
- `ACTIVE` 之后 `expiresAt` 归零（会话不再到期，只被 §4.5 或闲置回收终止），**没有 `pairedAt` 字段**：
  行里有 `createdAt`/`updatedAt`，但对端不需要第三个时间戳；
- 对方还没加入（`WAITING`）→ `BAD_REQUEST`；这轮已被新码顶掉（`REVOKED`）→ 同；过期 → `CODE_EXPIRED`。

### 4.4 `pairing.status`

任一侧查询会话状态，用于打开「我的 · 伴侣与同步」时的对账。

| 请求（位置参数） | 响应 |
|---|---|
| `pairId`、`uid` | `status`（`WAITING/PENDING_CONFIRM/ACTIVE/EXPIRED/REVOKED`）、`peerUid`、`peerPublicKey`、`expiresAt`、`serverTime` |

- **只读端点不得返回 `confirmToken`，也不得返回 `inviteCode`**。原设计的响应里有 `confirmToken`，
  那等于把"任何一侧轮询一次状态就能自己完成确认"的口子留在协议里；邀请码同理，
  它是仍可被第三次设备使用的凭据，不该在配对完成后还能从任何读路径拿到；
- 只有成员能查（非成员 `FORBIDDEN`，会话不存在 `NOT_FOUND`）；查到过期时服务端顺手落一次
  `EXPIRED`，让"过期"这个事实只有一份；
- `peerShareLevel` / `peerVersion` **未实现**：对方的档位与版本随快照信封到达（§4.8），
  在状态端点里重复一份就是两个事实源。对账只看 `status` 与 `peerUid`；
- `EXPIRED/REVOKED` 时客户端把本机状态收回 `UNPAIRED` 并**保留全部本机数据**（含对方代录数据）。

### 4.5 `pairing.unpair`

解除配对，**级联删除云侧该 pair 的全部快照**。

| 请求（位置参数） | 响应 |
|---|---|
| `pairId`、`uid`、`requestId` | `deletedVersions`（删除的快照行数）、`requestId` |

- 任一成员发起即整对解除（本产品的双人语义）；
- 云侧删除是硬删除，**顺序固定为先删快照、再删会话行**：反过来一旦中途失败，就成了
  "没有成员可验证、又查得到密文"的孤儿行；
- 成员关系存在会话行里（`creatorUid`/`joinerUid` 两列），没有独立成员表可删——
  原设计写的"同时删除成员表"就是删这一行；未过期的 `code` 随行一起消失；
- 本机：删除 HUKS 协商别名（密钥材料随之消失），清 `pairId`，保留本机 RDB 数据；
  身份别名 `crd-id-<uid>` 留着，下一轮配对还要用同一把公钥；
- 幂等：会话已不存在返回 `OK` + `deletedVersions = 0`（不返回 `NOT_FOUND`）。

### 4.6 `pairing.heartbeat`

轻量存活信号，用于避免 AGC 把项目判为闲置资源（docs/05 §3.2：连续 6 个月无有效调用 → 预警 30 日后回收）。

| 请求（位置参数） | 响应 |
|---|---|
| `uid`、`pairId`（未配对传空串） | `paired`、`serverTime` |

- **不携带任何载荷数据，不查库也不写库**：这条调用的频率由"项目快被回收了"决定，不由业务决定，
  任何一次读都是白付的配额。`pairId` 只用于日志对号，未配对时传空串是合法的存活信号；
- `projectLastActiveAt` **未实现**：AGC 没有把这个项目级时间戳暴露给云对象，返回它只能是服务端自己
  伪造的一份数据。防回收要看的是 AGC 控制台的资源状态，不是这个字段；
- 由冷启动与"每周一次"的定时器各发一次即可。
  > **[已接线，2026-09-27 批次 U·U3b-1] 但没有定时器，且只在已配对时发**。端侧实现是
  > `ProfileSettingsService.beatIfDue()`，挂在 `EntryAbility.onForeground` 的初始化链尾：
  > 本项目**不建常驻、不起定时器**（§3.3 与 §7 的硬约束），所以"每周一次"落成一个**节流窗口**
  > （`HEARTBEAT_WEEK_MS = 7d`）而不是闹钟——整机不用应用就不跳，代价由 25 倍余量吸收（7d 对 6 个月）。
  > 判定与发送分开（`heartbeatDue(pairId, lastBeatAt, now)` 是纯函数），因为设备侧改不了系统钟
  > （`hdc shell` 无 root，`date -s` 回 `Operation not permitted`），"隔一周"和"时钟回拨"这两格
  > 在真机上属于撞运气，权威覆盖只能离线断言（同 D-39 `greetingOf` 口径）。
  >
  > **此处比本节上面那句"未配对传空串是合法的存活信号"更窄，是有意的**：未配对（本机 `pairId` 为空）
  > 一次都不发。理由是配额与足迹——免费档的按天配额是**项目级共享**的，让每一台从没配过对的安装
  > 每年替项目交 52 次"保护不了任何东西"的调用，挤的正是快照同步的真配额；而"整个项目 6 个月零调用"
  > 等价于"没有任何配对用户在用"，那是一次应当由 owner 在 AGC 的 30 日预警里**看见并决定**的事，
  > 不该由代码静默兜掉。副作用要记住：**防回收的信号强度取决于有多少已配对用户在活跃**，
  > 单人态安装对云端贡献为零（§11 第 8 条因此只能拿 paired 态测）。
  > 失败只 `Logger.warn`，不落游标也不排重试：漏一跳下次回前台补，重试风暴则会把当天配额吃光，
  > 反过来把真同步挤成 `QUOTA_EXHAUSTED`。

### 4.7 `snapshot.put`

写入自己的加密快照。

| 请求（位置参数） | 响应 |
|---|---|
| `pairId`、`ownerUid`、`version`、`shareLevel`、`envelope`（§5.1 的五个字节字段）、`requestId` | `storedVersion`、`requestId` |

判定顺序就是下面这条顺序，它决定了客户端看到哪个语义码：

1. 会话不存在 → `NOT_FOUND`（端侧回 `UNPAIRED`，数据不删）；
2. `ownerUid` 不是成员 → `FORBIDDEN`；
3. 会话不是 `ACTIVE` → `BAD_REQUEST`（还没确认就推快照 = 状态机被绕开，属端侧缺陷）；
4. `envelope.schemaVersion !== 当前 SCHEMA_VERSION`（现在是 `2`）→ `SCHEMA_UNSUPPORTED`，**禁止静默降级写入**；
5. `algorithm !== 'AES-256-GCM'`、`iv`/`authTag`/`ciphertext` 任一为空、`version <= 0`、
   `shareLevel` 不在 0–3 → `BAD_REQUEST`；
6. Base64 长度换算后超过 2 MB → `BAD_REQUEST`（阈值按**字符串长度**算，因为计费与列上限都在字符串上；
   端侧真实量级是几十 KB，2 MB 是格式余量不是业务余量）；
7. `version` **小于**已存版本 → `CONFLICT_VERSION`；**等于**已存版本且 `iv` + `ciphertext` 完全相同
   → 判为同一份的重放，返回 `OK` + 原 `storedVersion`；等于但载荷不同 → `CONFLICT_VERSION`。

- 服务端只存信封字节，**不解密、不解析明文、不看日程内容**（§5.2 的明文列清单是它能看到的全部）；
- 覆盖写：每个 `pairId + ownerUid` 只保留**最后一个**快照（历史版本无用途，少存一份是一票收益的隐私改进）；
- 行上的 `peerUid` 由服务端按会话解析后写入，客户端传不进、也不需要传。
- `updatedAt` 未在响应里回带：它由服务端时钟写进行里，客户端下一次 `get` 自然拿到；
  在响应里再回一次等于给同一件事两个值。

### 4.8 `snapshot.get`

拉取对方的快照。

| 请求（位置参数） | 响应 |
|---|---|
| `pairId`、`uid`、`sinceVersion` | `snapshot`（§5.1 信封对象；无更新时**该字段缺席**）、`serverTime` |

- **`peerUid` 参数已删除，改为必须传调用方自己的 `uid`**：一个 `pairId` 下有两行快照（每人一行），
  服务端只有拿到"调用方是谁"才知道对方是哪一行，也才谈得上成员校验。少了它就只能要么全给、要么放弃鉴权。
  对端语义仍由服务端解析——客户端不需要知道对方 uid 的值；
- 会话不存在 → `NOT_FOUND`；非成员 → `FORBIDDEN`；对端还没推过快照、或
  `version <= sinceVersion` → `OK` 且不带 `snapshot` 字段（无更新是常态，不是错误）；
- **没有云数据库安全规则这回事**（原设计的 `request.auth.uid == resource.ownerUid || …` 表达式
  在 CloudDB 的 Server SDK / objecttype 形态下不存在）。实际防线是两层：
  `PairSnapshot` 的 `permissions` 四个角色全空（World/Authenticated/Creator 无任何权利，
  Administrator 才有 Read/Upsert/Delete），所以**端侧直连云数据库读写不到任何东西**；
  一切读写都必须穿过 `snapshot` 云对象，由它做 §4.7/§4.8 的成员与状态判定。
  这条是实测口径而非推定：spike 用匿名认证直连同一张表就是拿到 `2001015: permission denied`。

## 5. 快照对象与加密信封

### 5.1 信封（云侧存储单元）

```jsonc
{
  // ↓ 这四个是 snapshot.put 的位置参数，不在 envelope 里
  "pairId": "9f1c…（云端 UUID）",
  "ownerUid": "3f2a…（本机 UUID，列名叫 ownerUid）",
  "version": 17,
  "shareLevel": 2,
  // ↓ envelope 对象的五个字段（唯一进信封的部分）
  "schemaVersion": 1,
  "algorithm": "AES-256-GCM",
  "iv": "base64(12B)",
  "authTag": "base64(16B)",     // 独立字段，不再拼进 ciphertext
  "ciphertext": "base64(...)",
  // ↓ 服务端写的列，客户端传了也不算
  "updatedAt": 1767225600000
}
```

- **AAD = `pairId|ownerUid|version|schemaVersion`**（UTF-8）已实现：写侧在 `ScheduleUseCase.pushMySnapshot`
  里按自己的 `pairId/uid/version` 组串，读侧由 `aadOfSnapshot()` 从信封明文元数据重组。
  两侧必须共用 `SnapshotCrypto.aadOf` 这一个构造口径——各写一份就会漂，一漂就是"永远解密失败"。
  把上下文绑进 AAD 之后，"把 A 的密文搬到 B 名下"在解密这一步就直接失败；
- 编码统一为 **base64**（旧原型的 hex 已随信封字段一起换掉，没有共存期：`schemaVersion` 不匹配就拒绝写入）；
- `authTag` 与 `ciphertext` 分离，不再靠"末 16 字节是 tag"的隐式约定；
  `algorithm` 是明文列，云侧只接受 `'AES-256-GCM'` 这一个值，不准备"以后可能加"的第二把。

### 5.2 明文体（本机生成，按隐私等级降维）

沿用 `domain` 的 `CRD1` 文本格式（行分隔）：

```
CRD1|<version>|<level>|<startEpochDay>|<days>
B:<hex 位图，days*48 位，30 分钟粒度>       # L1/L2
S:<startMin>,<endMin>,<tag>;...             # L2/L3，epochMin
```

| 等级 | 对方能看到什么 | 归因影响 |
|---|---|---|
| L1 忙闲 | 只有位图，所有区间标签恒为 `BUSY` | 冲突只能归因到"对方时间发生变化"，说不出班次/课程 |
| L2 班次类型 | 位图 + 30 分钟量化标签（如"上课"），无精确时段 | 同上，量化后不暴露分钟 |
| L3 完整时间 | 分钟级区间 + 标签 | 可归因到"TA 的这段时间已有安排" |

**云端明文禁区**：日程名、课程名、地点、备注、计划标题、长期密钥、HUKS 别名、配对码、确认凭据、
昵称、精确定位。云侧明文列的完整清单就是 `cloud-backend/clouddb/objecttype/*.json` 里那两个对象的
字段集，逐字如下——

| 表 | 明文列 |
|---|---|
| `PairSession` | `pairId`、`status`、`code`、`creatorUid`、`creatorPublicKey`、`joinerUid`、`joinerPublicKey`、`confirmToken`、`schemaVersion`、`createdAt`、`updatedAt`、`expiresAt` |
| `PairSnapshot` | `pairId`、`ownerUid`、`peerUid`、`version`、`shareLevel`、`schemaVersion`、`algorithm`、`iv`、`authTag`、`updatedAt`（`ciphertext` 是密文本体） |

`code`、`confirmToken`、`iv`、`authTag` 这四列不在最初的允许清单里，是随"一张表装下成员关系"
这个实现选择一起进来的（§6.1 第 2 条）。前三者是有 TTL 的一次性凭据，`iv`/`authTag` 单独泄露
不解密也不产生信息——但它们的**存在**必须写进清单，否则下一次审计会按"禁区"误报。
真正的一票否决项没有动过：密钥材料、别名、日程明文，任何一条出现在列上都算协议被破。

**接收侧不再二次加缓冲**：快照产出时已含对方自己的通勤/收整缓冲（`ScheduleUseCase` 的 buffer 管线），二次叠加会把共同时间算少。

## 6. 密钥建立（HUKS）

目标：**长期密钥只在两端 HUKS 内生成，永不以裸字节交回应用**。

**路线 A 已选定并实现**（`cloud/src/main/ets/api/PairKeyStore.ets`），依据是 API 26 模拟器
两台设备的跨端互通实测（`docs/validation/clouddev-api26-spike.md` §2 实验 #5），不是静态推断：

- 本机静态身份密钥：`HUKS_ALG_ECC` / 256 / purpose 只有 `AGREE`（没有 export、没有 derive），
  别名 `crd-id-<uid>`。purpose 里没有可导出位，私钥就导不出去；
- 协商：`HUKS_ALG_ECDH` 会话 `initSession → updateSession → finishSession`，共享密钥以
  `HUKS_TAG_DERIVED_AGREED_KEY_STORAGE_FLAG = HUKS_STORAGE_ONLY_USED_IN_HUKS` 直接收进
  `crd-pair-<pairId>` 别名——**协商结果全零、`sharedSecret` 为空**，应用侧从头到尾没有裸密钥，
  所以 `PairKeyStore` 里不存在任何返回密钥的函数；
- 加解密在同一别名上做 `AES-256-GCM`。三条只有实测才能得到的参数口径写死在这里：
  GCM 用 `HUKS_TAG_NONCE` / `HUKS_TAG_ASSOCIATED_DATA` / `HUKS_TAG_AE_TAG`，
  用 `HUKS_TAG_IV`/`HUKS_TAG_AAD` 会**加密"成功"而解密报 `401: The parameter does not exist`**；
  HUKS 交回的 `outData` 是"密文 ‖ 16 字节 tag"，拆成 §5.1 的两个字段是本文件的职责。
- 路线 B（`wrapKeyItem`/KEM）不实现，也不留"以后可能加"的分支。

协商消息（公钥）通过 §4.1–§4.3 的会话端点带外交换，云端只见不透明 base64，不解析、不校验曲线。

三条实现约束的落地情况：

1. **已完成**：Preferences 里既不存密钥也不存别名——别名由 `pairId`/`uid` 现推
   （存一份就会和 `pairId` 漂）。`savePairKey`/`getPairKey`/`deriveKeyHex` 全部不存在，
   `SettingsStore.clearPairKey()` 只保留一个 delete 口，用来清旧原型留下的 64 位 hex 残留。
2. **仍未实测**：卸载重装、清数据、备份恢复之后别名是否还在。目前所有对外判断都走
   `hasKeyItem`——别名不在就是 `KEY_UNAVAILABLE`，由调用方引导重新配对，
   **绝不静默新建别名**（那会让双方密钥永久不一致）。开闸批要把"恢复后别名不存在"这一条
   真正在设备上跑一次并记进 §11。
   **2026-09-27 设备实测补充**：判断存在性不能用 `isKeyItemExist` 的 Promise 形态——它在别名
   不存在时不是返回 `false`，而是 reject `12000011 / The entity does not exist.`（API 26 模拟器，
   首次点「生成邀请码」时在 `ensureIdentity` 第一步就降级成"配对服务暂时不可用"，整条链路一条云请求
   都没发出）。`hasKeyItem` 的 Promise 形态（@since 11）才按文档返回 `false`。
3. **已实现**：密钥失配的表现与解密失败完全一致——保留最后有效快照 + 提示重新配对，
   不删对方数据、不进入半同步状态（`partnerIntervalsFromSnapshot` 返回 null 就是这条路径）。

### 6.1 残余风险（实现选择带来的，不是缺陷清单）

写在这里是为了让下一次审计不必重新发现它们。

1. **`uid` 是自证的。** AGC 云对象这条路给不出可验证的调用方身份（§4.8 的 `permissions`
   只覆盖 Cloud DB 直连那条路，而云对象用自己的服务身份访问数据库）。所以"是不是成员"
   的判定是"参数里的 uid 在不在会话行的两列里"。冒充一个 `pairId` + 成员 uid 能得到什么：
   **密文与元数据**（版本、档位、时间戳）。得不到什么：日程内容——载荷端到端加密，
   密钥只在两端 HUKS 内。代价与缓解：`FORBIDDEN` 挡住非成员是"提高成本"而非"不可能"，
   真正的防线是加密本身。
2. **配对密钥是对称的，因此成员之间无法互相验证写入。** 同一把 pair key 既能解自己的快照
   也能解对方的，所以一个已配对的成员**可以**用对方的 `ownerUid` + 更高的 `version` 写一条密文，
   服务端无从分辨（它能分辨的只有成员关系、状态、schema、算法、大小、版本单调性）。
   攻击后果被两件事限住：写进去的内容仍要是能被 `SnapshotCodec.decode` 解开的合法密文，
   而这需要它已经持有对方的密钥——也就是它已经是这个 pair 的成员。
   **本产品不防这一层**：能读到对方全部细节的前提是双方已经互相信任到交换配对码。
   `confirmToken` 一次一用、`status` 不回凭据（§4.3/§4.4）关掉的是"第三方抢配对"，不是"成员互害"。
3. **快照云对象被完全入侵能泄出什么**：元数据（`uid`/`pairId`/`version`/`shareLevel`/时间戳）
   与配额，泄不出日程。这条边界正是 §5.2 允许存在明文列清单的全部理由。
4. **`code` 落在明文列上**：`PairSession` 存了未用完的 6 位码（原设计也存，但没写进清单）。
   它的保护窗口就是 TTL 24 小时且用过即清（§4.1 的 REVOKED 会把 `code` 一起抹掉）；
   拿到一枚有效码能做的事是"抢下这个配对位"，仍然算不出密钥（§2）。
   如果将来要更进一步，做法是不存码而存 `SHA256(code)`——但云端本来就给不出比对用的盐，
   这条留作未决（§10 第 6 项）。

## 7. 排序、幂等与失败降级

| 情形 | 判定 | 处置 |
|---|---|---|
| 重复 `snapshot.put` | 同 `version` + 同 `iv` + 同 `ciphertext` | 服务端判为重放，幂等返回 `storedVersion`（**不看 `requestId`**，§3.3） |
| 乱序（旧包晚到） | `version <` 已存 | `CONFLICT_VERSION`，客户端丢弃本次待发 |
| 同版本内容不同 | `version` 相同但载荷不同 | `CONFLICT_VERSION`；客户端**不做先拉后推**，见下 |
| 未确认就推 | 会话不是 `ACTIVE` | `BAD_REQUEST`——这是端侧状态机的缺陷信号，不是网络问题 |
| 解密失败（tag/AAD） | 本机 | 丢弃这一份，保留**最后一次有效快照**，提示重新配对 |
| 解码失败（`CRD1` 格式） | 本机 | 同上 |
| 密钥失配 | 本机（`KEY_UNAVAILABLE`） | 保留旧快照 + 引导重新配对，清别名 |
| 云端 401/403/404 | 端点级 | §3.4 表；一律不删本机数据 |
| 超时/配额 | `retryable = true` | **不自动重试**：当天不再重排，UI 显示降级态，下一次真实触发再试 |
| 不可重试的失败（语义码 `retryable = false`、解密/解码炸了） | `retryable = false` | 压住推送排程**直到某次云往返重新证明通路**（拉成功即清回"已同步"），换日不放开；本机数据一律不动 |

落地形态（U3b-3）：上面的判定写在 `SettingsStore` 的 `cloud_sync_state`（`结论|日序|语义码`），
由 `ScheduleUseCase` 的推/拉两侧写、`scheduleMergedSync()` 在读到"当天已压"时**在 `setTimeout` 之前**
就返回——拦在这里而不是 `pushMySnapshot()` 里面，是为了让 `nextSnapshotVersion()` 一次都不被消费。
被压掉的版本号本身不算损失（§3.3：最坏只是多一个版本号被用掉），所以不做游标回滚；
回滚游标要引入"本机版本可能低于云端已存版本"的新形状，比它省下的那一格更贵。

`CONFLICT_VERSION` 在客户端的实际后果要写清楚，因为它和原设计的"先拉后推"不同：
`nextSnapshotVersion()` 是本机单调递增的游标，推送失败记一条 warn 加一次三态结论（§3.4），
所以版本回退的纠正方式是"下一次保存动作带着更高版本号推上去"，即**后推的赢**。
这里没有需要合并的东西——快照是本人班表的**全量降维投影**，不是增量补丁，
"先拉后推"只会白付一次配额去拉自己刚推出去的那份。

触发同步的时机与实际形态（不新增常驻）：

- **推**：`ScheduleUseCase.onScheduleChanged()` → `scheduleMergedSync()`，
  同一 5 秒窗口内的多次保存只排一次推送，到点时读**当时**的最新班表，
  所以连改三次只花一次配额而内容不丢。关闭态与非 `PAIRED` 一个定时器都不建；
  三态里"当天已压"的那两格（`RETRY` 且同日、`BLOCKED`）同样不建——那是 §7 末行的落地位置；
- **拉**：**按需，不排队不定时**——`buildPartnerBusy()` 需要对方忙区间时拉一次
  （首页/共同时间/冲突解释的计算路径都会经过它）。拉不到时读数降级为本机代录，
  但这次失败不再只是日志：结论进三态，「我的 · 伴侣与同步」的配对卡会把它念出来（U3b-3）。
  **拉永远不被三态拦住**——它是唯一的复检通路，压住它就等于把"已停止"变成永久；
- 配对完成会走一次 `onScheduleChanged()`，等价于原设计的"配对完成即推"；
- **冷启动与"应用回前台"没有独立触发点**：读数路径自己会拉，不必再排一次。
  这一条与原设计不同，写在这里是为了让"少了哪个触发"不再是猜。

## 8. 配对状态机

```
UNPAIRED ──create──▶ WAITING ──join──▶ PENDING_CONFIRM ──confirm──▶ ACTIVE
   ▲                    │expiresAt              │                        │
   └─────────status─────┴───────┬───────────────┘                        │
                                ▼                                        ▼
                          EXPIRED / REVOKED  ◀──────────unpair───────────┘
```

- 本机状态与云状态不一致时，以 `pairing.status` 为准（打开「我的 · 伴侣与同步」必然对一次账）；
- `EXPIRED/REVOKED` 的**本机后果相同**：收回 `UNPAIRED`，保留本机 RDB 全部数据，包括本机代录的对方日程（那部分从来不是云数据）；
- 严禁出现"UI 显示已配对但没有任何同步通路"的态。**这条已封口**：`confirmWithToken()` 只有在云端
  真的回 `status === 'ACTIVE'` 之后才写本机 `PAIRED`，「检查配对状态」只做对账不再直接置位，
  加入方停在 `PENDING_CONFIRM`。原先"完成配对按钮直接置 `PAIRED`"的偏离（`docs/testing-checklist.md` §9.5）
  随 U3a 一起消失；
- 云端没有"第六态"：`WAITING/PENDING_CONFIRM/ACTIVE/EXPIRED/REVOKED` 五态全在会话行的 `status` 列上。
  本机存的是同一组字符串（`SettingsStore` 的 `PAIR_NONE='NONE'`、`PAIR_WAITING='WAITING'`、
  `PAIR_PENDING='PENDING_CONFIRM'`、`PAIRED='PAIRED'`），**只有 `NONE` 是端侧自造的词**，
  对应云端的"会话不存在"（`NOT_FOUND`）。刻意不做第二套枚举：加一层映射就多一处会漂的地方，
  而 `EXPIRED → UNPAIRED`、`REVOKED → UNPAIRED` 这两条收敛在端侧写死一次就够了。

## 9. 差异清单的落地情况（原"实施前必须核对"）

原来的 10 条是"当前代码 → v1"的待办；1–9 已落地，第 10 条（开闸）在 2026-09-27 的开闸批落地。
提交：U1+U2 = `3207ebf`，U3a = `e44846e`，U3b-1（heartbeat）= `fb159ee`，
U4–U6（云侧源码、包络修复与探针复验）= `978b24b`…`8f9183c`，U3b-3（三态）= `fbf4b87`。

| # | 位置 | v1 要求 | 现状 |
|---|---|---|---|
| 1 | 密钥承载 | 密钥材料改由 HUKS 别名承载，Preferences 不落密钥 | **已落地**。`savePairKey/getPairKey/deriveKeyHex` 均不存在；`clearPairKey()` 只保留一个 delete 口清旧原型 hex |
| 2 | `SnapshotCrypto` AAD | `pairId\|ownerUid\|version\|schemaVersion`（§5.1） | **已落地**，且两侧共用 `SnapshotCrypto.aadOf` 这一个构造点 |
| 3 | `EncryptedPayload` | 独立 `authTag` + `algorithm`，base64（§5.1） | **已落地**。HUKS 交回的是"密文 ‖ tag"，拆分发生在 `PairKeyStore` |
| 4 | `CloudApi.call()` | 显式 `timeout: 30000` + `requestId`（§3.3） | **已落地**；`requestId` 的幂等角色按 §3.3 改成了实现口径（它不做幂等） |
| 5 | 端点名 | `snapshot.put` / `snapshot.get`（§4.7–4.8） | **已落地** |
| 6 | 端点集合 | 8 个方法 | **已落地**：`pairing` 6 + `snapshot` 2 |
| 7 | 邀请码 | 云端生成并下发（§4.1） | **已落地**，端侧 `generateInviteCode()` 已删 |
| 8 | 错误码 | §3.4 语义码表 + 三态 UI 收敛 | **已落地**（U3b-3）。端侧收敛在 `CloudApiError.semantic` + `retryable`；三态在 `feature/model/CloudSyncRules.ets`（纯函数：判定 + 措辞），持久态 `SettingsStore.cloud_sync_state`，推/拉两侧记账在 `ScheduleUseCase`，上屏在「我的 · 伴侣与同步」配对卡的 `NoticeBar` + 身份卡那一行。**两处偏离原计划，都写在代码注释里**：① 用 `NoticeBar` 而不是 `StatePanelKind.DEGRADED`——StatePanel 是整页空/错态的面板，配对卡里要的是一行内提示，`DEGRADED` 那一态因此仍是零调用点；② **不给"立即重试"这颗按钮**——§3.3 明写端侧没有退避重试，而手动重试不在 §7 的触发时机里，给了等于让用户自己按一次就烧一次免费档的按天配额；复检靠下一次真实保存/进共同时间自然带起 |
| 9 | 触发同步 | 触发集合 + 5 秒合并窗口（§7） | **已落地**，按 §7 修正后的口径（推有合并窗口，拉是按需） |
| 10 | `FeatureFlags.cloudPairing` | 门禁全过前保持 `false` | **已开闸（2026-09-27 批次 U·U3b）**：同批落地 `ohos.permission.INTERNET`（`reason: $string:internet_perm_reason`）、隐私政策 v1.1 全文 + 首启摘要 + 提审权限用途说明、以及 `docs/release/rollout-and-rollback.md` §3.3 三条同批条件的核对。**仍未同批的是备案**（上架前置，与档位无关）。回退 = 常量改回 `false` + 删掉 `INTERNET` + 政策回到 v1.0 口径，三者一起（§5） |

## 10. 未决项

原先 5 条里 4 条已经有了答案，留下的都归到 §11 的实测清单，因为它们的共同点是
"静态读代码读不出来"。

1. ~~实验 #3~~ **已定**：`SEPARATE_CLOUD_REPO`。硬把向导的 `CloudProgram/` 塞进多 HAR 扁平根目录
   会污染 App 侧构建；云侧实现落在 `cloud-backend/`（纯镜像，不参与本仓库任何构建），
   部署时复制进仓库外的向导工程，见 `cloud-backend/README.md` §2。
2. ~~实验 #5~~ **已定**：路线 A（§6）。但"别名在卸载/重装/清数据/备份恢复后是否还在"**仍未实测**，
   它是 §11 第 5 项，不是本条的已完成部分。
3. ~~实验 #4~~ **部分回答**：`timeout: 30000` 已显式传入，网络类失败归 `1008210001 → NETWORK`、
   AGC 未就绪归 `201/1008210009 → LOCAL`（`CloudGateway.transportError`）。
   **真实 30s 截断一次也没观察到过**，所以"截断到底报哪个码"仍是猜，见 §11 第 6 项。
4. ~~实验 #6~~ **已定**：没有安全规则这回事，靠 `permissions` 四角色全空 + 一切读写穿云对象（§4.8）；
   成员关系折进 `PairSession` 的两列，不需要服务端 join。
5. **仍未测**：单份快照的字节上界（`days` 上限 366 × L3 分段数在真实班表下的密文尺寸）。
   2 MB 阈值目前按 base64 **字符串长度**换算收口，是否需要按 `shareLevel` 分档取决于这条实测结果，
   见 §11 第 7 项。
6. **新加入**：`code` 是否改成只存 `SHA256(code)`（§6.1 第 4 条）。做了要解决"云端拿什么比对"，
   没做就把一枚 24 小时内有效的 6 位码明文留在列上——这条留给下一个改协议的人裁定。

## 11. 设备证据（**闸门已开，十条一条都没勾**）

本文所有"已落地"都只到代码层。下面每一条都要在真机或模拟器上跑出证据。
**它的定位在 2026-09-27 变了**：原先是"勾完才允许 `cloudPairing = true`"的前置闸门，档位已经开了（§9 第 10 行），
所以这一节现在是**提审前必须补完的欠账**——纪律平移而不变：验收报告 §7 那句"不得在没有设备证据时勾选
权限/渲染类通过"对下面每一条仍然逐字成立，只是主语从"开闸"换成了"提审"。**没有现场证据就不要在任何文档上打勾。**

跑证据的机器：两台 API 26 模拟器（`hdc list targets -v` → `127.0.0.1:5555` / `127.0.0.1:5557`）。
第 5 条（HUKS 别名在卸载/清数据/备份恢复后的语义）与第 10 条（第三次设备拿旧凭据访问）在模拟器上能跑出行为，
但"真机硬件安全等级"这一半**模拟器证不了**，勾的时候要说清楚是哪一种证据。

| # | 要跑的 | 通过判据 |
|---|---|---|
| 1 | 两台设备走完整配对：`create → join → confirm` | 云端 `status=ACTIVE` 之前，任何一侧的 UI 都不显示"已配对"；加入方停在 PENDING 态能看到"等 TA 确认" |
| 2 | 快照往返 | A 改班表 → B 侧共同时间在 5 秒窗口后跟上；`shareLevel` 三档各测一次，L1 看不到标签、L2 看不到分钟 |
| 3 | 三种降级：飞行模式 / AGC 未初始化 / 云对象未部署 | 本机全部功能可用、无阻塞弹窗、无重试风暴；`CloudGateway.calls` 增长但界面只回一句降级。**三态要能被看见（U3b-3 的实测项）**：飞行模式下保存一次 → 配对卡出现「云同步待重试」（警示色 ↻），且当天再保存**不再排推送**（日志里 `scheduleMergedSync` 直接 return，`snapshot.put` 调用数不涨）；次日或下一次拉成功后清回「已同步」；把 `cloud_sync_state` 手动写成 `BLOCKED` 那一格 → 配对卡念「云同步已停止」（错误色 !），且身份卡顶上那行不再是"加密同步" |
| 4 | 人为制造版本回退（把 `nextSnapshotVersion` 游标改小） | 只丢这一次推送（`CONFLICT_VERSION`），后续保存正常推上去，不进入"永远推不动" |
| 5 | HUKS 别名生命周期：卸载重装 / 清数据 / 备份恢复 | `hasKeyItem` 的答复与 UI 引导一致（**不要用 `isKeyItemExist`**：它的 Promise 形态在别名不存在时 reject 12000011，见 §6 第 2 条的 2026-09-27 实测补充）；**绝不静默新建别名**（否则双方密钥永久不一致，表现为永远解密失败） |
| 6 | 真实 30s 截断一次 | 记录实际错误码与归属（`NETWORK` / `INTERNAL` / 端侧 timeout），回填 §3.4 |
| 7 | 真实班表 366 天 L3 的密文字节数 | 得出上界，裁定 2 MB 阈值要不要按档位分档（§10 第 5 项） |
| 8 | ~~接上 `heartbeat`~~（§4.6 端侧缺口已于 U3b-1 补上，离线断言见 `ProfileSettingsGuardTest`）；剩观察项：paired 态连跑一周 | AGC 控制台看到 `pairing.heartbeat` 的调用计数在涨。**注意只能拿 paired 态测**：未配对的安装按 §4.6 的收窄一条都不发 |
| 9 | 解除配对 | 云侧该 pair 的会话行与两行快照一起消失（AGC 控制台核对），**对方**本机数据一条不丢 |
| 10 | 第三次设备拿旧码/旧 `pairId` 访问 | 全部 `FORBIDDEN`；本机数据不受影响 |

### 11.1 现场记录（2026-09-27，两台 API 26 模拟器）

**十条全部未勾。** 下面只记已经跑出来的事实，包括一次失败。

- 两台设备（`127.0.0.1:5555`＝Pura 90 Pro Max HVD / `127.0.0.1:5557`＝Mate 80 HVD，都是 API 26 模拟器）
  都装的是**签名后的 debug HAP**，`bm dump -n com.common.fortwo`
  各回三条权限、含 `ohos.permission.INTERNET`；启动日志 `CrdFlags: calendarFlow=on cloudPairing=on
  scanPairing=off newCard=on responsiveV2=on`。5555 那次是全新安装，顺带留下了首启隐私弹窗的真实截图
  （五条要点 + 两个按钮都是 v1.1 的文案）。
- **第 1 条卡在端侧，而且是代码缺陷不是环境问题**：两台设备首次点「生成邀请码」都只回一句降级，
  日志里**没有** `identity key created`、也没有任何出网记录。根因见 §6 第 2 条的实测补充——
  `ensureIdentity` 用 `isKeyItemExist` 判断别名是否存在，而它在别名不存在时 reject 而不是返回 false。
  改用 `hasKeyItem` 后两台都走到 `PairKeyStore: identity key created`。
- 修好之后第 1 条仍未通，卡在鉴权：请求真的出网了（`CloudDevelopProxyNet POST … httpCode: 401`），
  端侧把它归成 `CloudApiError('UNAUTHORIZED')`，界面念「云端拒绝了这次调用」。**两侧都停在「未配对」，
  没有阻塞弹窗，也没有写进任何半截配对状态**——这条本身就是 §11 第 3 条要的"降级只回一句话"的形态，
  但不算它的证据（触发原因不是那三种降级之一）。
  `[未判定]` 401 有两条候选解释，现在还不能二选一：① `com.common.fortwo`（app id `6917617383543050045`）
  在这两台模拟器上的调试凭据从没注册过——注册凭据是按 app id 绑的，spike 那轮注册的是**另一个** app；
  ② 云工程绑的是"两人份云"（`6917617526333646177`），跨 app 调用是否被网关放行属未知（运维册 §2.4 第 8 行
  预警的就是这一格）。处置顺序按成本排：先给正式应用注册两台模拟器各自的凭据（AGC → 证书、APP ID和Profile
  → 模拟器调试凭据，改后约 30 分钟生效），仍 401 才回到 §1 第 1 步重生成绑到本应用的云工程。
  **凭据值不写进本文档，也不写进任何聊天**：本次取到的两枚放在仓库外 `.crdtest/pair/debug-tokens.txt`。
- 21:54 用**同一次安装的第二次冷启**复跑一次（pid 14541 → 14987），把两条候选拉近了但**仍不勾第 1 条**：
  - 代理出网报文里签名的 app id 解出来正是 `6917617383543050045`（`SetSignHeaders … appId: 6**7**7**3**3**0**5`；
    这行日志按每三位留一字符脱敏，同一规则对"两人份云"的 `6917617526333646177` 会解成 `6**7**7**6**3**6**7`，不匹配）。
    同一条里 `saId` 为空，凭据类型是 `CloudAppIdentityAuth: credential cty: emulator_anon_cert`——
    **匿名**证书，现向 `tsms-drcn.security.dbankcloud.cn` 申请的，之前还有一次 `Query data row count:0`（代理本地没有这个 app 的凭据行）。
    这几点一起把天平压向候选 ①。
  - 候选 ① 的处置不会被 token 轮换打脸：两次冷启打出的是**同一个** debugToken，第二次没再出现
    `GetDebugToken: new debugToken …`，说明它存在代理自己的持久行里、不是一次性值。
    也就是"在 AGC 注册一次"是真动作，不是注册完下次启动又换掉。仓库外那两枚与设备上现取的值逐字一致。
  - 复跑还顺带确认：重启后两侧仍读作「未配对」，401 没有留下半截配对状态。
  `[仍未判定]` 候选 ②（云工程绑在另一个 app 上、网关是否放行跨 app 调用）在设备侧证不了——
  只有"注册之后仍 401"才能排除它，届时回到运维册 §1 第 1 步重生成绑到本应用的云工程。
- 同日 21:43 用服务端凭据直跑云侧 24 步全生命周期探针：23 通过，唯一失败是 `put_v0_behind` 拿到
  `12003: timeout of 30000ms exceeded`——那是**探针自己的客户端超时**，不是云对象回的语义码，
  所以既不能当 §11 第 4 条的证据，也不能反过来说版本回退的拒绝逻辑坏了；待复跑定性。
  云侧健康的旁证：`create → join → confirm → ACTIVE`、级联删除、外部人 `FORBIDDEN` 全在同一轮里过。

