# 本次云同步优化：部署与双端验证步骤

日期：2026-10-14。代码已实现，不代表已部署到你的 AGC，也不代表自动触发或锁屏通知通过。
正常升级不需要卸载、清空手机数据、重新配对或更换证书/Profile；保留当前连接与密钥。

## 可以先上线的部分

可先更新模型、云对象、双方 App 并启用增量同步/归档；独立通知可以稍后开通。
`FORTWO_PLAN_ASYNC_PUSH=false` 时继续同步发送**本次事件**，不会先处理旧队列；通知失败不会把已提交计划报为创建失败。
真实网络、匿名认证、云端冷启动仍有耗时，不能承诺所有设备立即完成。

## 1. 部署云模型，保留旧区和旧数据

1. 正式 App 使用 `E:/desktop/Code/harmony/FortwoCloud/Application`，关联正式“两人份”项目。
   `CloudDevSpikeOfficial` 只用于其原有隔离项目；不把主 App 切到隔离项目，不搬运匿名身份/密钥/连接。
2. 源码已同步到两个工程的 `CloudProgram/clouddb/objecttype`。DevEco 刷新后，右键 clouddb → Deploy Cloud DB（菜单名称以当前版本为准）。
3. 发布七个新增对象：
   - `PairPlanSyncState`：连接序列、活动数量、成员同步进度。
   - `PairPlanChange`：每个计划的最新密文变化；不是每次操作都无限复制一份。
   - `PairPlanArchive`：最终密文历史。
   - `PairPlanArchiveVote`：指定成员/版本的归档确认。
   - `PairPlanReceiptArchive`：压缩的原响应、防重复证明。
   - `PairPlanEventArchive`：结束投递的审计。
   - `PairPlanWake`：签名通知唤醒线索，不含密钥/Token/计划明文。
4. 更新现有对象：`PairMemberBinding` 添加 `storageVersion`（Integer，默认 1）、`cleanupPending`（Boolean，默认 false）；
   `PairDatePlan` 添加 pairId+pendingExpiresAt 索引；`PairPlanRequest` 添加 pairId+createdAt 索引；
   `PairPlanOutbox` 添加 pairId+planId、status 索引。其余新增模型的索引以已同步 JSON 为准，不手抄不同结构。
5. 在当前计划专用区确认这些对象可用：正式一般为 `FortwoPlans`，隔离此前为 `FortwoPlanProbe`，以你已有 `FORTWO_SHARED_PLAN_ZONE` 为准。
   所有对象只允许 Administrator 读/写/删除，World / Authenticated / Creator 不开放权限。
6. 如果控制台要求删除区、清表、重建原模型才能更新，停止并提供提示，不用清空数据来绕过。

## 2. 部署 dateplan 与双方 App

1. 右键 `CloudProgram/cloudfunctions/dateplan` → Deploy，部署整个目录（包括 additional-models.js/.d.ts、storage-v2.ts、wake.ts）。
   保留 Node Server SDK 1.0.5、原云对象入口 `dateplan.DatePlan`、原鉴权设置与平台注入凭据。
2. 保留原环境变量和 Push 账号；增加以下值，先都关闭：

```json
{
  "FORTWO_PLAN_STORAGE_V2": "false",
  "FORTWO_PLAN_ASYNC_PUSH": "false"
}
```

这只是要增加的两个字段，不是让你替换现有全部配置。保留项目 ID、区名、共享计划开关、Push 开关、服务账号分段变量及 dispatch secret。
3. 双方都覆盖安装新 App。升级后本地 schema 从 8 升为 9，增加会话隔离游标和归档投票记录，不删除班表/计划。
4. 确认原连接可读、创建/同意/撤回/取消仍正常，再将 dateplan 的 `FORTWO_PLAN_STORAGE_V2` 设为 `true`，重新发布/保存当前有效版本。
5. 读一次或操作一次会把该连接原地迁移为 storageVersion=2。无需重新生成短码。

验证：A 创建，B 下拉读到待确认；B 同意，双方周历占用正确；取消后双方活动列表不显示；切 Tab 不清空卡片、不触发重复整页重算。
在本机日志找 `FORTWO_PLAN_RPC_TIMING`：第一次支持协商可有 capabilities+readChanges，以后的健康增量读取应主要是一次 readChanges；无变化时不重复解密全部计划。
必要的结束版本归档会另有 acknowledge 调用，最多 10 项/批；它不占住用户决策写队列。

## 3. 重新部署补送 worker

