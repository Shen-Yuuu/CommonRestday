# 同休日 灰度发布与回退口径（阶段 6 Task 6.2）

> 口径日期：2026-09-23。适用对象：`feature/src/main/ets/config/FeatureFlags.ets` 里的每一个编译期常量。
> 配套：验收清单 `docs/testing-checklist.md`、云侧回退 `docs/cloud/operations-runbook.md` §5、门禁 `docs/validation/clouddev-api26-spike.md`。
> 本文只回答一件事：**某一档出问题时，怎么在不丢用户数据的前提下把它关掉，以及关掉之后应用会变成什么样。**

## 1. 先说清楚这套开关能做什么、不能做什么

**能做**：把某个能力的"链路 + 入口"在源码层面一起退场，出一个不带该能力的包。
**不能做**：按用户分流。开关是 `static readonly boolean`，只有改这一行 + 重新出包才能改档位，
所以这里的一次"灰度"= **一个档位一个包**，而不是同一份包在不同人手机上表现不同。

三条硬规则（与 `FeatureFlags.ets` 文件头同源，改一处必须改两处）：

1. **禁止远端动态下发**。项目没有可用的云端配置通道（云配对受 Task 0.4 门禁 `CLOUD_BLOCKED` 关闭），
   "能远程改配置"本身是一条未验证的能力，不为它留口。
2. **每个开关必须有读取方，且关闭分支必须真的能跑**。没有读取方的开关是假的安全感
   （`docs/testing-checklist.md` §11.14）。本轮按这条规则删掉了 `newShell`，给 `calendarFlow` 建了读取方。
3. **开关只关能力，不关数据**。任一档关闭时，本机已落库的事实仍可读、可改、可删；
   不存在"关掉某档会让列表空白"的分支。

**应用市场侧的分阶段放量（提审后的灰度比例、分阶段发布）不在本文范围内**：AGC 当前控制台是否支持、
怎么支持，本仓库没有核对过官方文档，属缺证据。需要时先查官方发布指南再补一节，不要照搬其他商店的经验。

## 2. rollout 顺序与当前档位

改造文档给的启用顺序是 `newShell → calendarFlow → cloudPairing → scanPairing → newCard → responsiveV2`。
下表是 2026-09-23 的实际档位与"口径落在哪一行代码"。

| # | 开关 | 当前档位 | 口径落点（读这一档的代码） | 顺序上的前置 |
|---|---|---|---|---|
| 1 | ~~`newShell`~~ | **已删除**（本轮） | 无：旧四 Tab 壳层已退场，关不回任何链路 | — |
| 2 | `calendarFlow` | `true` | `PlanUseCase` 的日历编排（`writeManaged`）+ `PlanFlow.canRetryCalendarSync` 与 `canExportToCalendar` | 无（本机链路） |
| 3 | `cloudPairing` | `false` | 阶段 6R.2 起共 5 个落点：`ProfileSettingsService.cloudBlocked()`（createInvite/joinByCode/markPaired 首句）+ `PairingShareGateway`（channels/offerFromScan/shareLink/offerIncoming/acceptOffer）+ `ScheduleUseCase`（快照推拉首句）+ `MeView`/`ScheduleHub`（入口与文案）；另 `module.json5` 首发不带 `INTERNET` | Task 0.4 门禁改写 |
| 4 | `scanPairing` | `false` | `PairingShareGateway.channels`（且以 `cloudPairing` 为条件） | `cloudPairing = true` |
| 5 | `newCard` | `true` | `FormAbility.onAddForm` + `FormAbility.refreshCard` | 无（只读本机） |
| 6 | `responsiveV2` | `true` | `Breakpoints.ofWidth`（全站断点唯一入口） | 无（纯渲染） |

前置关系写在代码里而不只在文档里：单开 `scanPairing` 不会露出一个只能失败的扫码入口。
`cloudPairing` 与 `scanPairing` 两档的**启用条件至今未满足**，本文档不提供它们的开档检查单，
只提供"确认仍然关着"的检查单（§5）。

