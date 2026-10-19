# AGC 共同计划独立通知派发：平台证据与上线边界

研究日期：2026-10-13。范围仅为 AppGallery Connect / Cloud Foundation Kit，不把华为云 FunctionGraph 的 API、消息队列、重试保证套用到 AGC。未登录用户控制台，未访问服务账号密钥，未创建或部署线上资源。

## 结论

1. **AGC 确实提供云数据库触发器，可独立触发普通事件云函数。**但不能直接把当前事务内 `tx.executeUpsert([event])` 当作可靠唤醒来源：官方明确排除了云侧 `executeUpsert` / `executeDelete` 批量 API。因此，当前 outbox 表配置 `onUpsert` 后就删除同步派发，是没有充分证据的做法。[触发器概述](https://developer.huawei.com/consumer/cn/doc/AppGallery-connect-Guides/trigger-introduction-0000001706837165)、[创建并配置函数：云数据库触发器及限制](https://developer.huawei.com/consumer/cn/doc/AppGallery-connect-Guides/serverless-create-and-config-func-0000001713008121)
2. **本地实际 SDK `@hw-agconnect/cloud-server` 1.0.5 未提供已查证的异步入队调用参数。**`CloudFunction.call()` 是等待 HTTP 函数执行结果的 Promise；仅接受 `name/version/timeout/data`。不应以不等待 Promise、缩短调用 timeout 或 `setTimeout` 冒充可靠后台执行。
3. 推荐准备一个**有验收闸门的独立唤醒通道**：计划与 outbox 同事务提交；事务成功后 `await` 专用唤醒对象的单条 `collection.insert()`；由专用 CloudDB 触发 worker 独立发送。SDK 的 `insert()` 使用 `executeInsert(..., 'INSERT')`，不同于官方排除的 `UPSERT` 路径；但**当前项目是否真实产生触发事件仍须控制台实测，不能把未被排除当作可靠性保证**。在此验收以及补送定时器未正常运行前，默认保留现有同步派发 fallback。

## 已确认的平台事实

### 触发器类型、事件源与入口

官方《创建并配置函数》（2026-04-16）明确：普通函数选择“事件调用”；可创建 CloudDB 触发器，事件源为项目 ID、存储区、对象类型；事件类型包括 `onUpsert`、`onDelete`、`onDeleteAll`、`onWrite`。存储区名称长度 1–20，对象类型名称长度 1–30，事件源需选择本项目已创建的资源。入口文件必须位于部署包根目录。[官方创建配置说明](https://developer.huawei.com/consumer/cn/doc/AppGallery-connect-Guides/serverless-create-and-config-func-0000001713008121)

同页的关键限制是：

> 云侧 API 批量插入（executeUpsert）/批量删除（executeDelete）以及导入数据场景不支持触发。

这里不能凭 `executeUpsert([oneRow])` 只有一个元素就推断不再是受限 API；实际接口名称和请求路径未改变。当前 `service.ts` 的计划、请求回执和 outbox 都通过事务 `executeUpsert` 写入。

官方数据库新增/更新事件是顶层对象，不是 HTTP `body`，也不是 TIMER 的 `dispatchSecret`：

```json
{
  "records": [
    { "before": null, "after": { "id": "server-generated-wake-id" } }
  ],
  "objectTypeName": "PairPlanWake",
  "naturalStoreName": "FortwoPlans"
}
```

更新事件的 `before` 为原字段对象；插入为 `null`。删除事件的 `records` 只有主键信息；清空表为 `[]`。这些字段来自[官方 event 对象说明](https://developer.huawei.com/consumer/cn/doc/AppGallery-connect-Guides/agc-cloudfunction-trigger-event-0000001620581529)。当前 TIMER worker 的密钥解析不能直接处理该事件，也不应通过信任客户端可构造的同名 JSON 字段绕过密钥。

### Server SDK 实际能力

本地一手 SDK 路径：

- `E:/desktop/Code/harmony/FortwoCloud/CloudProgram/cloudfunctions/pairing/node_modules/@hw-agconnect/cloud-server/function-service/params/functionParams.d.ts`：仅 `name`, `version?`, `timeout?`, `data?`。
- 同目录 `cloudFunction.js`：`await callable.call(data)`，然后返回结果 `getValue()`。
- `function-service/server/FunctionCallable.js`：认证后 HTTP POST；没有设置异步入队头/异步调用选项；timeout 范围 `0 < timeout <= 55000`。
- `database-service/CloudDBCollection.js`：`insert()` 调用 `executeInsert()`；`upsert()` 调用 `executeUpsert()`。
- `database-service/services/CloudDBZone.js`：前者 `handleIncrementData(..., 'INSERT')`，后者 `'UPSERT'`。

SDK 支持云函数调用云函数，但这不能证明其调用会独立入队。官方 Server 调用文档要求被调函数 HTTP 触发器选择“API 客户端鉴权（Server 适用）”；示例是调用并取得函数结果。[官方 Server 调用函数](https://developer.huawei.com/consumer/cn/doc/appgallery-connect-Guides/server-java-call-function-0000001513186468)

## 推荐实施设计（候选，尚需平台验收）

### 资源与权限

- 新对象 `PairPlanWake` 放入现有 `FortwoPlans` 存储区：服务端生成主键、outbox event ID、创建时间；不保存计划明文、Push Token 或密钥。
- World / Authenticated / Creator 均无读写权限；只允许 Administrator 使用服务端身份写入和清理，沿用本项目现有 outbox 的权限隔离。
- 新普通事件函数例如 `dateplanwake`：**仅数据库触发器**，事件源限定该对象，选择 `onUpsert`；不要创建 app / HTTP 公共触发器。
- 现有 `dateplanpush` 保持 TIMER / 人工密钥保护的补送职责，不把数据库事件解析兼容和密钥绕过塞到同一个公开入口。
- worker 只按事件主键重读 durable outbox；校验实际存储区/对象名、待发状态、最新计划版本、连接是否有效、通知开关、目标 Token；触发字段只是唤醒线索，不能作为授权或发送依据。

上述资源配置由开发者在正确项目/数据处理位置完成；不要求新增端侧权限或重新更换 App 证书。云函数服务身份、模型权限和 Push 服务账号仍按现有云侧权限配置，密钥不得进入 App 包或事件值。

### 快路径与失败处理

`mutate`：鉴权 → 计划/outbox/幂等回执事务提交 → 等待一条唤醒记录的插入确认 → 返回原业务结果。

worker：数据库事件 → 单事件 outbox 查询 → 原子领取 lease → 最新版本校验 → Push provider → 保存完成状态。

只有在确认插入会自动触发、发送确实在独立函数完成后，才开启“只等唤醒入库、不等 Push provider”的配置。默认关闭该模式，避免配置不完整时通知静默丢失。

事务与唤醒插入之间不是同一个原子事务，因此存在进程退出/插入失败的缺口；durable outbox 加已验收的定时补送才能覆盖该缺口。唤醒写入失败不能将已成功的计划回滚或对用户报告为创建失败，否则会制造重复创建。可以有限尝试同步 fallback，但不能裸 fire-and-forget。

### 实测闸门

1. 在测试连接提交一条通知事件；记录事务成功与唤醒 insert 成功的安全日志（固定 stage / 耗时 / 不含密文或凭据）。
2. 不手动执行 worker、不保持 App 存活，确认独立 `dateplanwake` 有新增调用记录，包含预期对象/存储区且业务派发日志出现。
3. 两台真机后台、锁屏验证；记录 provider 接受与手机收到的区别，不能把 HTTP `OK` 当作到达保证。
4. 用同一事件重复触发，验证 lease / 完成状态避免重复；并发确认、撤回、取消与解除连接后，不发送过时消息。
5. 模拟领取后退出/临时网络失败，验证定时 worker 能在 lease 到期后恢复。现在已知 TIMER 只有手动调用记录，此项仍未通过，正式上线前应解决或另设经过验证的独立补送服务。

## 明确未确认的事实

- 本次官方资料没有给出 CloudDB 触发器投递 exactly-once、时延上限、顺序保证、自动重试次数和保留期限；实现必须允许重复、乱序、延迟，并自行维护 outbox/lease/幂等。
- `executeInsert` 在本项目、当前云端区域、当前 SDK 版本能否产生独立触发，未实测。
- 事务写入能否直接触发（官方已明确排除 executeUpsert 路径），不作正面保证。
- 未找到 AGC Server SDK 的受支持异步调用入队参数，或可直接替代本项目 TIMER 的平台队列 SDK；不据此断言平台永远不存在，而是当前实现没有足够依据使用。
- 用户控制台定时器无自动入队/调用的问题未被本研究修复；需要 AGC 支持侧排查或实际重新验证，不是换事件解析就能保证解决。

## 获取证据的方法

华为页面是 JS 文档站，网页抓取仅返回壳。具体创建配置和 event 文档的正文通过文档站自身使用的公开只读 `documentPortal/getDocumentById` 接口获取（`objectId` 为完整文档 slug，`catalogName=AppGallery-connect-Guides`, `language=cn`, `showHide=0`），并核对 `updatedDate` 和正文。没有使用登录 Cookie、用户凭据或控制台私有 API。所有外部结论只来自以上华为官方文档；SDK 结论来自本项目已安装的华为 SDK 实际源码。

## 补充：索引的精确结构与首版部署要求

### 对象类型 JSON

官方《创建对象类型》（2026-10-10 更新）确认 `indexes` 每项有 `indexName`、`indexList`；`indexList` 每项包含 `fieldName` 和 `sortType`。支持组合索引，最多 5 个字段；单对象最多 16 个索引；`ByteArray` / `Text` 字段不支持索引。索引名 1–30 字符、字母开头，仅字母数字下划线，不区分大小写。[官方对象类型说明](https://developer.huawei.com/consumer/cn/doc/harmonyos-guides/agc-harmonyos-clouddev-objecttype)

本地华为 DevEco 插件 `D:/local/DevEcoStudio/plugins/harmony/lib/deveco-cloud-toolkit-16.6.1.302.jar` 中 `fileTemplates/internal/json File for object type.json.ft` 的一手模板直接包含相同 JSON 结构，以及 `ASC` / `DESC` 枚举样例。因此 `pairId + sequence` 的精确结构为：

```json
{
  "indexes": [
    {
      "indexName": "pairSequenceIndex",
      "indexList": [
        { "fieldName": "pairId", "sortType": "ASC" },
        { "fieldName": "sequence", "sortType": "ASC" }
      ]
    }
  ]
}
```

字段排列和排序方向按查询实际形状定义，不能只增加字符串形式的字段列表而省略 JSON 中的排序方向。

### Server 模型 `getIndexList()`

同一官方插件 `fileTemplates/internal/object_type_server_model.ts.ft` 定义：

```ts
getIndexList(): string[] {
  let indexList: string[] = [];
  // 模板对每个 index 执行 indexList.push(index.indexFields)
  return indexList;
}
```

对 `com.huawei.deveco.projectmgmt.agc.model.CloudDbObjectModel$IndexItem` 使用本地 `javap -c -p` 只读检查，`getIndexFields()` 顺序遍历 `indexList`、在字段名之间追加逗号 `,`；**不拼接索引名、不拼接 sortType**。所以前述复合索引对应：

```ts
getIndexList(): string[] {
  return ['pairId,sequence'];
}
```

若还有单字段 `pairId` 索引，则 `return ['pairId,sequence', 'pairId'];`。不是 `['pairId', 'sequence']`（那表示两个单字段索引），也不是 `[{indexName,...}]`。线上 JSON 与生成模型需要同步更新，优先让 DevEco 按对象类型重新生成，以避免字段反射漂移。

### 是否强制索引

需区分查询方法，不能概括为“一律必须”或“一律可省略”。官方 Node.js `CloudDBZoneQuery`（2025-01-16）规定：

- 单独排序 `orderByAsc` / `orderByDesc`：**建议**为排序字段建索引，否则数据较多时可能超时或失败。
- `startAt` / `startAfter` 与排序组合：**必须创建排序对应的字段索引**；未建可能抛出缺少索引的异常。
- 排序方法放在过滤条件后、`limit` 前；tuple 游标放在等值和排序后、`limit` 前。
- 单次 `get()` 结果不能超过 1000 条或 20 MB，历史全量回补必须分页，而不是单次读取不断累积的归档。

这些规则来自[官方 Node.js Query API](https://developer.huawei.com/consumer/cn/doc/AppGallery-connect-References/clouddb-clouddbzonequery-server-nodejs-0000001766572401)。同服务的 Server Java 指南也明确要求分页之前先建查询所需索引，未建可能异常。[官方分页说明](https://developer.huawei.com/consumer/cn/doc/AppGallery-connect-Guides/agc-clouddb-otheroperations-serverjava-0000001569826505)

`equalTo(pairId) + greaterThan(sequence) + orderByAsc(sequence) + limit(...)` 是否在每种数据规模都会无索引被硬拒绝，官方文档没有给出普遍保证。实施时仍应在首版部署正确复合索引，将索引可用作为分页验收前提；不要靠小数据量偶然查询成功判断无须索引。

### 本项目首版索引建议（按实际查询确认，不替代实现设计）

| 查询用途 | 建议字段顺序 | 模型返回字符串 |
| --- | --- | --- |
| 单连接变化增量：pairId 等值、sequence 范围、sequence 升序 | pairId ASC, sequence ASC | `pairId,sequence` |
| 归档按连接查找／分批解除连接清理 | pairId ASC | `pairId` |
| 归档或回执按连接与创建时间排序清理（若实现使用此查询） | pairId ASC, createdAt ASC | `pairId,createdAt` |
| 按过期时间筛选维护（若实现采用全局 expiresAt 游标） | expiresAt ASC，再加稳定主键 id ASC（若时间不唯一） | `expiresAt,id` |

变化 `sequence` 需在同一 pair 内严格单调且唯一。如果不唯一，分页要追加稳定 `id` 作为排序／游标字段，索引相应 `pairId,sequence,id`，否则跨页会漏掉同序号记录。对于单独 `pairId` 查询，未找到官方保证复合索引左前缀优化，因此首版可配置显式 `pairId` 单字段索引，不依赖未确认的优化器行为。没有实际查询就不要无目的添加所有索引。

## 补充：wake 证明不能替代授权

以下是安全设计要求，不是平台自动提供的保证：仅 Administrator 可写 wake 对象，可阻止普通客户端直接伪造存储记录；HMAC 可证明 wake 字段由掌握云侧秘密的服务生成，但不能仅因事件“长得像 CloudDB 事件”就发送通知。

建议 worker 使用专用云侧 HMAC 秘密（不随事件发送、不进入 App），验证带版本/用途域隔离的规范字符串；证明至少绑定 wake ID、outbox event ID、pair ID、创建/过期时间及对象/存储区身份。固定字段编码须消除拼接歧义，使用固定字段序列或长度前缀，并且长度检查后恒定时间比较 MAC。

真实授权还要求：按 wake 主键重读云数据库中实际服务器记录，验证 proof 与持久记录一致、仍在有效期内，再读取绑定的 outbox 和最新连接／计划状态，执行已有原子 lease／幂等和通知开关检查。事件中的 `after` 只能给出需要查询的线索，不能直接携带任意目标 Token、明文标题或任意 pair 作为发送命令。

重复投递不应被当作安全失败；保持幂等，必要时用同一 wake/event ID 重试。伪造模型名、存储区名、MAC 缺失、字段改写、过期 proof、跨 pair/event 挪用都应拒绝，并只记录固定分类，不打印 HMAC 秘密、proof、密文或 Push Token。HMAC 自身不提供 exactly-once，管理员/云函数服务身份被攻破也不在其防护范围内。
