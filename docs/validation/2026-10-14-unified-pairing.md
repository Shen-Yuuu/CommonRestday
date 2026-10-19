# 一次配对：部署与双端验证

日期：2026-10-14。本次实现用户已确认的统一流程：只输入一次配对码、邀请方确认一次，自动建立班表同步和共同计划连接。共同计划仍需逐条由对方同意，通知仍单独授权。源码已更新不等于云端已部署。

## 用户看到的变化

- “伴侣与同步”中移除独立“共同计划连接”的生成短码、输码、确认、单独解除入口。只有原来的云配对入口。
- 两项都完成才显示“已配对”；中间阶段显示等待/连接待完成。没有伪造同步或连接成功。
- 已有两项 ACTIVE 连接直接保留，不修改计划/日程。只有班表连接的旧用户，两端各点一次“完成连接”，不再交换第二个码。
- 仅已授权的当前班表关系可自动续接。前台可见弹窗每 3 秒单飞检查，最长 60 秒；关闭弹窗、切后台停止后续检查。网络/校验失败持久化暂停，回前台不会偷偷重放，用户点击“继续连接”才恢复。
- 统一“解除配对”先撤销共同计划，再清理班表；失败保留所需凭据，仍可重试。发起方创建回包丢失可按原 flowId 撤销；自动加入回包丢失可用密文中已核实的 pairId 撤销，不猜别人的连接。
- 极少数旧的多份未完成连接会提示冲突，不任取一份、不删除历史或替换另一份。交接过期、设备密钥丢失、原认证身份不在也不静默重新创建；需核实或由用户通过统一解除处理。

## 必须按顺序部署

1. 在 DevEco 打开正式云项目 `E:/desktop/Code/harmony/FortwoCloud/Application`，核对 AGC 正式“两人份”项目/数据处理位置。CloudDevSpikeOfficial 是隔离测试项目，不把主 App 切过去。
2. 本地 `CloudProgram/clouddb/objecttype/PairMemberBinding.json` 已同步。本次不新增对象，而是在现有 PairMemberBinding 增加：
   - `bootstrapRoute`：String，默认空字符串；新增 bootstrapRoute 索引。
   - `bootstrapOffer`：Text，默认空字符串。
   右键 clouddb 部署，保留原区、原字段、原数据和 Administrator-only 权限。若要求删表/重建区，停止并提供提示，不清数据。
3. 右键 `CloudProgram/cloudfunctions/dateplan` 部署整个目录。必须包含新 `bootstrap.ts`、更新的 `dateplan.ts`、`service.ts` 和 `models.js/.d.ts`，不能只替换入口。保留 `dateplan.DatePlan`、SDK 1.0.5、原鉴权和平台服务身份。无需改 pairing/snapshot。
4. 保留已有项目 ID、计划区、共享计划/Push 开关、服务账号变量、dispatch secret。此次统一流程不新增环境变量。此前增量同步/归档的开关继续按其部署说明配置；`FORTWO_PLAN_ASYNC_PUSH` 在自动触发/补送未验证前仍保持 false。
5. 如已部署 dateplanpush/dateplanwake，更新本次重新生成的 ZIP，保持原入口 `dispatch.handler` / `wake.handler`、环境变量和触发器。此处只为模型反射同源，不要求重新生成任务密钥或重建触发器：
   - `E:/desktop/Code/harmony/.crdtest/dateplanpush.zip`
   - `E:/desktop/Code/harmony/.crdtest/dateplanwake.zip`
6. 打开主项目 `E:/desktop/Code/harmony/CommonRestday`，双方都覆盖安装新版 App。不要卸载、清数据、更换匿名身份、重新配对；本次无需增加手机权限、Push 权益、证书或 Profile。

## 双端验证

### 新配对（只在可丢弃测试关系测试，不解除正在用的正式关系）

1. A 在“我的 → 伴侣与同步”生成配对码，B 输入这一组码。
2. A 点“检查并确认配对”，确认一次。B 无需第二次输码。
3. 两端保持弹窗打开、应用在前台。中间可显示“正在完成连接/等待 TA”；完成后两端应显示“班表同步 · 共同计划均已连接”和已配对状态。
4. A 创建共同计划，B 看到待确认且不占用空闲；B 同意后两端参与计算。
5. 不开启计划通知时不应自动申请系统通知或登记 Push Token。开启通知仍从“共同 → 计划”主动操作。

