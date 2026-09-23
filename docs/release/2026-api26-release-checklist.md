# 同休日 API 26 发布验收清单（2026-09-23）

> 对应改造文档 Task 6.4。本文件只做一件事：**把"能不能提审"拆成可判定的条目，并写清每一条现在有什么证据**。
> 逐屏操作口径不在这里重复，全部在 [真机验收清单](../testing-checklist.md)（下面记作 `TC §n`）。

> **2026-09-23 独立复核补充：** 本文件的“不具备提审条件”结论继续成立，但阻断范围已扩大。复核发现：
> ① `editEvent` 创建的系统日历事件在当前普通权限下不能按现有应用专属 Calendar 路径可靠删除/改期；
> ② `node tools/test/run.mjs` 虽打印 177/177，却带 5 个 TypeScript 错误并错误返回 0；
> ③ 清空数据还会遗留计划级 ReminderAgent，而不仅是系统日历事件。完整证据、修法与阶段 6R 顺序以
> [全阶段独立验收](../validation/2026-09-23-full-redesign-acceptance.md) 为准。整改完成前，本文件任何旧的“全绿”措辞不得作为提审证据。
>
> **整改进度（同一天的阶段 6R.1 / 6R.3 之后）**：② 已关闭——runner 现在 0 类型错误才算绿，有类型错误直接返回 3；
> ①③ 已在代码层面关闭（默认改成应用专属「同休日」日历的 `addEvent` 受管写入、`editEvent` 降级为「导出」，
> 取消/改期/清空的删不掉的句柄一律保留成 `CLEANUP_PENDING` 并给「重新清理」+ 回前台补扫，清空先清投影再删表并如实报告剩余），
> 对应离线断言 182 条全绿、插桩用例已同步，但**"系统日历里真的出现/真的消失"仍无任何设备证据**，所以 B0/B2 只算"代码已改、真机待验"。
> **本文件的结论不变：仍不具备提审条件**——B1（云开关不是安全边界）、B4（隐私政策与权限文案）、B5（签名与包身份）、B6（零设备证据）一条都没关。

## 0. 判定口径（先读这一节）

- **本轮没有接入任何真机或模拟器**。因此本清单里"通过"只有三种可能来源：离线套件、命令行构建、代码/配置的静态事实。渲染、权限弹窗、系统日历、通知栏、卡片、扫码、备份恢复一律标 **待设备**，不因离线通过而勾掉。
- 发布门禁共五条（改造文档 Task 6.4）：**G1 P0 流程无阻断缺陷 / G2 功能开关关闭时纯本地版可发布 / G3 云数据库无敏感明文 / G4 隐私文案与实际权限一致 / G5 所有数据删除动作可验证**。逐条判定见 §2。
- **本轮结论：不具备提审条件**。原验收登记的 4 类阻断继续成立；独立复核又增加了受管日历生命周期、测试假绿和计划级提醒残留，统一按上方独立验收 B0–B6 整改。设备接入后还要补 TC §1–§20 全量走查。

## 1. 构建与产物证据（本轮实测）

| 项 | 命令 | 结果 |
|---|---|---|
| 清干净 | `hvigorw clean --no-daemon` | BUILD SUCCESSFUL（7 tasks） |
| release 出包 | `hvigorw assembleHap --mode module -p product=default -p module=entry@default -p buildMode=release --no-daemon` | **首次运行失败**，修复后 BUILD SUCCESSFUL，产物 `entry/build/default/outputs/default/entry-default-unsigned.hap` |
| 告警基线 | 同上（统一入口 `node tools/verify.mjs`，先 `clean` 再比 `tools/verify-baseline.json`） | `ArkTS:WARN` **357**（debug 与 release 同值，均比阶段 6.4 的 361 低）、0 error |
| 离线套件 | `node tools/test/run.mjs` | 阶段 6R.3 起 **0 类型错误 / 182 passed / 0 failed / exit 0**（此前"177 passed 但带 5 个 TypeScript 错误且返回 0"的假绿口径已撤销，见上） |
| 插桩包 | `node tools/verify.mjs --steps=ohostest` | 2026-09-23 复跑：编译通过、0 error、`ArkTS:WARN` 262（基线由 266 收紧），**未执行 → 待设备** |

