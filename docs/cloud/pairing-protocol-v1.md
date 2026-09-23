# 配对与加密快照协议 v1（冻结设计）

> 状态：**设计已冻结，尚未获授权实施。**
> 依据：阶段 3 的唯一开门条件是 `docs/validation/clouddev-api26-spike.md` 的结论不为 `CLOUD_BLOCKED`；
> 当前结论为 `CLOUD_BLOCKED`（HUKS 实验 #5 仅 `PARTIAL_STATIC`，实验 #1/#2/#3/#4/#6 `NOT_STARTED`）。
> 因此本文只冻结"要建成什么样"，不代表任何端点已经存在或可用。翻闸前必须按 §9 逐项核对。
> 本文是本仓库内云端契约的唯一事实源；改协议 = 改本文并升 `schemaVersion`，不允许在代码注释里另立口径。

## 1. 云端承担什么、不承担什么

云端只做两件事：**配对会话**与**加密快照中转**。它不是主库。

| 事实源 | 归属 | 云端角色 |
|---|---|---|
| 班表/课表/循环模板/单日覆盖/计划 | 本机 RDB | 只存"降维后的加密快照"，不存原始数据 |
| 共同时间窗口计算 | 本机 `domain` 引擎 | 云端不参与计算，也不缓存计算结果 |
| 配对状态（`UNPAIRED/WAITING/PAIRED`） | 双方各存本机 + 云端会话记录 | 云端是会话生命周期的仲裁者（过期、撤销） |
| 长期密钥 | **只存在于 HUKS 安全环境** | 云端永不得到密钥明文，因而读不到载荷 |

三条不可让步的边界（来自改造文档 §0.3 与 spike §4 门禁规则）：

1. **邀请码不得直接作为长期快照密钥**，也不得用 `SHA256('crd-v1:' + code)` 这类短码派生长期密钥；
2. **长期密钥不得写入 Preferences、源码、二维码或日志**——Preferences 里只允许存 HUKS **别名**；
3. **云端任何失败都不得阻断本机**：拉取失败、超时、401/403/404、配额用尽一律降级为"沿用最后一次有效快照或本机代录"。

## 2. 标识与凭据

| 名称 | 形态 | 生成方 | 可见范围 | 说明 |
|---|---|---|---|---|---|
| `ownerUid` | 云端分配的账号内 uid | 云端 | 云侧明文 | 用于安全规则与归属判定；非个人信息 |
| `pairId` | 云端生成的会话 id | 云端 | 云侧明文、双方本机 | 快照的分片键与权限键；Preferences 可存 |
| `code` | 6 位数字，**短期凭据** | 云端 | 用户之间口头/分享传递 | 只能用于 `pairing-join`，有 TTL，用过即废 |
| 长期密钥 | 256-bit | **HUKS 会话协商派生**（§6） | 只在两端 HUKS 内 | 以别名引用，密钥材料不出安全环境 |
| `version` | 单调递增整数 | 客户端（每台自己维护） | 云侧明文 | 幂等与乱序判定用（§7） |

`code` 与长期密钥的关系是**单向且经过 HUKS 协商**的：拿到 `code` 不能算出密钥，`code` 泄露的最坏后果是"在 TTL 内被人抢一次配对"，而不是历史快照被解密。这是本协议与旧原型（`deriveKeyHex(code)`）的唯一实质区别。

## 3. 通用包络

### 3.1 请求

所有端点共用同一请求骨架：

```jsonc
{
  "requestId": "uuid-v4",     // 客户端生成，幂等键的一部分
  "sentAt": 1767225600000,    // 客户端毫秒时间戳，仅用于观测，不参与判定
  "schemaVersion": 1,         // 本协议版本；不匹配返回 SCHEMA_UNSUPPORTED
  // ...端点自有字段
}
```

### 3.2 响应

