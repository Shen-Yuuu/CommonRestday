# 云同步时延与容量优化：本地实施验证

日期：2026-10-14。范围为用户已批准的兼容增量、独立通知候选、双端归档及缓存优先刷新。
已完成本地代码/模型/构建包；**未部署线上、未修改控制台配置、未使用服务账号密钥、未操作设备数据**。

## 已实现

- 默认兼容旧服务器/旧读取。storage-v2 初次协商后，每次健康同步用一份经过认证的 readChanges 响应验证连接、身份、伴侣公钥与密文，不再额外请求 capabilities。
  这只是协议支持记忆，不是缓存写权限。创建/确认/改期/取消继续验证服务器有效连接与本机身份/代际。
- 游标按 pair/actor/generation 隔离；先验证并持久化变化，再推进游标。页最多 50 项，单次最多 10 页；未读完报告 SYNC_MORE，不假装全部完成。
  空增量不扫描整份历史、不重复解密、不做空写入；同分钟无新变化不重复扫描归档候选。
- 共享计划待确认/仅内容变化更新卡片与角标；确认/取消/时间变化才重算占用，连续分页合并一次重算。
- 归档最多 10 项/批，双方确认同一版本、客户端判定已结束且无待确认改期，或已终态，才迁出活动表。维护请求释放用户决策队列后运行。
  完整密文历史、不可变原回执和 digest 继续保留；原请求核实可读取压缩历史回执，旧 planId 不允许复活。
- 活动计数与变化序列在原绑定 CAS 内更新。回执达到 150 后分批压缩迁移；投递终态和过时通知释放活动计数，正在投递的有效 lease 不被抹除。
- 解除先停止连接，再按数量/字节预算清理活动与归档。新清理批最多 50 项/约 1MB，归档每表读最多 25 项；未完成返回 CLEANUP_PENDING，保留原身份补删凭据。
- 通知优先处理本次操作对应的稳定事件；定时补送不让过时记录占掉 provider 名额。Push 失败不改变已经提交的业务结果。
- 新签名 wake 使用独立 insert，数据库 worker 重读实际管理员记录并校验 HMAC、对象/区、outbox、最新版本、成员通知开关和 lease。
  默认仍同步 fallback；打开异步后只等唤醒持久化，不等 provider。唤醒失败回退，保留原 outbox。
- 隐藏 Tab、被栈页面盖住的主页面、后台主页面暂停读数；重进读最新本机缓存并合并连续失效事件，不清空已有页面。
  计划读取失败保留卡片；同周刷新保留网格，在读取期间阻止旧结果点击。未引入新的布局、标题高度联动或加载闪烁动画。
- 前台计划读取不再先重复请求配对状态；明确撤销/清理异常时仍走原配对恢复。班表快照原有失败暂停/手动重试、网络外置重算队列和在途合并规则保持不变。

## 数据与模型

- 本地 schema 8 → 9：增加 shared_plan_cursor、shared_plan_archive_vote；恢复/清空/撤销/代际变更同步清理这两表。
- 新云模型七个：SyncState、Change、Archive、ArchiveVote、ReceiptArchive、EventArchive、Wake（完整名均以 PairPlan 开头）。
- 既有 PairMemberBinding 增补 storageVersion / cleanupPending，计划/回执/outbox 增补索引；权限仍仅 Administrator。
- 迁移标记是粘性的：storage 开关关闭只能阻止新迁移，不能回退已有归档连接的幂等保护。禁止回滚旧 dateplan 或删除新增表。

## 实际验证结果

| 检查 | 结果 |
| --- | --- |
| 云合同 ES2020 / ES5 | 每个目标原 57 + storage-v2 10 + wake 4，全部通过；实际 Server SDK 1.0.5 strict/noEmit 通过 |
| 客户端增量/刷新回归 | 新增 10 个生产控制流适配测试通过；原刷新性能 14 个通过；实际内存 SQLite 游标/投票/恢复/事务回滚通过 |
| offline closed / open | 两档各 typecheck 0 errors、Hypium 368 passed / 0 failed；所有附加回归和静态审计通过 |
| debug / release / ohosTest 构建 | 全通过；ArkTS WARN 分别 281 / 279 / 259，低于既有 289 / 289 / 269 基线，未上调基线 |
| perf | 通过；开发机 paired120 P50 14.1ms；60行投影 P95 0.103ms，1000行 P95 1.263ms；不是手机/云时延 |
| 同步源码 | 正式/隔离两个本地 CloudProgram：14个目录文件与12个模型，共52份目标文件逐字节哈希相同；未覆盖配置、依赖清单或凭据 |
| worker 包 | 两个 ZIP 根目录包含入口、全部依赖模块及 additional-models；生成模块可导入并导出 handler，未调用云端 |

测试覆盖 110 个累计计划/220 个请求、50/50/10 的变化分页、原请求归档后核实、planId 拒绝复活、改期/旧版本不得归档、
有效 provider lease 与归档并发、字节超限分批清理、代际变化拒绝晚到响应、旧服务器回退、错误保留卡片/网格、空增量零写入。

复跑命令：

```text
node cloud-backend/test/dateplan-storage-v2.mjs
node cloud-backend/test/dateplan-storage-v2.mjs --es5
node cloud-backend/test/dateplan-wake.mjs
node cloud-backend/test/dateplan-wake.mjs --es5
node tools/verify.mjs --steps=offline,debug,release,ohostest,perf
node tools/build-dateplan-push-worker.mjs
node tools/build-dateplan-push-worker.mjs --wake
```

完整客户端日志位于 `E:/desktop/Code/harmony/.crdtest/verify-{offline-closed,offline-open,debug,release,ohostest,perf}.log`。

## 仍需用户完成，不能用本地测试替代

按 [部署操作清单](2026-10-14-cloud-latency-capacity-operator.md) 更新模型、整个 dateplan、双方 App 与两份 worker。
独立数据库 insert 是否实际自动触发、TIMER 是否恢复自动入队、真机后台/锁屏收到通知、真实网络延迟仍未验证。
`FORTWO_PLAN_ASYNC_PUSH` 默认关闭，以上条件未通过时继续同步 fallback。释放的是活动容量，密文历史仍使用云存储配额。