## 3. 逐个开关的口径

### 3.1 `newShell` —— 本轮删除，不是遗漏

- **原意**：阶段 1 用三 Tab + Navigation 新壳层替换旧四 Tab 壳层，`DEBUG` 构建开、release 关。
- **为什么删**：阶段 1 Task 1.2/1.3 直接把根页面换成了新壳层，旧壳层从未作为可切换分支存在过；
  到 Task 6.2 时全仓对 `newShell` 的读取方是 **0 处**，而 `entry/src/main/ets/pages/` 下也没有旧壳层页面可回。
  留着它的后果很实际：release 包里它是 `false`，谁读它谁就以为线上关着新壳层。
- **壳层的回退方式**：整包回退到上一版 HAP。壳层不写数据，所以整包回退没有数据兼容问题；
  真要退回旧导航形态，只能回到改造前的提交重新出包。
- **数据兼容性**：无关。

### 3.2 `calendarFlow` —— 系统日历链路（阶段 6R.1 重写为受管写入）

| 项 | 口径 |
|---|---|
| 启用条件 | ①默认路径是**应用专属「同休日」日历的受管写入**（`CalendarGateway.writeEvent` → `getCalendar`/`createCalendar` + `addEvent`），`editEvent` 只剩「导出到系统日历」这一个出口，导出后状态落 `EXTERNAL_UNMANAGED` 且代码里永不试删；②取消/拒绝时本机计划照常保留，写失败落 `FAILED` 并给出补写入口；③删不动时句柄留在计划行、状态转 `CLEANUP_PENDING` 并给「重新清理」。离线侧 19 条日历用例已钉住这三条；真机侧仍需 `docs/testing-checklist.md` §6（专属日历那一本、导出确认页、清理与补扫）与 §7 勾通过 |
| 监控指标 | `hilog` 里两类行：`CalendarGateway` 的 `managed event written, id=…` / `event exported to system calendar, id=…` / `addEvent failed:` / `deleteEvent degraded:`，以及 `PlanUseCase` 的 `plan created id=… calendar=<状态>`。判据按状态分：`MANAGED_WRITTEN` 之外的占比升高＝日历侧退化；`EXTERNAL_UNMANAGED` 升高说明用户更多走了导出（那份本应用管不动）；出现 `CLEANUP_PENDING` 就是系统侧有残留待清。无远端遥测，指标只能来自用户回传的日志截图 |
| 关闭影响 | 创建/改期/补写/导出四条路径一条日历调用都不发；`plan.calendar_state` 归一成 `NOT_REQUESTED`，卡片徽标停在「仅保存在应用内」，且**不再出现**「写入日历」与「导出到系统日历」两个入口（`canRetryCalendarSync`/`canExportToCalendar` 同档判空）。用户看到的是一个纯应用内计划器。**例外**：「重新清理」不受本档控制，关档包仍能把开档时留下的日程删掉 |
| 数据兼容性 | 完全兼容。`calendar_state` / `my_event_id` / `reminder_id` 三列照常写，不新增语义。开档时写入的日程在关档后仍会被清理：取消与改期都走 `PlanProjectionCleanupService`（与写入路径分家），`EntryAbility.onForeground` 的 `sweepPendingProjections()` 也照跑，因此不会留下没人认领的孤儿日程。关档期间新计划的 `my_event_id` 恒为空串 |
| 已知缺口 | 关档期间用户**没有**任何补写入口，历史计划要等重新开档后才可补写；`NOT_REQUESTED` 与 `LOCAL_ONLY` 在关档时对用户是同一句话（「仅保存在应用内」），这是有意的——回退档不该讲内部状态名 |