```jsonc
{
  "code": "OK",               // 语义码，见 §3.4；成功恒为 "OK"
  "message": "",              // 面向日志的英文短语，不进 UI 文案
  "retryable": false,         // 客户端是否值得退避重试
  "serverTime": 1767225601234,// 服务端毫秒时间戳，客户端据此校准 TTL 判定
  "requestId": "uuid-v4",     // 原样回带
  // ...端点自有字段
}
```

### 3.3 超时与重试

- 客户端调用**必须显式传 `timeout: 30000`**。`FunctionParams.timeout` 的 SDK 默认值是 70×1000ms，而云函数同步调用侧上限是 55s，不传就会在慢请求上撞墙（spike §1 已核）。
- 只有 `retryable = true` 且网络类错误才重试：**指数退避 + 抖动**，1s 起、上限 3 次；`retryable = false` 立即降级，不重试。
- 重试必须复用同一 `requestId`：写类端点（`snapshot-put`、`pairing-confirm`）以 `pairId + ownerUid + version + requestId` 幂等。
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

## 4. 端点（8 个）

字段表里"必填"标注省略的均为必填。所有端点都要求调用方已通过 Cloud Foundation 匿名鉴权。

### 4.1 `pairing-create`

发起方生成邀请码。

| 请求 | 响应 |
|---|---|
| `creatorUid` | `pairId`、`code`、`expiresAt`（服务端时钟）、`ttlSeconds` |

- `code` 由**云端**生成（当前原型在端侧 `generateInviteCode()` 生成后上传，实施时删除该路径）；
- 同一 `creatorUid` 同时最多一个 `WAITING` 会话：重复调用**复用**未过期会话并返回同一 `pairId` + 新码（旧码作废）；
- 副作用：创建会话记录，状态 `WAITING`。

### 4.2 `pairing-join`

加入方凭码入会。

| 请求 | 响应 |
|---|---|
| `code`、`joinerUid` | `pairId`、`creatorUid`、`status`（`PENDING_CONFIRM`）、`expiresAt` |

- 一次 `code` 只允许一个 `joinerUid`（`CODE_TAKEN`）；
- 加入后**不得立即视为已配对**，也不得立即写任何快照——必须等 §4.3；
- 加入方在此步完成 HUKS 密钥协商的本地准备（§6）。

### 4.3 `pairing-confirm`

发起方确认，会话转 `ACTIVE`。

| 请求 | 响应 |
|---|---|
| `pairId`、`uid`（发起方）、`confirmToken` | `status = ACTIVE`、`pairedAt`、`serverTime` |

- `confirmToken` 是 `pairing-join` 之后由云端下发给加入方、再由加入方通过任意安全信道（二维码/分享，§4.6）交回发起方的一次性凭据；
- 只有双方 uid 都在会话成员表内才允许 `ACTIVE`（否则 `FORBIDDEN`）；
- 幂等：同一 `pairId` 重复确认返回同一结果。

### 4.4 `pairing-status`

任一侧查询会话状态，用于打开「我的 · 伴侣与同步」时的对账。

| 请求 | 响应 |
|---|---|
| `pairId`、`uid` | `status`（`WAITING/PENDING_CONFIRM/ACTIVE/EXPIRED/REVOKED`）、`peerUid`、`peerShareLevel`、`peerVersion`、`expiresAt`、`serverTime` |

只读、可频繁调用；`EXPIRED/REVOKED` 时客户端把本机状态收回 `UNPAIRED` 并**保留全部本机数据**（含对方代录数据）。

### 4.5 `pairing-unpair`

解除配对，**级联删除云侧该 pair 的全部快照**。

| 请求 | 响应 |
|---|---|
| `pairId`、`uid`、`requestId` | `deletedVersions`（删除的对象数） |