**修复的那条失败必须记下来**：`buildMode=release` 在 5 个 HAR（`commons/domain/data/cloud/feature`）上报
`00304036 Not Found — The obfuscation rule file './obfuscation-rules.txt' cannot be found`。
根因：这 5 个模块的 `build-profile.json5` 都写着 `ruleOptions.files: ["./obfuscation-rules.txt"]`，而**文件不存在**——即使 `enable: false`，hvigor 仍然校验路径。此前所有验收都只跑 `buildMode=debug`，所以这条从未暴露。
处置：按 DevEco「New Module」模板为这 5 个模块补齐 `obfuscation-rules.txt`（内容即模板默认，四行 `-enable-*`）。**注意**：将来任何模块把 `enable` 翻成 `true` 之前，必须先给 `domain`/`cloud` 的 JSON 往返字段加 `-keep-property-name`——快照编解码与 RDB 行映射都按属性名取值，属性名被混淆会在运行时静默读空（判断，非实测）。

**签名**：仓库未配置 `signingConfigs`，release 包是 `-unsigned.hap`。提审需自动签名或正式证书，属人工步骤（§5）。

**生效档位**（`FeatureFlags.summary()`，release 与 debug 同源同值）：
`calendarFlow=on cloudPairing=off scanPairing=off newCard=on responsiveV2=on`。
开关是 `feature/src/main/ets/config/FeatureFlags.ets` 里的**源码常量**，改一行重出包，无远端下发通道（TC §18.1.1）。TC §9.3 旧的"由编译期 BuildProfile 映射"表述与代码不符，本次已更正。

## 2. 发布门禁逐条判定

### G1 P0 流程无阻断缺陷 —— **待设备**

P0 流程 = 录入 → 三答案 → 窗口 → 计划 → 系统日历 → 冲突处理 → 卡片。当前只有两类证据：

- 离线 182 用例（含日历生命周期 19 条、冲突三动作、卡片六态投影、迁移与恢复决策、档位断言）；
- 插桩 3 条端到端用例 + 7 条升级/恢复用例**编译通过、未执行**（TC §0.1、§17.2），刻意不覆盖真实日历写入与删除、通知栏、云端快照。

已知偏离（不当通过、也不判失败，逐条在原文件里）：TC §11.16（卡片点击不带窗口 id）、§13.13/§13.14（大屏双栏无设备可构造）、§14.4（ChipV2 热区未实测）、§17.4（"PAIRED 但无密钥"无运行时自愈）、§10.12（扫码整条闭环无法端到端验）。

### G2 功能开关关闭时纯本地版可发布 —— **不通过（代码）**

`cloudPairing=false` 时纯本地链路确实完整可用：全仓 `rg` 确认除 `cloud` 模块外**没有任何网络调用**
（无 `@kit.NetworkKit`、无 `http.createHttp`），TC §18.1.4 还单独验证过 `calendarFlow=false` 时关闭分支真的在链路上（169 passed / 13 failed，失败项全是日历口径 + 那条档位断言）。

**但有一个入口没有被开关拦住**：

- `feature/src/main/ets/usecase/ProfileSettingsService.ets`
  `createInvite()`（L193）与 `joinByCode()`（L212）**先** `await new AgcPairingClient().createPairing/joinPairing(...)` 发出云函数请求，**再**在成功分支里 `SettingsStore.savePairKey(SnapshotCrypto.deriveKeyHex(code))`；
- 唯一让它今天不生效的原因是 **AGC 未配置**（仓库里既没有 `agconnect-services.json` 也没有 `cloud-config.json`，`cloudFunction.call` 必然抛错走降级），**不是** `FeatureFlags.cloudPairing`；
- 一旦有人把云工程关联上（换机、复用证书、误配置），这条路径会**真的把配对成功态写进本机**，并且用"6 位邀请码派生长期密钥存 Preferences"——同时撞改造文档 §0.3 的两条红线（邀请码不得作为长期快照密钥、长期密钥不得写入 Preferences）。TC §9.4 已经把它写成"停止条件"，但停止条件靠的是"后端不存在"，不是代码。