> 旧稿这里的"`directCalendarWrite`（跳过确认页直接 `addEvent`）是高级选项目前恒 false"已经不存在了：阶段 6R.1 之后 `addEvent` 就是默认路径，"要不要写日历"由计划 Sheet 上的开关逐条当面决定，没有第二档编译期常量。回退只看 `calendarFlow` 一个档。

### 3.3 `cloudPairing` —— 云端配对与加密快照

| 项 | 口径 |
|---|---|
| 启用条件 | **尚未满足。**Task 0.4 结论 `CLOUD_BLOCKED`：HUKS 托管长期密钥的链路未验证。解除条件全部见 `docs/validation/clouddev-api26-spike.md` §4 五条门禁，一条不满足就不开。**不允许**退回"用邀请码派生长期密钥"（改造文档 §0.3 明文）——阶段 6R.2 已经把 `SnapshotCrypto.deriveKeyHex` 与 `SettingsStore.savePairKey` 从源码删掉，所以"翻开关就复活旧实现"这件事现在做不到：要开档必须先在 HUKS 那侧把密钥容器实现出来并补上单测<br>**加回 `ohos.permission.INTERNET` 的条件**（首发包刻意不带它）：同一批里 ①`cloudPairing=true`、②HUKS 托管密钥验证通过、③隐私政策全文与提审"权限用途说明"同步补上联网用途。三条不齐就不要动 `module.json5` |
| 监控指标 | 门禁未过，无线上指标可看。云侧运维指标见 `docs/cloud/operations-runbook.md` §6 |
| 关闭影响 | **关闭态是一条真边界，不是"云恰好没配"**：`createInvite/joinByCode/markPaired` 在第一句就返回 `FeatureFlags.cloudClosedMessage`（不生成/读回 uid、不发云函数、不写 `pairId/pairKey/pair_state`），`acceptOffer()` 在写任何数据前返回同一句，扫码/分享/外来 want 三条入口在网关层各自先拒（不开相机、不开分享面板、不留待确认痕迹也不广播 `pairOfferCount`），快照推拉第一句停住，`MeView` 连生成/输码/扫码/二维码/分享/共享等级的控件一起不渲染。对方日程继续靠本机代录，全部功能可用。**两个退出通道刻意不受关闭态拒绝**：`unpair()` 与 `cancelWaiting()` 照常清本机标记（上一版原型可能留下 `PAIRED`/`WAITING`，藏了入口就不能再撤），只是不再发云侧解绑请求——「开关只关能力，不关数据」 |
| 数据兼容性 | 本机数据零影响。关档不需要删云数据（`operations-runbook` §5：停服＝关开关）；`pair_state` / `pairId` 留在库里不丢，重新开档后继续用。**换机恢复会主动把配对抹成未配对**（Task 6.1：长期密钥不参与备份）；旧原型残留在 Preferences 里的 `pair_key` 由 `clearPairKey()` 清掉（该键已无任何写入方，读到也只当没钥匙）。「共享等级」`shareLevel` 的值在关档时仍照旧保存，只是当前没有可见效果——所以关档不重置它 |
| 已知缺口 | `pair_state = PAIRED` 但密钥解不出时，没有运行时自愈路径把状态拉回未配对；现场只能靠「重新配对」入口。这一条记在 `docs/testing-checklist.md` §17.4，不因为本文档写"兼容"就当已解决 |

### 3.4 `scanPairing` —— 扫码配对

| 项 | 口径 |
|---|---|
| 启用条件 | `cloudPairing = true` **之后**；且 Scan Kit 在真机上验证通过（清单 §10.2）。两道条件缺一不可，第一道已经写进 `PairingShareGateway.channels()` |
| 监控指标 | 无（能力未上线）。开档后要看的第一件事是 `ScanOutcome.UNSUPPORTED` 与解析失败率——扫不出配对码却把入口摆在最显眼处，比没有入口更伤 |
| 关闭影响 | 扫码按钮不出现（清单 §10.1 已确认当前构建里就是这句）；`emphasizeCode` 由"本机有没有扫码能力"决定，与开关无关，所以短码大字提示照常 |
| 数据兼容性 | 无关：扫码只是取得一次性凭据的通道之一，凭据从不落库（门禁 §4 第 3 条） |
| 已知缺口 | 关档期间用系统分享/短码把请求交给对方是**唯一**路径，两条路径都不依赖本开关 |