- 任一成员发起即整对解除（本产品的双人语义）；
- 云侧删除是硬删除，且必须**同时**删除成员表、快照对象与未过期的邀请码；
- 本机：删除 HUKS 别名（密钥材料随之消失），清 `pairId`，保留本机 RDB 数据；
- 幂等：会话已不存在返回 `OK` + `deletedVersions = 0`（不返回 `NOT_FOUND`）。

### 4.6 `pair-heartbeat`

轻量存活信号，用于避免 AGC 把项目判为闲置资源（docs/05 §3.2：连续 6 个月无有效调用 → 预警 30 日后回收）。

| 请求 | 响应 |
|---|---|
| `uid`、`pairId?`（未配对时省略） | `serverTime`、`projectLastActiveAt` |

- **不携带任何载荷数据**，不写库；
- 由冷启动与"每周一次"的定时器各发一次即可，成本可忽略；
- 未配对用户没有云数据可回收，因此未配对时允许省略 `pairId`，服务端只记一次项目活跃。

### 4.7 `snapshot-put`

写入自己的加密快照。

| 请求 | 响应 |
|---|---|
| `pairId`、`ownerUid`、`version`、`shareLevel`、`payload`（§5 信封）、`requestId` | `storedVersion`、`updatedAt` |

- 会话必须 `ACTIVE`，`uid` 必须是成员；
- `version` 必须大于该 `ownerUid` 已存的 `version`，否则 `CONFLICT_VERSION`（不做服务端合并，客户端先拉后推）；
- 服务端只存信封字节，**不解密、不校验明文结构**；`payload` 超过 2 MB 直接 `BAD_REQUEST`；
- 覆盖写：每个 `pairId + ownerUid` 只保留**最后一个**快照（历史版本无用途，且少存一份是一票收益的隐私改进）。

### 4.8 `snapshot-get`

拉取对方的快照。

| 请求 | 响应 |
|---|---|
| `pairId`、`peerUid?`、`sinceVersion` | `snapshot`（对象或 `null`）、`serverTime` |

- 省略 `peerUid` 时服务端按成员表自行解析对端——**客户端不需要知道对方 uid 的语义**；
- `version <= sinceVersion` 时返回 `snapshot = null`（无更新），这是常态而不是错误；
- 安全规则：`request.auth.uid == resource.ownerUid || request.auth.uid == resource.peerUid`，其余一律 `2001015: permission denied`（docs/05 §5.5）。端侧禁止绕过云函数直连读写。

## 5. 快照对象与加密信封

### 5.1 信封（云侧存储单元）

```jsonc
{
  "pairId": "p_...",
  "ownerUid": "u_...",
  "version": 17,
  "shareLevel": 2,
  "schemaVersion": 1,
  "algorithm": "AES-256-GCM",
  "iv": "base64(12B)",
  "authTag": "base64(16B)",     // 独立字段，不再拼进 ciphertext
  "ciphertext": "base64(...)",
  "updatedAt": 1767225600000
}
```

- **AAD = `pairId|ownerUid|version|schemaVersion`**（UTF-8）。当前实现用的是固定常量 `'crd-v1'`，必须换掉：把上下文绑进 AAD 之后，"把 A 的密文搬到 B 名下"会直接解密失败；
- 编码统一为 **base64**（当前实现是 hex，实施时一次性迁移，§9）；
- `authTag` 与 `ciphertext` 分离，不再靠"末 16 字节是 tag"的隐式约定。

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

**云端明文禁区**（可由 §4.8 的审计查询核验）：日程名、课程名、地点、备注、计划标题、长期密钥、邀请历史、昵称、精确定位。允许明文：`pairId`、`ownerUid`、`peerUid`、`version`、`shareLevel`、`schemaVersion`、`updatedAt`、`algorithm`。

**接收侧不再二次加缓冲**：快照产出时已含对方自己的通勤/收整缓冲（`ScheduleUseCase` 的 buffer 管线），二次叠加会把共同时间算少。

## 6. 密钥建立（HUKS）