**提审前必办**：在 `createInvite()` / `joinByCode()` 的 `try` 之前加 `if (!FeatureFlags.cloudPairing) { return fail(同一句降级文案); }`（写库前不发请求），或让这两个按钮在 `cloudPairing=false` 时不渲染。改完后 `MeView` 的文案分支可以一并收敛。
本条不在 Task 6.4 的文件清单内，所以本轮**只登记不修改**（改造文档 §0.1：只改任务列出的文件）。

### G3 云数据库无敏感明文 —— **通过（构造性满足）**

不是"加密做得好"，而是**当前根本没有任何数据会到云数据库**：

- `AgcSnapshotSync.pushSnapshot` 的唯一调用方 `ScheduleUseCase.pushMySnapshot()`（L244）以 `pairId === '' || keyHex === ''` 为前提短路返回 false，而这两个值只有走 G2 那条违规路径才会出现；
- 云数据库侧：`entry/src/main/resources/rawfile` 为空，云 schema 从未部署（`docs/cloud/operations-runbook.md` §1 第 5 项仍未执行）；
- 通知与卡片文本已按"不含课程名/班次名/地点/计划标题/昵称"实现（TC §11.11、§12.10，均**待设备**复核）。

**口径提醒**：这条只在"云端保持关闭"时成立。门禁解除（HUKS 托管长期密钥验证通过）后必须重新判：届时明文边界要看 `SnapshotCodec` 的字段集与 `shareLevel` 裁剪，见 `docs/cloud/pairing-protocol-v1.md`。

### G4 隐私文案与实际权限一致 —— **不通过（材料+文案）**

实际权限只有 4 条（`entry/src/main/module.json5`）：`READ_CALENDAR`、`WRITE_CALENDAR`（两条带 `reason: $string:calendar_perm_reason` = 「用于将共同计划写入系统日历，并在取消计划时同步移除」）、`PUBLISH_AGENT_REMINDER`、`INTERNET`（后两条**无 reason / 无 usedScene**）。逐条比对结果：

| # | 现状 | 结论 |
|---|---|---|
| 1 | 首启弹窗的《隐私政策》全文入口只 toast「隐私政策全文即将上线」（`AppConst.PRIVACY_POLICY_URL` 是空串，`PrivacyUtil.openPrivacyPolicy` 因此不跳转） | **阻断**：应用市场要求可访问的隐私政策链接。必须先成文并托管，再谈提审。文案里"未来云端同步仅存储加密后的忙闲数据"这类前瞻性表述，全文里要如实写明**当前未开通** |
| 2 | `INTERNET` 已声明，但按 G2，唯一使用方是门禁关闭的配对链路 | **需处理**：要么本轮就从 `module.json5` 移除 `INTERNET`（纯本地版确实用不到），要么在隐私政策与提审"权限用途说明"里如实写"仅用于尚未开放的配对功能"。留着一个无用途说明的联网权限是最容易被打回的组合 |
| 3 | `PUBLISH_AGENT_REMINDER` 无 `reason` | **需核对（缺证据）**：本机 SDK 的 `permissions.d.ts` 不标注授权方式；代码里它从未走 `requestPermissionsFromUser`（`ReminderGateway` 直接发布提醒），这与 system_grant 一致，所以缺 reason 很可能合规。提审前按官方权限列表复核该权限是否需要用途说明 |
| 4 | 弹窗第二句「日历事件：仅在你确认创建共同计划时写入系统日历」 | **文案落后于实现（阶段 6R.1 之后差距更大）**：默认路径已经改成"创建时由本应用直接 `addEvent` 写进应用专属的「同休日」日历"，用户确认的是计划 Sheet 上默认勾选的「写入系统日历」开关（TC §6.3），**不再**经过系统日程确认页；`editEvent` 只剩「导出到系统日历」这一个出口（TC §6.6）。"你确认"三个字仍然成立、但"确认什么"已经完全变了，`calendarFlow=false` 关档时更是一次都不写。提审前按这三态重写这句（属 Task 6R.4） |
| 5 | 弹窗末尾「你可以随时在「我的」页调整隐私共享等级（L1 忙闲 / L2 类型 / L3 完整时间）」 | **承诺了当前无可见效果的能力**：等级只参与快照生成，而快照链路关闭（docs/03 L14 已注明"等级只在有云时才有意义"）。要么在「我的」该卡上加一行"云端配对开放后才会影响 TA 看到的内容"，要么本轮先隐藏等级设置 |
| 6 | OCR 页文案「照片仅用于本地识别课表（端侧 OCR），不联网、不保存原图」 | **一致**：`pages/OcrCourse.ets` 走 `cameraPicker.pick` + `PhotoViewPicker.select`（系统 Picker，无需应用侧相机/相册权限），识别用端侧 `textRecognition`；全仓无图片上传代码 |
| 7 | `AppScope/app.json5`：`bundleName: com.huawei.commonrestday`、`vendor: example`、`versionName 1.0.0 / versionCode 1000000` | **阻断/待定稿**：`vendor` 明显仍是模板值；包名前缀与开发者主体也必须在首个正式包前确认。包名正式使用后不可随意更换（改了就是另一个应用：卡片、深链 scheme `crdpair`、已授权权限全部重来） |

