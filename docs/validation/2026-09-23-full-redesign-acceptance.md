# 全阶段改造独立验收与发布整改方案

> 验收日期：2026-09-23  
> 代码基线：`2e146fc`，当前工作树另有 `PaintMonth.ets`、`ScheduleEditor.ets` 两个用户 WIP  
> 核验方式：提交与源码静态审计、本机 API 26 SDK 声明、clean release 构建、ohosTest 编译、离线测试与性能脚本  
> 总结论：**工程实现有条件通过；发布验收不通过（NOT RELEASE READY）**

## 1. 执行摘要

阶段 0–2、4–6 的主要代码和文档骨架已经形成，重构不是失败项目，也没有必要推翻重来。精简三入口、答案优先首页、日程命令编排、计划读模型、玻璃视觉试点、响应式、无障碍、卡片、提醒、迁移和回退文档均有真实提交与实现支撑。

但“所有阶段已完成”不能作为当前正式口径：

- 阶段 3 受 `CLOUD_BLOCKED` 门禁约束，只有协议/运维文档完成，Task 3.2–3.5 明确未执行；
- 阶段 4、5 的设备能力与视觉验收均未执行；
- 阶段 6 的构建收口完成，但发布门禁没有通过；
- 本轮新增发现默认系统日历生命周期在 API 权限模型上不成立，以及离线 runner 会带类型错误返回成功。

因此下一步不是继续加功能，而是进入 **阶段 6R：发布阻断整改**。整改完成并通过设备冒烟前，不应制作提审包。

## 2. 本轮独立证据

### 2.1 当前工作树

`git status --short` 只有：

- `entry/src/main/ets/pages/PaintMonth.ets`
- `entry/src/main/ets/pages/ScheduleEditor.ets`

二者属于用户 WIP，本轮只读核验、未修改。以下构建结论针对“`2e146fc` + 这两个 WIP”的当前工作树。

### 2.2 release 构建

执行：

```powershell
hvigorw.bat clean --no-daemon
hvigorw.bat assembleHap --mode module -p product=default `
  -p module=entry@default -p buildMode=release --no-daemon