目标：**长期密钥只在两端 HUKS 内生成，永不以裸字节交回应用**。

spike §1 的静态核验已经否决了两种写法：本 SDK 的 HUKS **没有** `deriveKey()` / `agree()` 函数，也**没有** `NON_EXPORTABLE` 标签。因此 v1 只允许下面两条形态之一，且**必须由实验 #5 在真机上二选一定形**：

- 路线 A：ECDH 会话流程（`initSession/updateSession/finishSession`，`HUKS_ALG_ECDH = 100`）派生共享密钥，派生密钥以 `DERIVED_AGREED_KEY_STORAGE_FLAG` 留在 HUKS 内，直接用于 AES-GCM 会话；
- 路线 B：`wrapKeyItem` / `unwrapKeyItem`（`HUKS_UNWRAP_SUITE_ECDH_AES_256_GCM_NOPADDING`）或 KEM `encapsulate`/`decapsulate`（含 `HUKS_ALG_ML_KEM = 200`）包裹一把内容密钥。

协商消息（公钥/封装体）通过 §4.1–§4.3 的会话端点带外交换，云端只见不透明字节。

三条实现约束：

1. Preferences 只存**别名**（如 `crd-pair-<pairId>`）与 `pairId`，`SettingsStore.savePairKey/getPairKey` 这条密钥持久化路径在实施时必须**删除**；
   > **阶段 6R.2 已完成这一条的"删除写入口"半边**：`savePairKey` 与 `SnapshotCrypto.deriveKeyHex` 已从源码移除，`getPairKey` 转为只读、`clearPairKey` 只用于清旧原型残留（换机恢复与解除配对时调用）。
   > 剩下的是"存别名"这半边：HUKS 别名方案尚未实现（Task 0.4 `CLOUD_BLOCKED`），届时 `getPairKey` 这个读接口也应一并换成 `getPairKeyAlias()`，别留一个读密钥材料的口子。
2. 别名生命周期必须在 spike 里实测：卸载重装、备份恢复、清数据后别名是否还在。若"恢复后别名不存在"，则本机必须能感知密钥丢失并引导重新配对（`KEY_UNAVAILABLE` → 提示重新配对），不得静默生成新别名造成双方密钥永久不一致；
3. 密钥失配的表现必须与"解密失败"一致：保留最后有效快照 + 提示重新配对，**不删对方数据、不进入半同步状态**。

## 7. 排序、幂等与失败降级

| 情形 | 判定 | 处置 |
|---|---|---|
| 重复 `snapshot-put` | 同 `version` + 同 `requestId` | 服务端幂等返回首个结果 |
| 乱序（旧包晚到） | `version <= storedVersion` | `CONFLICT_VERSION`，客户端丢弃本地待发 |
| 同版本内容不同 | `version` 相同但 `requestId` 不同 | 后到者失败并转为"先拉后推"（不做服务端合并） |
| 解密失败（tag/AAD） | 本机 | 丢弃这一份，保留**最后一次有效快照**，提示重新配对 |
| 解码失败（`CRD1` 格式） | 本机 | 同上 |
| 密钥失配 | 本机（`KEY_UNAVAILABLE`） | 保留旧快照 + 引导重新配对，清别名 |
| 云端 401/403/404 | 端点级 | §3.4 表；一律不删本机数据 |
| 超时/配额 | `retryable = true` | 退避重试；当天不再重排，UI 显示"待重试" |

触发同步的时机（与改造文档一致，不新增常驻）：配对完成、日程保存后、应用回前台、进入共同时间、用户手动同步。前四项在客户端各自只排一次"合并同步"，同一 5 秒窗口内的多次触发合并为一次调用。

## 8. 配对状态机

```
UNPAIRED ──create──▶ WAITING ──join──▶ PENDING_CONFIRM ──confirm──▶ ACTIVE
   ▲                    │expiresAt              │                        │
   └─────────status─────┴───────┬───────────────┘                        │
                                ▼                                        ▼
                          EXPIRED / REVOKED  ◀──────────unpair───────────┘
```