### G5 所有数据删除动作可验证 —— **代码已改（阶段 6R.1）；判定停在待设备**

盘点（用户能触发的删除动作共 6 类）：

| 动作 | 实现 | 删到哪 | 离线断言 | 设备验证 |
|---|---|---|---|---|
| 取消计划 | `PlanUseCase` + `PlanProjectionCleanupService`（只清系统侧、不写库） | 窗口恢复空闲 + 受管日程移除 + 本应用提醒取消；**删不动时句柄原样留着**、状态转 `CLEANUP_PENDING`、卡片给「重新清理」 | **有**（19 条日历用例里含"删不动→留句柄→重试→补写""导出那份永不试删"） | 待设备（TC §6.9、§6.10） |
| 冲突改期 | 同上迁移 | 旧事件删 + 新事件写；旧投影没让开就**不写新的**（避免同一天两条） | **有** | 待设备（TC §6.8、§7.6） |
| 删除伴侣档案 | `ProfileSettingsService.deletePartner` | `clearPartnerProfile` + 4 张表 `owner='PARTNER'` 行；**plan 表不动**（共同计划是本机的，口径与弹窗文案一致） | 无 | 待设备（TC §3.5） |
| 解除配对 | `ProfileSettingsService.unpair` | 云侧 `pairing-unpair`（当前必降级）+ 本机清 key/pairId/状态/快照游标 | 无 | **本轮无法到达**（只能经 G2 违规路径配对，TC §9.4） |
| 清空全部数据 | `ProfileSettingsService.clearAllData` | **先**逐条清投影（`listPlansCarryingHandles` → 删日程/撤提醒）→ `purgeManagedCalendar()` 兜底清「同休日」那一本 → 取消周摘要提醒 → **再**清 8 张 RDB 表与全部设置（隐私同意标记刻意保留）；确认弹窗与结果 toast 都按实际剩余播报 | 口径**有**（`clearAllMessageOf`：没清掉的一律列出）；动作本身**无**——它删的是用户真机数据，不能放进自动化里跑一次 | 待设备（TC §20.1，含 20.1.3/20.1.4 的"真删了没有""删不动时有没有谎报"） |
| 备份恢复后的降级 | `Db` 首启消费恢复标记 | 三条 UPDATE：日历投影（含 `MANAGED_WRITTEN`/`EXTERNAL_UNMANAGED`/`CLEANUP_PENDING`/`WRITTEN`/`PENDING` 五种取值）→`LOCAL_ONLY` 并清空来源设备的事件 id、提醒句柄→`-1`、云端声明→本地 | **有**（`DbMigrationTest` 12 条 + 插桩 7 条） | 待设备（TC §17.3） |

