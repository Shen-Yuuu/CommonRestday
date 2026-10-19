# 计划邀请 BAD_COUNTER：Long 读取修复及部署步骤

## 已定位原因

用户提供的 dateplan 诊断为 `operation=mutate`、`stage=mutate.tx.plans`、`code=BAD_COUNTER`。本地在计划存储读取路径中复现了同一错误：

1. `PairPlanSyncState.sequence / creatorAck / recipientAck` 是 CloudDB **Long** 字段。
2. 项目安装的 Server SDK 1.0.5 `Utils.deserializeObjects` 保留它们的十进制字符串表示，Integer 字段则转成 number。
3. 原生成模型 getter 直接返回 raw 字段，但声明为 number；`storageHead` 的 `Number.isSafeInteger('0')` 为 false，首条计划即被拒绝。
4. 客户端诊断码白名单又漏了 BAD_COUNTER，所以屏幕上显示 RESULT_UNKNOWN，掩盖真正错误。不是当前客户端加密/解密失败的证据，也不是配对码鉴权问题。

## 修复边界

- `additional-models.js` 的 Long getter 严格接受非负安全整数或规范十进制字符串。拒绝空串、空白、null、undefined、布尔、小数、指数串、负数与超安全整数；不默认归零、不放宽 counter 检查。
- 同一边界覆盖增量 change cursor、双方 ack、归档时间和签名 wake 时间戳，避免创建通过但后续同步/worker 仍因 Long 表示失败。
- 字段与索引完全不变；没有迁移、重算、删除或清零线上数据，没有更换密钥/配对/请求 ID。
- 客户端保留 BAD_COUNTER / STORAGE_NOT_READY 的原始安全码和云端诊断编号，持续显示存储提示；保留原请求、锁住重复新建，并支持修复后的原请求核实/重试。
- 服务端诊断版本改为 `2026-10-17-counter1`，便于确认失败日志是否来自新部署。
- 标题/注释作为同一左侧 Column 与角色在同一 Row 底部对齐，双方绘制偏移同为 3vp；不新增动画，保留仅眨眼和点击反馈。

## 本地验证

- 测试存储的普通查询和事务查询现在都调用**实际安装的 SDK 反序列化函数**，不再用 structuredClone 假装线上类型。无真实云访问。
- 修复前：`node cloud-backend/test/dateplan-storage-v2.mjs` 第一条 v2 计划断言得到 BAD_COUNTER；复现日志 `../.crdtest/long-counter-before.log`。
- 修复后：server contract **57/0**、storage-v2 **12/0**，ES2020/ES5 均通过；bootstrap **6/0**、unified integration **2/0**、wake **4/0**。包含 9→10 非拼接、全部新增 Long getter、坏值拒绝、原请求恢复与幂等回执、110 条历史计划及回执归档、双端投票和在途通知计数。
- 客户端真实 UseCase / fake ports：BAD_COUNTER 后原请求仍在，部署修复后先查询回执再按同一 requestId 发送，不生成第二条；原请求、HUKS/Auth/网关回归 **38/0**。
- ArkTS 技能 `scripts/run.ps1`（ohpm install --all + assembleApp）：**BUILD SUCCESSFUL**，日志 `../.crdtest/counter-header-build.log`。
- `node tools/verify.mjs --steps=offline`：ALL PASS，closed/open 各 **368 passed / 0 failed**，两档 typecheck 均 0 errors。初次新增测试桩缺 list 方法已补齐，未修改生产逻辑绕过该失败。
- 两个部署副本的 additional-models.js SHA256 与主源码一致；两个 worker ZIP 内 additional-models.js 内容与主源码完全一致。ZIP 为本地构建产物，未上传 AGC。

源码已同步到：

- `CommonRestday/cloud-backend/cloudfunctions/dateplan/`
- `FortwoCloud/CloudProgram/cloudfunctions/dateplan/`
- `CloudDevSpikeOfficial/CloudProgram/cloudfunctions/dateplan/`

两份已重新生成的 worker 包位于：`E:/desktop/Code/harmony/.crdtest/dateplanpush.zip` 和 `dateplanwake.zip`。

## 你需要执行

1. 在用于**正式项目**的云工程中，重新部署整个 `dateplan` 云对象目录（FortwoCloud 和 CloudDevSpikeOfficial 两处本地修复一致，只部署实际关联正式项目的一处）。不能仅部署入口 `.ts`，必须带上更新后的 `additional-models.js`、`identity.ts` 和其他现有依赖。
2. 本次**不需要**更新 CloudDB 模型/索引、环境变量、证书或 Profile；不要关闭 STORAGE_V2、不要清表/删除 PairPlanSyncState、不要解除配对。部署后只复核原项目、区、环境变量与超时未被向导覆盖。
3. 若已部署 `dateplanpush` / `dateplanwake`，分别上传上述新 ZIP 更新代码版本，保留原入口 `dispatch.handler` / `wake.handler`、环境变量和现有触发器配置，不新建重复触发器。它们也读取相同模型；旧包不能验证新模型兼容性。
4. 覆盖安装当前主 App（包含诊断显示及标题调整），不卸载、不清数据。
5. 对现有那条待核实邀请点击一次「核实 / 重试」。客户端先查原回执；未提交才用同一 requestId/密文重发。不要另建一条邀请替代。
6. 成功标准：A 看到待对方确认，B 看到同一邀请；B 同意后双方显示已确认、周历占用更新；下拉刷新不再返回 BAD_COUNTER。若仍失败，提供新诊断；新云端日志应带 `2026-10-17-counter1`，若仍是 diag2，先检查部署到了哪个项目/版本。

线上部署、真实 CloudDB 事务、推送自动触发和原生标题视觉仍需设备复测，本地通过不等于已在线修复。旧数据若确实包含非法/越界值，新代码仍会拒绝，不擅自改成零。