- 本机状态与云状态不一致时，以 `pairing-status` 为准（打开设置页必然对一次账）；
- `EXPIRED/REVOKED` 的**本机后果相同**：收回 `UNPAIRED`，保留本机 RDB 全部数据，包括本机代录的对方日程（那部分从来不是云数据）；
- 严禁出现"UI 显示已配对但没有任何同步通路"的态：现行「完成配对」按钮直接置 `PAIRED` 而不走 §4.3，属实施时必须修掉的偏离（见 `docs/testing-checklist.md` §9.5）。

## 9. 实施前必须核对的差异（当前代码 → v1）

这些是**待授权**的改动清单，不是待办建议；在门禁解除前不得动手。

| # | 位置 | 现状 | v1 要求 |
|---|---|---|---|
| 1 | `SnapshotCrypto.deriveKeyHex()` + `SettingsStore.savePairKey/getPairKey` | ~~`SHA256('crd-v1:'+code)`，密钥 hex 落 Preferences~~ **已随阶段 6R.2 删除**（`deriveKeyHex`/`savePairKey` 不存在；`getPairKey` 只读，供清理与"没钥匙就停住"判断） | 余下动作：把 `getPairKey` 换成 `getPairKeyAlias()`，密钥材料改由 HUKS 别名承载（§6） |
| 2 | `SnapshotCrypto` AAD | 固定 `'crd-v1'` | `pairId\|ownerUid\|version\|schemaVersion`（§5.1） |
| 3 | `EncryptedPayload` | `{ciphertext, iv}`，tag 拼在密文尾，hex | 独立 `authTag` + `algorithm`，base64（§5.1） |
| 4 | `CloudApi.call()` | `cloudFunction.call({name, version, data})`，未传 timeout | 显式 `timeout: 30000` + `requestId`（§3.3） |
| 5 | 端点名 | `snapshot-push` / `snapshot-pull` | `snapshot-put` / `snapshot-get`（§4.7–4.8） |
| 6 | 端点集合 | 5 个 | 8 个：补 `pairing-confirm`、`pairing-status`、`pair-heartbeat` |
| 7 | 邀请码 | 端侧 `generateInviteCode()` 上传 | 云端 `pairing-create` 生成并下发（§4.1） |
| 8 | 错误码 | `CloudApiError(1001/1002)` 两态 | §3.4 语义码表 + 三态 UI 收敛 |
| 9 | 触发同步 | 保存后即时推 | 触发集合 + 5 秒合并窗口（§7） |
| 10 | `FeatureFlags.cloudPairing` | `false` | 保持 `false`，直到 spike §4 五条门禁全部满足 |

## 10. 未决项（只能靠 spike 实测回答，写代码前必须有答案）

1. 实验 #3：现有多 HAR 扁平根目录能否不重排而加入 `CloudProgram/` → 决定 `IN_REPO_CLOUDPROGRAM` 还是 `SEPARATE_CLOUD_REPO`；若为后者，云函数实现落在独立授权仓库，本仓库只保留本文与运维手册。
2. 实验 #5：HUKS 路线 A / B 哪条能在 API 26 上跑通；派生密钥是否会被以裸字节交回应用；别名在卸载/恢复后的行为。
3. 实验 #4：Node.js 20 运行时下端侧 `timeout: 30000` 的实际截断行为与错误码归属（`TIMEOUT` vs `INTERNAL`）。
4. 实验 #6：云数据库安全规则能否稳定拒绝端侧直连（`2001015`），以及成员表模型下 `peerUid` 解析是否需要在服务端做 join。
5. 单份快照的字节上界：`days` 上限 366 × L3 分段数在真实班表下的密文尺寸（决定 `BAD_REQUEST` 阈值是否需要按等级分档）。