**阶段 6R.1 已改**：`clearAllData()` 不再是"`DELETE FROM plan` 完事"——现在先清系统侧投影再删表，删不掉的按条数如实报；普通取消/改期也不再吞掉投影删除失败，句柄留着并可重试。修法与判据见独立验收 B0/B2。
**这条门禁为什么还不算通过**：G5 要的是"可验证"，而以上每一条最终都要在设备上看见**系统日历里真的少了一条、提醒列表里真的没有残留**。本轮零设备证据（B6），所以 G5 的判定停在 **待设备**；`ProfileSettingsService` 是设备耦合源码（离线 runner 里被 skip），因此清空动作的离线断言只覆盖到播报口径这一半。
**还缺的一条**：`deletePartner` 与 `unpair` 两类删除动作连口径断言都没有（表里"无"），补它们属阶段 3 门禁解除后的工作，本轮不扩大范围。

## 3. 发布矩阵（改造文档 Task 6.4 指定的 9 维）

| 维度 | 本轮可判 | 待设备 / 阻断 | 指路 |
|---|---|---|---|
| 全新安装 / 升级安装 | 全新安装：`bm clean` 后首启链路（待设备）。**升级维度对首版是空集**——本应用从未上架，没有可升级的线上包；这一维现在只有离线夹具 12 条（`DbMigrationTest`）+ 插桩 7 条（编译通过、未执行）撑着 | 老包→新包的真实覆盖安装留给第二个版本 | TC §1、§17.1/§17.2 |
| 单人 / 本机代录 / 云配对 | 单人、本机代录：离线用例 + 静态文案核对。云配对：**保持关闭**，且入口本身是 G2 的待修项 | 两形态的渲染与重算走查 | TC §2–§4、§9 |
| 在线 / 离线 / 云停服 | **离线与在线同一份代码路径**（本机链路零网络调用）；"云停服"= 当前常态，降级为 toast + 停在未配对态 | 飞行模式下全量回归一次（证明没有隐藏依赖） | §2 G2/G3、TC §9.3 |
| 通知允许 / 拒绝 | 三档默认值与文案已在代码里定死（需行动开、精确提醒关、周摘要关） | 授权弹窗、去重、锁屏隐私、到点真响 | TC §12 |
| 日历允许 / 取消 | 默认是**应用专属「同休日」日历的受管写入**（`addEvent`，不弹系统确认页）；拒绝授权 → `LOCAL_ONLY` + 「写入日历」/「导出到系统日历」两个出口；删不动 → `CLEANUP_PENDING` + 「重新清理」：这三处口径都有离线断言 | 权限弹窗、专属日历那一本真出现/真消失、`createCalendar` 是否真的建得出「同休日」、导出确认页、`CLEANUP_PENDING` 重新授权后真清得掉、回前台补扫真的跑 | TC §6、§18.2.2/§18.2.3 |
| 扫码支持 / 不支持 | `scanPairing=false` + `canIUse(Scan)` 双前置 → 当前构建**不出现扫码按钮**（静态判定） | 两种设备各确认一次；真扫码闭环等门禁解除 | TC §10 |
| 360vp / 横屏 / 大字体 / Senior Mode / 深色 | 令牌与断点口径为静态事实（`fp` 字号、`hit_min 44vp`、断点按容器宽度）；**横屏没有任何适配代码**（全仓无 `orientation` 声明，也没有横屏布局分支），横屏下手机宽度会落进 medium/expanded，从而触发为平板设计的双栏 | **产品决定已在独立验收里定稿：首发暂时锁竖屏**（`EntryAbility` 的 ability 上加 `orientation: 'portrait'`），横屏真机验收通过后再开放——落地属阶段 6R.4，本轮尚未改。五种形态逐屏截图仍全部待设备 | TC §8、§13、§14、§15 |
| 卡片添加 / 更新 / 移除 | 只有 2×2、六态投影、路由白名单、只从桌面添加：静态事实 + 离线用例 | 卡面渲染、跨进程刷新、伪造参数、移除重加 | TC §11 |
| 配对解除 / 清本机数据 / 备份恢复 | 恢复降级有离线断言（含新状态与 `CLEANUP_PENDING` 句柄作废）；解除与清空见 G5 | 备份→恢复往返、清空后「同休日」日历与提醒是否真没残留 | TC §17、§2 G5、§20.1 |