本机已生成：`E:/desktop/Code/harmony/.crdtest/dateplanpush.zip`。

1. AGC → 正确项目/数据处理位置 → 云函数 → 原 `dateplanpush`，上传此 ZIP，入口 `dispatch.handler`，Node.js 20。
2. 环境变量沿用该项目/区/Push 账号、原 `FORTWO_PLAN_DISPATCH_SECRET`。该 secret 是你原先生成的服务器随机值，不是 JSON 文件里的某个字段。
   不复制系统保留变量或把 Push 密钥传给 App。两份 worker 与 dateplan 的 secret 必须一致。
3. 保留原定时触发器和 secret 事件值；手动执行只能证明入口能运行，不能证明自动调度。
4. 你此前的自动 TIMER 尚未验证成功。先不点手动执行，跨过至少两个配置周期，检查调用次数、入队情况和 `FORTWO_PLAN_PUSH` 日志。
   如果仍只出现手动调用，保留截图和时间段向 AGC 支持排查；本次代码没有宣称能修复平台未入队问题。

## 4. 新增数据库 worker（异步投递的候选通道）

本机已生成：`E:/desktop/Code/harmony/.crdtest/dateplanwake.zip`。

1. 创建普通事件云函数 `dateplanwake`，上传 ZIP，入口 `wake.handler`，Node.js 20。它不是云对象，也不用端侧直接调用。
2. 环境配置与补送 worker 同项目/区/Push 账号/secret。保持可访问 CloudDB 的平台服务身份；不要拿 Push 账号代替 CloudDB 身份。
3. 添加云数据库触发器：事件源选择当前计划区、对象 `PairPlanWake`，事件选择 `onUpsert`；启用触发器。
   **不要**配置 HTTP、App、API 网关或 TIMER 触发器，也不要对 PairPlanOutbox 的事务 upsert 设置触发器代替这一步。
4. SDK 的独立 insert 与事务 upsert 不是同一条路径。当前候选使用独立 insert，但是否自动触发，必须在你的实际云环境验证。
5. 在隔离项目/可丢弃测试连接中短暂设置 dateplan `FORTWO_PLAN_ASYNC_PUSH=true`，创建一个新邀请。
   不手动执行 dateplanwake；应出现新增调用和 `FORTWO_PLAN_WAKE` / `2026-10-14-wake1` 日志。
   dateplan 的 `FORTWO_PLAN_NOTIFY_PATH` 应显示 `DURABLE_WAKE`，且发送由独立 worker 完成。
6. 如果没有自动调用、日志出现 WAKE_REJECTED/PUSH_DEFERRED 或手机没有收到，立即恢复 async=false；原 outbox 保留，恢复同步路径并检查配置。
   不在日志或聊天里粘贴 Token、完整事件记录、服务账号或 secret。
7. **正式开启条件**：数据库自动触发、定时补送、双端后台/锁屏通知都通过。此前 TIMER 未自动执行的问题未解决前，正式 async 继续 false。

独立模式仍需等待鉴权、事务和唤醒入库，但不等待 Push 网络结果。事务提交与唤醒 insert 之间存在崩溃缺口，因此不能省略可靠补送。
providerAccepted=1 只代表推送服务接受，不代表手机已展示；lease/固定通知 ID 降低重复，不宣称 exactly-once 到达。

## 5. 双端验收与回退

- 保留已有配对，重复前后台与切页；同一在途读取应合并，失联仍保留最后有效缓存。网络状态未知不自动重发原用户决定。
- 归档测试只用可丢弃连接：同步已结束/取消的同一版本，确认双方投票后移出活动表，密文历史与原请求证据还在。
  待确认改期不能因原计划已结束而归档；旧请求核实仍返回原响应；归档后的同名 planId 不能重新创建。
- 测试解除：有很多历史时可以返回 CLEANUP_PENDING，表示连接已停止而删除尚未结束。再次解除/手动继续云清理直到 OK；不要提前卸载或清本机凭据。
- 若出现异常，async=false 可以立即恢复同步投递。storage=false 只阻止新的连接迁移，已经为 v2 的连接继续使用其归档/增量保护。
  **不要回滚旧版 dateplan 或删新增表**：旧服务器不知道历史与防重复证明，可能错误重建已归档 planId。
- 密文历史保留会使用 AGC 存储配额。释放的是活动容量，不是无限/零成本云存储；需监控项目配额和费用。

这次不要求新增手机权限、重新申请 Push 权益或更换证书；现有通知授权与配对方开关仍必须由用户明确开启。