### 已有连接升级

1. 两条链路早已 ACTIVE：直接打开新版，已有计划与班表保留，不出现第二套短码，不生成另一份绑定。
2. 只有班表：双方分别点“完成连接”，保持前台，后续自动交接。
3. 某方原本已有未完成的共同计划：优先沿用原 flowId、公钥及密文证明，不重复生成。多份候选或对方不匹配时停止并提示，不自动决定替换哪一份。

### 失败、生命周期和解除

1. 测试中途断网：保留原进度，恢复网络后点“继续连接”；检查没有再次创建另一份 flowId。
2. 失败后切后台再回来：不自动重放失败流程。弹窗检查到 60 秒上限后也应停止自动检查。
3. 云调用未结束时关闭弹窗/切后台：晚到回包不能再改已关闭界面；不能常驻轮询。
4. 点击统一“解除配对”：不再需要单独解除共同计划。网络失败或 CLEANUP_PENDING 时保留凭据，再次解除/继续清理；不要提前卸载。
5. 清空本机后，旧异步回包不能恢复旧会话或旧密钥投影。

## 安全与证据边界

内部交接使用原班表密钥随机 nonce AES-GCM，AAD 绑定旧 pairId；密文绑定发送/接收旧 UID、新 pairId、公钥、短码和有效期。发现接口仅返回加密信封与公钥/连接 ID；route 哈希不是认证凭据。客户端解密核对后才 join，服务端继续验匿名 token；确认前仍验证现有伴侣的密钥证明。不得把旧 UID 当作 AGC 认证主体，不能用配对短码派生长期密钥。

云端自动触发、真机 HUKS、真实网络耗时、后台/锁屏通知没有由本次离线测试替代，仍需上述设备验收。没有操作真实 AGC、设备数据、服务账号或签名。

## 验证命令

```powershell
node tools/test/unified-pairing-regression.cjs
node tools/test/secure-pairing-regression.cjs
node cloud-backend/test/dateplan-bootstrap.mjs
node cloud-backend/test/dateplan-bootstrap.mjs --es5
node cloud-backend/test/dateplan-unified-flow.mjs
node cloud-backend/test/dateplan-unified-flow.mjs --es5
node cloud-backend/test/dateplan-storage-v2.mjs
node cloud-backend/test/dateplan-wake.mjs --es5
node tools/verify.mjs --steps=offline,debug,release,ohostest,perf
```

本轮新增协调器/实际 UI 方法/交接加密/原班表取消竞态用例 22 条，原安全配对扩充为 37 条，服务器交接 6 条，真实服务端与 ArkTS 流程离线串联 2 条。服务器用例导入时会重复运行原 57 条契约，不把重复运行当新增用例。ohosTest 构建不等于真机运行。

最终本地门禁：`node tools/verify.mjs --steps=offline,debug,release,ohostest,perf` ALL PASS。

- offline 关闭/开启两档：typecheck 0 errors，各 368 Hypium passed / 0 failed，附加用例与静态审计均通过。
- Debug / Release / ohosTest 构建成功；ArkTS 告警分别 281 / 279 / 259，未增加，也未放宽基线。
- 性能检查在预算内；它是开发机计算/投影测试，不是云端时延测量。
- 服务器原 57 条、bootstrap 6 条、unified integration 2 条、storage-v2 10 条、wake 4 条均通过；覆盖 ES2020/ES5 服务端转译与真实 SDK strict/noEmit。
- 两份云项目本次更新的 14 个源文件/模型目标 SHA256 同源；两份 worker ZIP 根入口、839 个条目、模型内容与模块导入通过。
- `git diff --check` 通过。没有线上部署、真机安装、真实凭据读取或数据库清空。

测试顺序：服务器新入口先验证缺失方法的失败，再实现；客户端协调与 UI 用例随实现扩充，不将本轮描述成全程测试先行。