## 4. 灰度与回退（引用，不重复）

档位表、每档的启用条件/关闭影响/数据兼容性、以及"关档不关数据"规则见
[rollout-and-rollback](./rollout-and-rollback.md)；设备侧关档走查清单是 TC §18.2。
本项目**没有按用户分流的能力**（开关是编译期常量，一档一包），也**没有远端遥测**——放量判断只能建立在"关闭影响是否可逆 + 数据是否兼容"上。

## 5. 提审材料清单（全部人工，本轮未动）

- [ ] 《隐私政策》全文成文并托管为可访问 URL（G4-1；须如实写：不接华为账号、当前无云端同步、`INTERNET` 的实际用途、数据删除方式=清空本机数据/卸载）
- [ ] 权限用途说明与 G4 表逐条对齐（尤其 `INTERNET`、`PUBLISH_AGENT_REMINDER`）
- [ ] 应用截图（首页/共同时间/我的/班表/卡片）+ 一句话介绍 + 分类（生活或效率）+ Age rating + 版权/开发者信息
- [ ] App 备案（docs/04 M0 第 5 项登记为"本周发起"，至今**无状态记录** → 需回填实际进度）
- [ ] 签名配置（自动签名或正式证书）后重跑一次 release 出包，确认产物不再是 `-unsigned`
- [ ] AGC：创建云资源与否的决定与 `docs/cloud/operations-runbook.md` §1 前置清单一并记录（保持关闭就明确写"首版不开通"）

## 6. 完成定义对照（改造文档末尾 8 条）

| 条件 | 状态 |
|---|---|
| 三个主入口与精简原型一致，旧四 Tab 不再存在 | 达成（Task 6.3 复验：无四 Tab 残留，`main_pages.json` 6 个入口全在用） |
| 首页、窗口详情、计划、日历和卡片形成一条真实数据链路 | 代码与离线达成（阶段 6R.1 后这条链路是"窗口 → 本机计划 → 应用专属日历受管投影 → 卡片"，取消/改期/清空都跟着投影走）；**真机端到端待设备** |
| 本地数据在无网、无云、无权限时仍可使用 | 达成（本机链路无网络调用；权限拒绝有降级分支，弹窗侧待设备） |
| 配对数据端侧加密，长期密钥由 HUKS 托管 | **未达成**——Task 0.4 判 `CLOUD_BLOCKED`，HUKS 链路未验证；现状是"云端整体关闭"。按红线**不允许**用短码派生密钥充当（G2 那条待修代码正是这个反例） |
| 云工程位置和运维方式有实测结论 | 部分：`docs/05` + `operations-runbook` 是文档级结论，"实测"两字仍缺（无 AGC 账号操作记录） |
| 360vp、深色、大字体、读屏和 Senior Mode 达标 | 代码口径达成，**达标与否待设备**（§3 第 7 行，含横屏缺口） |
| 所有阶段构建、自动化测试与手工验收记录齐全 | 构建/自动化齐全（§1）；手工验收记录=空，全部待设备 |
| 文档不再保留与实现相冲突的旧技术结论 | 达成（Task 6.3；本轮再更正 TC §9.3 的 BuildProfile 表述与 `docs/05` 一处路径） |

**净结论**：8 条里 3 条达成（三主入口 / 本机数据自足 / 文档与实现不再冲突）、1 条按门禁承诺未达成（HUKS 托管长期密钥）、4 条卡在"证据只到代码与离线这一层"（真机端到端、云侧实测、五种显示形态、手工验收记录）。
提审前最少要闭合：G2 的代码级云守卫（阶段 6R.2）、G4 的隐私政策成文 + 日历那句文案重写 + `INTERNET` 处置（阶段 6R.4）、D1 计划类型精简与 D2 锁竖屏（阶段 6R.4）、签名与备案材料（B5），以及设备接入后按 TC §1–§20 全量勾一遍（B6）——G1 与 G5 的判定都卡在这最后一项上：代码与离线口径已经改完，缺的是"系统日历里真的少了那条、提醒列表里真的没有残留"这类只有设备能给的证据。