```

结果：`BUILD SUCCESSFUL in 25 s 283 ms`，产物：

```text
entry/build/default/outputs/default/entry-default-unsigned.hap
size = 1,085,865 bytes
```

结论：源码可以生成 release HAP，但因 `signingConfigs` 为空，只是 unsigned 产物，不是可提审包。ArkTS 仍有大量“可能抛异常”、deprecated 和 syscap 警告，不能再表述为“只剩 showToast”。

### 2.3 ohosTest

执行 `entry@ohosTest` debug `assembleHap`，结果 `BUILD SUCCESSFUL in 18 s 698 ms`。这只证明插桩包可编译；`hdc list targets = [Empty]`，测试没有在设备上执行。

### 2.4 离线测试

`node tools/test/run.mjs` 最终打印 `177 passed / 0 failed`，但转译阶段先出现 5 个 TypeScript 错误：

1. `CommonTimeQueryServiceTest` 将 `Window` 传给 `WindowSummary`；
2. 字符串传给 `WindowTag`；
3. `PlanUseCaseTest` 找不到 `AppStorage`；
4. `ScheduleCommandServiceTest` 找不到 `AppStorage`；
5. `ConflictTest` 引用已不存在的 `ConflictHint` 导出。

runner 的 `noEmitOnError=false` 会继续执行已产出的 JS，并且最终只看用例进程状态，故本次返回码仍为 `0`。因此正确口径是：

> 177 个运行时断言通过，但测试工程类型编译失败，测试门禁不通过。

### 2.5 性能脚本

`node tools/perf/budget.mjs` 返回 0。当前机器：

- 120 天 paired 重算 P95：15.250ms；
- 366 天 paired 重算 P95：78.178ms，超过 16ms，因此必须走既定 TaskPool 门槛；
- 1000 窗口投影 P95：0.911ms。

这是 Node/开发机下界，不替代设备 Profiler 证据。

## 3. 各阶段验收

| 阶段 | 判定 | 说明 |
|---|---|---|
| 阶段 0 基线与门禁 | 通过 | 领域基线、契约、迁移与设计令牌存在；云门禁明确为 `CLOUD_BLOCKED` |
| 阶段 1 精简主框架 | 有条件通过 | 三 Tab、答案优先与入口收纳成立；视觉/返回栈仍待设备 |
| 阶段 1R/1V | 有条件通过 | 时间口径、跨午夜、命令服务、玻璃基础设施已落地；仍有少量 UI 直读 SettingsStore/Repo 的边界债 |
| 阶段 2 计划闭环 | **不通过发布验收** | 本地计划/冲突读模型成立；默认 `editEvent` 后续删除/改期的权限模型不成立，见 B0 |
| 阶段 3 云配对 | **未执行，门禁阻断** | 仅 Task 3.1 文档完成；3.2–3.5 不得标“完成” |
| 阶段 4 卡片/扫码/提醒 | 静态有条件通过 | 代码和离线投影存在；扫码随云端关闭，卡片/提醒未真机运行 |
| 阶段 5 响应式/无障碍/性能 | 静态有条件通过 | 策略和组件存在；360vp、横屏、大字体、读屏、材质和 Profiler 待设备 |
| 阶段 6 迁移/灰度/发布 | **发布不通过** | release/ohosTest 可编译，迁移与回退文档齐；安全、测试、合规、签名和设备证据未闭环 |

## 4. 发布阻断项

### B0：默认日历确认路径无法可靠执行后续删除/改期 — P0

当前路径：

1. `CalendarGateway.confirmEvent()` 调用 `CalendarManager.editEvent()`；
2. 用户在系统日历创建页选择日历并保存，应用得到 event ID；
3. 取消/改期时，`CalendarGateway.removeEvent()` 打开应用自建“同休日”日历，再调用 `Calendar.deleteEvent(id)`。

本机 API 26 `@ohos.calendarManager.d.ts` 对 `editEvent` 明确说明：该 API 创建的事件可由系统日历管理；第三方应用要读取/修改，需要 `READ_WHOLE_CALENDAR` / `WRITE_WHOLE_CALENDAR`。本机权限定义又表明这两项为 `system_basic`，普通应用当前只具备 `READ_CALENDAR` / `WRITE_CALENDAR`。

所以不能假设“在应用专属 Calendar 对象上凭 event ID 删除”能管理 `editEvent` 创建到其他日历的事件。当前取消/改期还会吞掉删除失败、继续把本地计划取消或覆盖 event ID，导致孤儿或重复日程无法重试。

**必须整改：**

- 默认受管路径改为：用户在应用内确认“同时写入系统日历”后，使用 `addEvent` 写入应用专属“同休日”日历；
- `editEvent` 若保留，只能命名为“导出到系统日历（之后由系统日历管理）”，落库为新的 `EXTERNAL_UNMANAGED` 状态，不承诺自动删除/改期；
- 删除、改期返回结构化结果，不得在删除失败时仍返回无条件成功；
- 删除旧事件失败时不得覆盖唯一 event ID，可保留 cleanup tombstone 或失败队列；
- 真机覆盖创建、权限拒绝、取消、改期、撤权后重试、事件被用户提前删除。

### B1：云功能关闭不构成真正安全边界 — P0

`ProfileSettingsService.createInvite()` / `joinByCode()` 没有读取 `FeatureFlags.cloudPairing`，会先发云请求；若 AGC 被误配置成功，随后执行 `savePairKey(deriveKeyHex(code))`，把由 6 位短码派生的长期密钥写入 Preferences。

**必须整改：**

- 两个 service 方法第一行先检查 `cloudPairing`，关闭时在任何 UID、网络和写库动作之前返回；
- `MeView` 在关闭时隐藏生成邀请码、输码、扫码、分享等级，只保留本机代录与“云端未开放”说明；
- 删除或隔离生产路径中的 `deriveKeyHex + KEY_PAIR_KEY`，避免以后只翻开关就复活不安全实现；
- 增加“开关关闭时云客户端 0 次调用、pairId/key/state 均不变”的离线测试。

阶段 3 门禁未解除前，不允许测试性打开 `cloudPairing`。

### B2：计划删除与清空数据会遗留系统副作用 — P0

问题不只在“清空全部数据”：

- `cancelPlan` 的日历/提醒清理失败会被吞掉，仍把计划标记 `CANCELLED`；
- `acceptAlternative` 删除旧事件失败后仍可能创建新事件，产生重复；
- `clearAllData` 直接清空 plan 表，不处理每条 `my_event_id` 与 `reminder_id`；
- 目前只取消周摘要 reminder，计划级 ReminderAgent 可能变成孤儿。

**必须整改：**

- 与 B0 一起建立统一 `PlanProjectionCleanupService`；
- 取消/改期必须保留可重试清理信息并向 UI 报告“本机计划已处理，系统日历/提醒仍待清理”；
- 全量清空前删除应用专属 Calendar 或批量清理受管 event IDs，并取消所有计划提醒和周摘要；
- 用户坚持清空而外部清理失败时，给出失败数量与人工处理说明；不得静默声称“已清空全部数据”；
- 增加取消、改期、删除伴侣、解除配对、全量清空的离线与真机断言。

### B3：离线测试 runner 存在假绿 — P0

**必须整改：**

- `tsconfig.json` 使用 `noEmitOnError=true`；
- `compile.status !== 0` 时立即返回非零，不再启动 `boot.cjs`；
- 修复现有 5 个类型错误；
- 日志分别打印 `typecheck` 与 `tests` 状态；
- 发布文档只有在“0 type error + 0 failed + exit 0”时才能写“全绿”。

### B4：隐私、权限与产品文案不完整 — P0

- `AppConst.PRIVACY_POLICY_URL=''`，全文入口只显示“即将上线”；
- `INTERNET` 在纯本地首发包中没有有效用途；
- 云共享等级在云功能关闭时没有可见效果；
- 日历承诺与 B0/B2 的实际清理能力不一致；
- “清空全部数据”没有披露外部日历/提醒失败的处理口径。

**本次决策：首发移除 `INTERNET`。** 云门禁解除、隐私政策更新并重新验收后再加回来。`PUBLISH_AGENT_REMINDER` 已由本机 SDK 26 权限定义确认是 `system_grant`、normal 权限，不需要运行时申请；仍应在隐私政策中说明提醒用途与关闭入口。

隐私政策必须形成真实可访问 URL，首启摘要、我的页、权限用途说明和商店材料保持同一口径。

### B5：签名、包身份与提审材料未定稿 — P0

- `signingConfigs=[]`，release 包为 unsigned；
- `AppScope/app.json5` 的 `vendor` 仍是 `example`；
- `bundleName=com.huawei.commonrestday` 是否属于开发者主体尚未确认；
- App 备案、截图、分类、年龄分级、版权/开发者信息无落地证据。

这些必须在首个正式包前确定。bundleName 一旦正式使用不应再随意更换。

### B6：没有设备证据 — P0 发布门禁

当前没有真机或模拟器，所以无法判断：

- 默认日历确认/受管日历是否真创建、真删除；
- 权限允许/拒绝/撤回；
- 卡片跨进程更新、路由回流和桌面移除；
- ReminderAgent 是否按档位触发并正确取消；
- 360vp、深色、2× 字体、读屏、Senior Mode、玻璃材质和动画；
- 备份恢复、横屏及性能 Profiler。

发布验收不能用“待设备”替代“通过”。

## 5. 与改造方案不一致但不单独阻断首发

### D1：计划类型仍为 8 项

Task 2.2 要求精简类型，但 `PLAN_KINDS` 仍暴露 8 项。

**本次决策：创建界面只显示“ 一起吃饭 / 其他 ”。** 保留 8 项 key→label 兼容表，用于展示历史数据；`其他` 使用现有 `custom` key 并要求填写标题。这样既符合精简原型，也不会破坏旧数据。不要改成含义过宽的“约会/其他”。

### D2：横屏策略没有产品结论

当前只声明 phone，却没有 orientation；手机横屏可能按宽度进入 medium/expanded，触发原为平板设计的双栏。

**本次决策：首发暂时设置 EntryAbility `orientation: 'portrait'`。** 本机 API 26 schema 已确认 `portrait` 是合法值。完成横屏真机矩阵后再解除，而不是在无证据时默认接受。

### D3：entry/feature 分层仍有残余

- `MeView` 仍直接读三项 `SettingsStore` 通知偏好；
- 老录入页仍直接查询 `ScheduleRepo`；
- `ProfileSettingsService` 直接 import `reminderAgentManager`，没有完全走 integration 门面。

这些不是首发 P0，但新整改不得继续扩大。B2 实施时应把 reminder 取消收进 Gateway/cleanup service；通知偏好补入 ProfileSettings 读模型。老页面的只读查询可在发布后单独偿债。

### D4：警告基线过高

当前 release 能构建，但警告不止 deprecated，还包含异常处理与 syscap。首发前至少做到：

- 新整改不增加警告；
- 对日历、加密、备份、数据库这些高风险路径逐项归类；
- 云端关闭时的 SnapshotCrypto syscap 警告不得被误读为已验证能力；
- 建立 warning 基线文件，数量上升使 CI 失败。

## 6. 阶段 6R 整改执行计划

### 6R.1 日历生命周期重构（最高优先级）

**目标：** 本地计划、系统日历和提醒的状态可解释、可删除、可重试。

1. 冻结新状态：`LOCAL_ONLY / MANAGED_WRITTEN / EXTERNAL_UNMANAGED / CLEANUP_PENDING / FAILED`；
2. 默认创建改为应用专属 Calendar 的受管 `addEvent`；
3. `editEvent` 降为显式“导出”动作，不能复用受管 eventId 语义；
4. 重构取消、改期、补写与清空数据；
5. 更新 `PlanSummary` 徽标、Privacy 文案和测试；
6. API 26 真机跑完整生命周期。

**退出条件：** 创建—改期—取消后系统日历零孤儿；撤权/系统侧已删除均能给出确定状态。

### 6R.2 纯本地安全封口

1. service 级 cloud flag 守卫；
2. 关闭态隐藏云入口和分享等级；
3. 首发移除 `INTERNET`；
4. 增加零云调用断言；
5. 保持 `cloudPairing=false / scanPairing=false`。

### 6R.3 修复测试门禁

1. 修复 5 个 TypeScript 错误；
2. typecheck 失败立即非零退出；
3. 补 B0–B2 的失败路径测试；
4. release、ohosTest、离线测试与性能脚本组成统一验证命令。

### 6R.4 合规与首发形态

1. 创建并托管隐私政策；
2. 同步首启摘要与“我的”页；
3. 设置 `orientation: portrait`；
4. 创建界面只留“一起吃饭/其他”；
5. 确认 bundleName、vendor、版本号、签名和备案资料。

### 6R.5 设备验收

建议至少一台 API 26 真机；如能增加第二台，第二台用于不同尺寸/深色/大字体，不用于开启云配对。

按以下顺序执行，任一 P0 失败立即停止：

1. 全新安装、隐私拒绝/接受、无网启动；
2. 单人录入与本机代录 → 三答案；
3. 创建计划 → 受管日历 → 改期 → 取消 → 清空；
4. 权限拒绝、撤权、事件被系统侧删除；
5. 提醒允许/拒绝、精确提醒开关；
6. 卡片添加/更新/点击/移除；
7. 360vp、深色、2× 字体、读屏、Senior Mode、降低透明度；
8. 备份恢复和性能采样。

### 6R.6 最终出包

- 签名 release clean build；
- 严格测试 runner 0 type error / 0 failed；
- ohosTest 在设备执行而非只编译；
- 回填截图、日志、测试日期、设备型号和系统版本；
- 所有 B0–B6 关闭后再把状态改为 `READY FOR SUBMISSION`。

## 7. 交给后续 AI 的禁止事项

- 不得把 `editEvent` 返回的 ID 当作普通权限下可管理的应用专属事件；
- 不得为快速绿灯让 runner 忽略 TypeScript 错误；
- 不得只在 UI 隐藏云入口而省略 service 级守卫；
- 不得开启 cloud/scan 开关验证未通过的 HUKS 路径；
- 不得把“清空本地表”描述成“已清除系统日历与提醒”；
- 不得覆盖或顺手提交当前两个用户 WIP；
- 不得在没有设备证据时勾选渲染、权限、卡片、提醒或备份恢复通过。

## 8. 最终完成定义

- [ ] B0–B6 全部关闭；
- [ ] 阶段 3 保持明确的 `SKIPPED / CLOUD_BLOCKED`，而非伪装完成；
- [ ] release 签名包生成且包身份材料确定；
- [ ] 严格离线测试 0 type error / 0 failed / exit 0；
- [ ] ohosTest 在 API 26 设备实际执行通过；
- [ ] 日历、提醒和清空数据无孤儿副作用；
- [ ] 隐私政策 URL 可访问且与实际权限/开关一致；
- [ ] 真机可用性、无障碍、卡片、备份和性能证据已归档。

## 9. 整改记录（只追加，不改写上面的判定）

本节记录"代码层面做到哪一步了"，**不构成任何一条阻断项的关闭**：B0/B2 的最终判据是设备上的现象，B6 存在期间它们最多只能写成"代码已改、真机待验"。

### 9.1 B3 —— 已关闭（2026-09-23，提交 `2656341`）

`tools/test/tsconfig.json` 改 `noEmitOnError`，`run.mjs` 在编译有 `error TS` 时**不启动测试**直接返回 3；负向验证过（注入一条类型错误 → `tests: not run`）。被它掩盖的 5 个类型错误全部修掉。新增统一入口 `tools/verify.mjs` + `tools/verify-baseline.json`，`ArkTS:WARN` 只允许降不允许升。

### 9.2 B0 + B2 —— 代码已改，真机待验（2026-09-23，阶段 6R.1）

按 B0 列出的五条整改要求逐一对应（B2 的四条清理要求并进最后两行）：

| 整改要求 | 现在的实现 | 证据与缺口 |
|---|---|---|
| 默认受管路径改成 `addEvent` 写应用专属「同休日」日历 | `CalendarGateway.writeEvent` → `open()`（`getCalendar` 失败即 `createCalendar`）→ `cal.addEvent`；计划 Sheet 的「写入系统日历」开关默认开、逐条决定 | 离线 19 条日历用例；出包 0 error；**专属日历是否真建得出、系统日历 App 里是否真看得见 → 待设备** |
| `editEvent` 只命名为"导出"，落 `EXTERNAL_UNMANAGED`，不承诺自动删除/改期 | `CalendarGateway.exportEvent`（原 `confirmEvent`）；`PlansView` 入口文案「导出到系统日历」+ 徽标「已在系统日历，之后由系统日历管理」；`canExportToCalendar` 只在日历上确实还没有它时放行；清理路径对导出那份**永不试删**（拿它的 id 去删可能删错别人日历里的条目） | 离线用例 `exported_events_are_never_auto_deleted_but_are_reported`；导出确认页现象 → 待设备 |
| 删除/改期返回结构化结果，删除失败不得无条件成功 | `RemoveOutcome{REMOVED,FAILED}` + `ReminderCapability.cancel(): boolean`；`CleanupReport` 五计数；`calendarStateAfterCleanup` 把"还有残留"分成 `CLEANUP_PENDING` 与 `EXTERNAL_UNMANAGED` 两格 | 离线用例断言"删不动 → 状态不是干净态"；`deleteEvent` 真抛错时的现象 → 待设备 |
| 删旧事件失败不得覆盖唯一 event ID，留 tombstone 或失败队列 | 句柄原样留在 `plan.my_event_id` / `reminder_id`，状态 `CLEANUP_PENDING`；`ScheduleRepo.updatePlanProjection` 一次写清"状态 + 事件 id + 提醒句柄"，避免出现"日程已清、提醒句柄还挂着"的半套状态；旧投影没让开就**不写新投影** | 离线用例 `undeletable_old_event_blocks_the_new_one_and_stays_retryable` |
| 取消/改期/清空的计划级提醒孤儿；清空只删本地表 | 新增 `PlanProjectionCleanupService`（只清系统侧、不写库）+ `PlanCapabilities`（端口唯一持有者）；`clearAllData` 先逐条清投影 → `purgeManagedCalendar()` → 撤周摘要提醒 → 才删表，并按 `clearAllMessageOf` 如实播报剩余；`EntryAbility.onForeground` 跑 `sweepPendingProjections()` 补扫；`MeView` 清空确认弹窗写清会连带删掉什么 | 离线 `PlanUseCaseTest` 里"取消清两条 / 取消留残留可扫 / 清扫不误删正常投影 / 导出不试删"四组 + `clearAllMessageOf` 口径 1 条；插桩新增 `cleanup_pending_handles_are_voided_before_the_sweep_sees_them`；**清空 / 撤权 / 补扫的真机现象全部待设备**（TC §20.1.3～§20.1.5、§6.9～§6.10） |

配套收口：`normalizeCalendarState` 把阶段 2 那个"editEvent 与直写不分家"的 `'WRITTEN'` 保守读成 `EXTERNAL_UNMANAGED`（宁可提示"请在系统日历里删除"，也不谎报"本应用会替你删"）；`RESTORE_CLEANUP_SQL` 的降级名单补入全部新状态，来源设备的 `CLEANUP_PENDING` 句柄不会被这台机器的清扫认领。

**本轮实测口径**（2026-09-23，`node tools/verify.mjs --steps=offline,debug,release,ohostest`，日志 `.crdtest/6r1-verify.log`）：offline 0 type error / 182 passed / 0 failed / exit 0；debug 与 release 均 BUILD SUCCESSFUL、0 ERROR、`ArkTS:WARN` 357；ohosTest 同样 BUILD SUCCESSFUL、`ArkTS:WARN` 262、**未执行**。

**本报告 §1 执行摘要与"不具备提审条件"的结论不变。** B1、B4、B5、B6 本节一项都没动。

### 9.3 D4 —— 基线收紧

`ArkTS:WARN` 上限从 361（debug/release）与 266（ohosTest）降到 357 / 262：`ScheduleRepo` 六个单行写入口合并为 `setPlanColumns`、计划查询合并为 `queryPlans`（ArkTS 的 "Function may throw exceptions" 按 @kit 调用点计数，重复写体会成倍放大告警位）。基线只随实测下降而改，数值记在 `tools/verify-baseline.json`，复跑日志在 `.crdtest/6r1-verify.log`。

> **2026-09-23 追加（阶段 6R.2 后再降一档）**：357 / 357 / 262 → **352 / 352 / 260**。降的原因是 B1 封口删掉了真实的调用点，不是措辞变化——`SnapshotCrypto.deriveKeyHex` 与 `SettingsStore.savePairKey` 两个方法体（各含 `cryptoFramework` / `preferences` 的"可能抛异常"位）连同 `ProfileSettingsService` 里三处 `savePairKey` 调用一起消失。实测命令 `node tools/verify.mjs --steps=offline,debug,release,ohostest`，日志 `.crdtest/verify-{debug,release,ohostest}.log`。

### 9.4 B1 —— 代码已封口，权限面已收窄（2026-09-23，阶段 6R.2）

B1 列的四条整改逐条落地，并额外把"关不掉"的结构依赖删了。**这一条仍不构成阻断项关闭**：B6 存在期间，"关闭态一个字节都不出本机"的最终证据只能是真机抓包/权限核查。

| 整改要求 | 现在的实现 | 证据 |
|---|---|---|
| 两个 service 方法第一行先检查 `cloudPairing`，关闭时在任何 UID、网络和写库动作之前返回 | `ProfileSettingsService.cloudBlocked()`（单一判据）；`createInvite`/`joinByCode`/`markPaired` 三条的第一句即返回 `FeatureFlags.cloudClosedMessage`，`getOrCreateUid()` 与 `AgcPairingClient` 都在其后；`unpair`/`cancelWaiting` **不受拒**（本地清除永远执行，云端解绑只在开启时才发） | 离线 `profileSettingsGuardTest` 前三个用例断言"关闭态返回后 `AgcPairingClient.calls === 0`、pairId/pairState/partnerUid 全不变"；`markPaired` 单列一条：能写到库里的 `PAIRED` 就是界面上的"正在同步" |
| `MeView` 关闭时隐藏生成/输码/扫码/分享等级 | `pairingBlock()` 第一段 `if (!FeatureFlags.cloudPairing)`：只给未开放说明 + 本机代录指引 + 退出通道（残留 `PAIRED`/`WAITING` 仍可解除）；`partnerSyncCard()` 的 `divider + levelBlock` 一并收走；`ScheduleHub` 的 TA 侧提示去掉"请用配对"这半句 | 编译期分支（`else if` 链在关闭分支之后），非运行时隐藏；出包 0 error |
| 删除或隔离生产路径中的 `deriveKeyHex + KEY_PAIR_KEY` | `SnapshotCrypto.deriveKeyHex` **删除**（该模块头注明"不派生、不保存密钥"）；`SettingsStore.savePairKey` **删除**，`getPairKey` 转为只读、`clearPairKey` 只用于清旧原型残留；`AgcSnapshotSync` 的推拉在 `ScheduleUseCase.pullPartnerSnapshot/pushMySnapshot` 第一句看档位 | 结构保险：只翻 `cloudPairing` 复现不出"短码派生密钥落 Preferences"，因为写入口已经不存在（`grep savePairKey` 只剩注释与文档） |
| 增加"开关关闭时云客户端 0 次调用、pairId/key/state 均不变"的离线测试 | `AgcPairingClient.calls` 进程内计数（生产与替身同名）；`tools/test/run.mjs` 的 `STUB_DATA` 补出真实签名对齐的内存 `SettingsStore`/`ScheduleRepo`，并把 `ProfileSettingsService` 从 feature 跳过名单里放回来（替身不忠实就没法证 B1）；替身**总是成功**，因此"0 次调用"只能由守卫给出，不能靠云恰好没配 | 离线 **190 passed / 0 type error / exit 0**（新增 8 条）；变异验证：临时删掉 `createInvite` 首句守卫 → 仅 `create_invite_returns_before_uid_cloud_and_writes` 失败（`expected false but got true`）→ 还原 |

另外两处不属于 B1 清单但同批落：`PairingShareGateway` 的 `channels()/offerFromScan()/shareLink()/offerIncoming()` 四个入口在网关层各自先拒（关闭态连相机视图、分享面板、外来 want 留痕与 `pairOfferCount` 广播都不发生，对应 §7「不得只在 UI 隐藏」）；`entry/src/main/module.json5` 移除 `ohos.permission.INTERNET`（`requestPermissions` 只剩 3 条：`READ_CALENDAR`、`WRITE_CALENDAR`、`PUBLISH_AGENT_REMINDER`），纯本地版即便有代码也发不出请求。

**未做**：解除配对与删除伴侣的"云端成功路径"断言（`CLOUD_BLOCKED` 下不可达，见发布清单 §2 G5 表最后两行）；ohosTest 的 `pairing_reset_lands_on_real_preferences` 已改成用 `@kit.ArkData` 的 `preferences` 直接种 `pair_key` 残留（生产写入口已删，残留由测试自己造），**仍属未执行**。



### 9.5 B4 + B5 + D1 + D2 —— 代码与材料已落地，两项均不判关闭（2026-09-23，阶段 6R.4）

§5 的三个待决策项与 §4 的 B4/B5 里"仓库能做的部分"一次做完。**判定不变**：B4、B5 各自还剩账号侧与设备侧的硬缺口，本报告 §1 的"不具备提审条件"结论继续成立。

| 条目 | 现在的实现 | 证据 / 缺口 |
|---|---|---|
| D1 计划类型精简（§5 定稿：只显示"一起吃饭/其他"，旧 8 类保留兼容表，`其他` 用 `custom` key 并强制填标题，不要改成"约会/其他"） | `feature/src/main/ets/model/PlanKinds.ets`：`PLAN_KINDS`（2 项，可创建）与 `LEGACY_PLAN_KINDS`（旧 6 类标签）+ `planKindLabel` 兜底返回原值——**两张表分开是这条定稿的全部难点**，合成一张会让每次精简选项都把老数据读成空白或英文码；`其他` 复用 `custom` 因此零迁移；`WindowDetailSheet.pickKind` 切到"其他"清空标题且不钉住 `titleTouched`（两项之间"点过去再点回来"很常见） | 离线 `entry/src/test/PlanKindsTest.ets` 5 条（两项、`custom`、旧 key 仍出中文、未知 key 读出自己、"其他"必填标题）。**先红后绿**：红因是 runner 的 barrel 由 `run.mjs` 硬编码名单生成、不读 `feature/Index.ets` → 3 个 `error TS2305` / exit 3 / tests not run |
| D2 首发锁竖屏（§5 定稿：横屏真机矩阵通过后再开放） | `entry/src/main/module.json5` EntryAbility `"orientation": "portrait"`；解除条件写在 TC §20.6b——**要的是横屏矩阵通过，不是"竖屏锁这条通过"**，两件事极易被混成一件 | 静态事实。设备侧现象（横握不转）待验证（B6） |
| B4 隐私政策（§4 三条：无全文、无商店材料、摘要与实际行为不一致） | 全文**随包内置** `entry/src/main/ets/component/PrivacyPolicySheet.ets`（十条半模态，首启弹窗 + 「我的 · 数据与隐私」共用），`PrivacyUtil` 与 `privacy_fulltext_soon` 删除。**结构性原因**：这个包按定稿不带 `INTERNET`，"点入口跳浏览器看托管页"在当前形态下做不到，所以填 URL 修不好旧入口；canonical 稿 `docs/legal/privacy-policy.md` + 可直接上传的自包含页 `docs/legal/privacy-policy.html`，三份文字同源、漂移规则写在文件头。摘要四条按 6R.1 真实行为重写；旧那句"可随时在「我的」页调整隐私共享等级"（控件已被 6R.2 收走）换成"以上为全文摘要，措辞不一致以全文为准" | **B4 不判关闭**，欠两条：① 应用市场仍要求可访问 URL，上传与回填 `AppConst.PRIVACY_POLICY_URL` 属账号侧（URL 为空时页底如实显示"尚未填写"，不阻断阅读）；② 全文与当场行为逐字对照、360vp/2.0× 字号/深色/读屏下的可读性属设备侧（TC §20.3/§20.3b，B6） |
| B5 签名与包身份材料 | 新建 `docs/release/submission-materials.md`：包身份（`bundleName` 归属、`vendor` 仍是模板值 `example`、版本号）、签名（`signingConfigs: []` + `products[0].signingConfig: "default"` → 产物 `entry-default-unsigned.hap`；规则：密钥库口令与私钥不进仓库）、备案状态（**仓库内至今零记录**）、隐私政策两步、商店材料（0 张截图）、开发者信息 | **B5 不判关闭**：登记表里每一项的"值"都要 AGC 账号确认，本机无法代做。`com.huawei.*` 前缀可能被审核质疑这一点在文档里**明确标为判断**而非事实——本仓库没有华为官方"禁用该前缀"的条款可引；趁首个正式包之前改最便宜 |

**本轮实测口径**（2026-09-23，`node tools/verify.mjs --steps=offline,debug,release,ohostest`，出包日志 `.crdtest/verify-{debug,release,ohostest}.log`、离线日志 `tools/test/out/last-run.log`）：offline 0 type error / **195 passed** / 0 failed / exit 0；debug 与 release 均 BUILD SUCCESSFUL、0 ERROR、`ArkTS:WARN` **349**；ohosTest BUILD SUCCESSFUL、**260**、**未执行**。基线 352/352/260 → 349/349/260（D4 的只降不升口径延续；**−3 的逐位归因未核对**，上一档日志已被本轮复跑覆盖，只知道本任务删了 `PrivacyUtil`/`PlanKindUtil` 两个文件并把计划类型词表上移进 `feature`）。
