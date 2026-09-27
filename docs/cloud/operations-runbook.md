# 云侧运维手册 v1

> 配套：`docs/cloud/pairing-protocol-v1.md`（协议，唯一事实源）与 `cloud-backend/README.md`（代码放哪、怎么部署）。
> 状态：**云侧代码已写好，AGC 项目与两张表还不存在**——本手册的 §1 与 §2 是"把还不存在的东西建出来"
> 的步骤，§3 之后是建好之后的管理。已实测过的路径会标 `[实测]`，只有文档依据的标 `[文档]`，
> 需要账号持有者本人在 AGC 控制台点的都标 `[需你操作]`。
> 2026-09-27 依实现回写：删掉了"8 个云函数""三份对象类型""云数据库安全规则"这三处从未成立的前提（§2.2、§2.3）。

## 1. 一次性前置（开通前核对，缺一不可）

| # | 事项 | 为什么是硬条件 | 出处 |
|---|---|---|---|
| 1 | 账号已实名认证、注册地为中国境内（港澳台除外）、**账户无欠款** `[需你操作]` | 欠款会连带卡住云开发开通；开通靠 DevEco 勾选协议自动完成 | docs/05 §1 |
| 2 | 数据处理位置只启用「中国」，之后**不再改动** `[需你操作]` | 云开发仅支持中国境内；更改或取消启用**可能自动清理云侧数据且不可恢复** | docs/05 §3.3 |
| 3 | 手动开启**消费提醒 + 余额不足提醒** `[需你操作]` | 免费档"用尽即停"不会自动扣费也不会自动扩容；配额提醒只有互动中心消息是默认有的 | docs/05 §3.1 |
| 4 | 运行时 Node.js（spike 实测跑在 20 上）；不要沿用旧 `@hw-agconnect` SDK 写法 | 2025-11-04 起云函数运行时收窄为仅 Node.js | docs/05 §8 |
| 5 | 服务端凭据放在**仓库外**（`ForTwoPrivate/agc-apiclient-*.json`），经环境变量交给探针 | 凭据进仓库＝进 git 历史，删不掉。云对象自身不需要它——AGC 运行时用 `PROJECT_CREDENTIAL` 注入 | `[实测]` spike 的 `server-probe` |
| 6 | 端云工程关联后记下 `CloudProgram/cloud-config.json` 的位置与里面的项目/应用 ID | 这份文件是向导产物，**永不进 git**（含 projectId/appId/teamId） | `[实测]` |

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
5. 端侧：关联签名配置 → 模拟器取 `clouddevelopproxy.debugToken` 注册到 AGC（模拟器无登录态，缺这步必然失败）
   → 按 `cloud-backend/README.md` §6 的三步探针验一次 `create → status → put`；
6. 探针用完 `unpair` 清掉测试行，别在正式项目里留脏数据。

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

- 内存与超时在 AGC 控制台按对象设：建议 128MB / 同步调用上限内；`unpair` 要给到 15s，
  它要在一次调用里删完两行快照再删会话；
- 云函数同步调用上限 55s，端侧统一 `timeout: 30000`（协议 §3.3）；**函数内部耗时必须 < 30s**，
  否则客户端先断、服务端还在写，会得到"失败但已写入"的假不一致；
- `put` 的体积阈值按协议 §4.7 的 2 MB 拒绝；云侧**不解密、不解析明文**，所以它的 CPU 与载荷内容无关；
- 版本策略见 §5：端侧写死 `$latest`，这条在 2026-09-27 是个已知限制而不是选择。

## 3. 日常巡检（每周一次，10 分钟）

| 看什么 | 在哪看 | 触发动作 |
|---|---|---|
| 三项服务的免费额度与已用量 | 项目设置 → 项目配额 | 任一项 > 60% → 查异常调用源（§4.5） |
| 云对象错误率与 P95 耗时 | 云函数监控（按对象看，不再按 8 个函数） | 错误率 > 1% 或 P95 > 3s → §4 |
| `pairing.heartbeat` 调用量 | 云函数监控 | **连续 7 天为 0** → 心跳没接线（协议 §4.6 已知缺口），距闲置回收约 5 个月，立刻修 |
| 数据库对象数 | 云数据库 | `PairSnapshot` 行数 > 配对数 × 2 → 解除配对级联删除有漏；`PairSession` 里 `REVOKED/EXPIRED` 堆积 → 正常（码不落库留存，但会话行不删） |
| 项目最后活跃时间 | **AGC 控制台**（云对象响应里没有这个字段，协议 §4.6） | 临近 6 个月 → 手动发一次调用，别等预警 30 日 |

闲置回收是本产品**最容易踩**的运维风险：双人低频意味着一个寒假不打开就可能触发（docs/05 §3.2）。
心跳的作用是把"项目级活跃"和"用户级活跃"解耦——只要还有任何一个用户在用，项目就不会被回收。

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
2. 查调用源：最常见是心跳被写成了每次进 App 都发，或 `snapshot.get` 漏传 `sinceVersion` 导致每次全量拉；
3. **不要**为绕过配额而升级按量付费——降级到"今天不同步"对本产品完全可接受（主路径是本机代录）。

### 4.5 异常调用放大（疑似被刷）

症状：云对象请求量突增、数据库对象读暴涨、出现非成员 `FORBIDDEN`。
处置顺序：AGC 侧对两个云对象加限流 → 撤销可疑会话（`pairing.unpair`）→ 通知受影响用户重新配对。
注意：载荷是加密的，被刷的最坏后果是配额耗尽与元数据（uid/pairId/version/shareLevel）暴露，不是日程泄露。
成员**之间**的伪造写入是另一件事，协议 §6.1 第 2 条已经明确本产品不防这一层。

### 4.6 「已配对但看不到对方数据」

按顺序判：`pairing.status` 是否 `ACTIVE` → 对方 `version` 是否 0（对方从没推过）→ 本机是否解密失败
（密钥失配，协议 §7）→ 本机是否把 `snapshot.get` 的"无更新"当成错误 → **HUKS 别名是否还在**
（卸载重装/清数据之后 `isKeyItemExist` 会答 false，此时任何拉到的密文都解不开）。
**禁止的处置**：为了让界面有内容而伪造对方数据，或在解密失败时自动重建密钥。

### 4.7 云侧完全不可用

预期表现：本机录入、共同时间计算、计划、冲突全部正常，只有「伴侣与同步」显示降级。
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

- `[需你操作]` 实际项目 ID / 应用 ID / 区域与 `CloudProgram/cloud-config.json` 落点；
- `[需你操作]` 两个云对象的真实部署时间、AGC 控制台里的内存/超时实配值；
- 配额水位的历史峰值（用于验证 §1 末的 0.01% 估算）；
- 真机上是否必须 `agconnect-services.json`（§1 末那条未验证边界）；
- 闲置回收预警的实际到达方式与响应流程（是否只有邮件）。

**已可以删掉的待补项**：HUKS 路线 A/B 的实测结论（协议 §6 已定路线 A，但别名生命周期仍待测，
挂在协议 §11 第 5 项，不在本手册里重复登记）。