### 3.5 `newCard` —— 桌面 2×2 卡片内容

| 项 | 口径 |
|---|---|
| 启用条件 | 阶段 4 Task 4.2 出口：卡面与首页同源（`CardSummaryService` 投影，卡片不自己数窗口）、只读算不写库、跨天先本机重算。真机侧仍待清单 §11（卡片添加/更新/移除、点击带 route） |
| 监控指标 | `hilog` 的 `FormAbility` 两类行：`card read degraded:`（读库/算失败降级）与 `refresh card on update failed:`（回填失败）。**卡片侧没有更好的观测点**：卡片是独立进程、无法上报，出问题时唯一证据是日志和截图 |
| 关闭影响 | `onAddForm` 与 `refreshCard` 两处只下发 `FormAbility.disabled()`：卡面显示「桌面卡片已停用 / 当前版本未开启卡片内容，打开 App 查看共同时间」，且**不初始化 Db、不读本机数据、不触发重算**（关档时卡面上不该出现任何本机事实）。停用文案是常数，不含日程、时间或计划标题 |
| 数据兼容性 | 无关：卡片全程只读。关档后不再需要单独处理 |
| 副作用（必须知道） | 卡片是**日切重算的触发器之一**：关档后这个入口消失，重算回到"App 冷启动按 `lastRecomputeDay` 补算"一条路。只关卡片不会让首页变陈旧，但会让"从不打开 App、只看桌面"的用户看不到今天的结论——这正是卡面上的那句话把人指回 App 的原因 |
| 无法关的东西 | 卡片在桌面上的**存在与否**由用户在桌面添加/移除，应用侧关不掉（本项目按 `project-widget-desktop-only` 决策不做应用内添加入口）。关档只是让这张卡不再有内容，不是把它撤掉 |

### 3.6 `responsiveV2` —— 容器级响应式断点

| 项 | 口径 |
|---|---|
| 启用条件 | 阶段 5 Task 5.1/5.2 出口 + 真机三档走查（清单 §13：360vp、展开态/平板宽度、横屏）。`ContainerReader` 的 `!!` 回灌口径在本仓库**只有编译证据、没有设备证据**，这是启用前必须补的一条 |
| 监控指标 | 断点是纯本地渲染决策，无线上指标。替代证据是走查截图：`Breakpoint` 档位、外壳是否居中、共同时间是否双栏 |
| 关闭影响 | `Breakpoints.ofWidth` 一律返回 `COMPACT`，于是宽屏居中封顶、分档留白（18/24/32）、正文可读宽度上限、共同时间「列表—详情」双栏一起退到阶段 4 的单列形态；详情改回半模态。不会出现"外壳收成两栏、里面还按窄屏排版"的半开状态——因为口径只有这一处 |
| 数据兼容性 | 无关：纯渲染，不写库、不改读模型 |
| 不在本档里 | **适老化（Senior Mode 低密度、2 倍字号、减少动效、读屏语义）不受 `responsiveV2` 控制**，那是用户设置与系统无障碍状态（`AccessibilityPolicy`），不是灰度能力。别把"关掉响应式"当成"回到适老化之前" |

## 4. 监控指标从哪来（本项目没有遥测）

档位摘要在冷启动时打一行，用于事后判断"这个包到底开了什么"：

```bash
hdc shell "hilog | grep -E 'CrdFlags|PlanUseCase|FormAbility|CrdRestore'"
```

