# Plan Storage Long and Header Alignment Implementation Plan

> **For agentic workers:** Inline execution; no delegation or automatic commits over user changes.

**Goal:** 修复用户日志 mutate.tx.plans/BAD_COUNTER 的 SDK Long 类型不匹配，并让共同休时标题/注释成组对齐右侧角色底边。

**Architecture:** CloudDB additional-models 的 Long getter 严格转换规范十进制字符串/安全数字；不迁移、不清零、不删除任何计数或回执。客户端保留 BAD_COUNTER 诊断与原请求。页头左侧 Column 与角色同一 Row 底部对齐、相同 3vp 绘制偏移。

**Tech Stack:** Node/TypeScript Server SDK 1.0.5，ArkTS/ArkUI，离线实际 SDK deserialize 回归。

**Spec:** 用户 FORTWO_DATEPLAN_DIAG 日志和后续标题对齐要求；源码 storageHead / changePage 的整数约束。

## Global Constraints

- 不改变模型字段/索引、存储区、鉴权、密钥、环境变量或推送投递模式。
- 不重新配对、不生成新 requestId；继续原请求核实和幂等重试。
- 历史数据非法时保持拒绝，不做 Number(null/空串)→0，不放宽安全整数范围。
- 只保留页头已有眨眼和点击响应，不添加其他动作。
- 同步本地 FortwoCloud 与 CloudDevSpikeOfficial 源码，不擅自部署在线资源。

### Task 1: SDK Long 边界与计划原请求恢复

**Files:** cloud-backend/cloudfunctions/dateplan/additional-models.js，cloud-backend/test/dateplan-contract.mjs，cloud-backend/test/dateplan-storage-v2.mjs，feature/src/main/ets/model/SharedPlanDiagnostic.ets，SharedPlanPresentation.ets。

- [x] 测试仓库的查询读出走实际 Server SDK Utils.deserializeObjects，让 Long 字段与线上一样为十进制字符串。
- [x] 运行 `node cloud-backend/test/dateplan-storage-v2.mjs`，确认旧代码在新增计划遇到 BAD_COUNTER。
- [x] additional-models.js 的 Long getter 使用严格转换，Number.isSafeInteger 与非负校验均保留；不改 raw 字段或 schema。
- [x] 增加 9→10 非拼接、最大安全整数/越界/空白/布尔/小数拒绝、原请求回执恢复和增量读取回归。
- [x] 客户端保留 BAD_COUNTER/STORAGE_NOT_READY 原码，显示可操作提示，待核实状态仍锁住原请求。
- [x] 跑 server ES2020 / ES5、storage-v2、bootstrap/unified/wake、客户端原请求回归。
- [x] 校对已有云工程副本一致后同步修复，重建两份 worker ZIP（包含同一 additional-models），不在线部署。

### Task 2: 标题注释与角色底边成组对齐

**Files:** entry/src/main/ets/view/CoTimeView.ets，tools/test/companion-motion-regression.mjs，docs/prototype/companions-layered-2026-10-17.html。

- [x] 测试约束 subtitle 必须在与 title 同一 Column 内，和角色同一 Row，底对齐且偏移同为 3vp。
- [x] 调整 header 的标题/备注嵌套，保留原字体、文本、颜色、headerWidth、active 和 sheet 播放门禁。
- [x] 原型同步左侧文字组；编译验证 `scripts/run.ps1`，全量离线验证，记录原生未验收边界。

### Handoff

- [x] 写清先重新部署整个 dateplan 云对象、两个 worker 替换包（如已部署），再覆盖主 App；不改 CloudDB 模型、不关 storage-v2。
- [x] 用现有邀请点“核实 / 重试”，不要新建一条或清数据；双端确认与增量读取仍需用户在线复测。