`CrdFlags` 那行按 §2 的顺序列出五档（`calendarFlow=on cloudPairing=off scanPairing=off newCard=on responsiveV2=on`），
由 `entry` 的 `Index.aboutToAppear()` 打印，位置在隐私拦截之前，所以拒绝弹窗的冷启动同样留痕。
`FeatureFlags.summary()` 由离线用例断言五档齐全（`entry/src/test/PresentationModelsTest.ets`），
漏一档会在 CI 之前就红。

这不是可聚合的指标系统：单人开发、纯本机数据、无云端上报，**能拿到的只有用户主动回传的日志与截图**。
放量判断只能建立在"这一档的关闭影响是否可逆 + 数据是否兼容"上，不能指望线上告警。

## 5. 回退操作手册

改档位 = 一行代码 + 一次出包。步骤固定，别跳：

```powershell
# 1) 改 feature/src/main/ets/config/FeatureFlags.ets 里的那一行

# 2) 离线口径先跑一遍（档位断言会随档位变化，见下方说明）
node tools/test/run.mjs

# 3) 出包（发布档位用 buildMode=release）
& 'D:\local\DevEcoStudio\tools\hvigor\bin\hvigorw.bat' assembleHap `
  --mode module -p product=default -p module=entry@default -p buildMode=release --no-daemon

# 4) 提交：只提交 FeatureFlags.ets 与本文档的档位表，commit 里写清"关掉哪一档、为什么"
```

**离线用例对档位的断言**（`feature_flags_gate_unreleased_capabilities`）会把"改档位忘改文档"变成红灯：
`calendarFlow=false` 时该用例必然失败——这正是它存在的意义（开关真的接在代码上）。
回退包要过 CI，就得同时更新那条用例与本文的档位表；不接受为了绿灯而删断言。

**回退后必须复查的三件事**（真机条目在 `docs/testing-checklist.md` §18.2，接上设备一起做）：

- [ ] 冷启动日志里 `CrdFlags` 一行确实是目标档位；
- [ ] 该档的入口真的消失了（`calendarFlow`：计划卡无「写入日历」；`cloudPairing`：「我的」页无生成/输码/扫码/二维码/分享/共享等级，只剩本机代录与解除/取消两个退出按钮；`scanPairing`：「我的」页无扫码按钮；`newCard`：桌面卡片显示停用文案；`responsiveV2`：宽窗口回到单列）；
- [ ] 本机数据仍完整：班次、课程、计划、冲突、已配对的本机档案一条不少（开关只关能力，规则 3）。

**云侧不需要跟着回退**：`cloudPairing`/`scanPairing` 的关闭动作本身就是端侧出包，
云数据保留、不删（`operations-runbook` §5）。删数据是不可逆动作，不属于回退手段。

## 6. 本轮验证到哪一步（不写"已验"的地方）

| 项 | 证据 | 状态 |
|---|---|---|
| 每个开关都有口径 | 全仓 `grep FeatureFlags` 结果记在 §2 表里；`newShell` 已删除；`cloudPairing` 自阶段 6R.2 起是 5 个落点（service / gateway / 快照推拉 / 两页文案与入口），不是一处 | 已核 |
| 当前档位不出现装饰性开关 | 同上 | 已核（清单 §11.14 关闭） |
| 当前档位的离线口径 | 阶段 6R.4 之后只有这一条算数：**0 type error / 195 passed / 0 failed / exit 0**（旧的"177 passed 但带 5 个类型错误却返回 0"已作废）；其中 6 条专证 `cloudPairing=false` 的关闭态（云客户端 0 次调用、`pairId/pairKey/pairState` 不变、解除与取消等待仍清本机标记），另 5 条专证计划类型精简（可选项只剩两项、"其他"复用 `custom`、旧 8 类标签仍渲染、未知 key 读出自己、"其他"必填标题） | 已测（`node tools/test/run.mjs`；变异验证：临时删掉 `createInvite` 首句守卫 → 只有那条守卫用例失败） |
| 当前档位编译 | clean 出包 `node tools/verify.mjs --steps=offline,debug,release,ohostest` → 三条全 BUILD SUCCESSFUL、0 ERROR；`ArkTS:WARN` debug **349** / release **349** / ohosTest **260**（基线沿革 361/361/266 → 357/357/262 → 352/352/260 → 349/349/260，见 `tools/verify-baseline.json`）；ohosTest **只编译、未执行** | 已测（日志 `../.crdtest/verify-{debug,release,ohostest}.log`） |
| 首发包不带 `INTERNET` | 静态事实：`entry/src/main/module.json5` 的 `requestPermissions` 只有 3 条（两条日历 + `PUBLISH_AGENT_REMINDER`）。**没有设备去核实"这个包确实发不出请求"** | 配置已核，现象待设备（清单 §9.3、TC §20.5） |
| `calendarFlow = false` 分支 | 单独翻档后**离线套件按预期变红：169 passed / 13 failed**，失败项全是日历口径（`expected MANAGED_WRITTEN/LOCAL_ONLY/FAILED/PENDING but got …`、`double_submit… expected 1 but got 0` = 一次日历调用都没发、清理后句柄没留下）+ 那条档位断言本身。阶段 6R.1 重写后又复测了一次，口径与阶段 6.2 一致 | 已测（日志 `../.crdtest/6r1-off-calendarflow.log`；6.2 的出包日志 `build-6-2-off-calendarFlow.log`） |
| `newCard = false` 分支 | 阶段 6R.1 之后重跑：`entry@default` debug BUILD SUCCESSFUL / 0 ERROR / `ArkTS:WARN` 357；卡面表现**未看** | 编译已测（日志 `../.crdtest/6r1-off-newCard.log`），真机待验 |
| `responsiveV2 = false` 分支 | 同上重跑：BUILD SUCCESSFUL / 0 ERROR / WARN 357；断点行为**未看** | 编译已测（日志 `../.crdtest/6r1-off-responsiveV2.log`），真机待验 |
| 三档恢复后的合并状态 | 五档回到 §2 的发布档位（`calendarFlow=on cloudPairing=off scanPairing=off newCard=on responsiveV2=on`）后，上表的 offline/debug/release/ohostest 四步再全绿一次 | 已测（阶段 6R.4 复跑，`../.crdtest/verify-*.log`：195 passed / 349 / 349 / 260） |
| 首发包的屏幕方向 | 静态事实：`EntryAbility` 声明 `orientation: 'portrait'`（阶段 6R.4 定稿）。这不是开关而是形态收口——**没有设备就证不了"横握真的不转"**，也证不了"删掉这行后横屏矩阵可接受" | 配置已核，现象待设备（TC §20.6/§20.6b） |
| `cloudPairing = true` / `scanPairing = true` 分支 | 不验证 | **故意不做**：门禁未过，验证会诱导"顺手开一下"。要开先改 `clouddev-api26-spike.md` 结论 |
| 关档后的真机表现（停用卡面、单列回退、无补写入口） | 无设备 | **待设备**（清单 §18.2） |
| 按用户分流的灰度、分阶段放量 | 未核对官方控制台 | 缺证据，见 §1 |

**离线套件在关档下变红不是缺陷**，而是这道验证的全部意义：`calendarFlow` 一关，10 条日历断言就跟着改口，
说明开关确实接在链路上，而不是"关掉了一个没人读的常量"。回退包要重新过 CI，就得连这条档位断言一起更新。

## 7. 与验收的接口

- 发布门禁（改造文档 Task 6.4）里的「功能开关关闭时纯本地版可发布」= 把 §2 表的档位作为发布配置，
  且 §3 每行的「关闭影响」在真机上表现一致；
- 清单里所有 `FeatureFlags.*` 相关条目以本文为准；两者冲突时，先改清单再改代码，不要反向；
- 新增开关的代价：必须同时给出读取方、关闭分支、§3 的一小节、离线断言。四样缺一样就不要加开关。
