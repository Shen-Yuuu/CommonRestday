# 两人份（For Two）API 26 发布验收清单（始于 2026-09-23）

> **当前增量（2026-09-29）**：开档包 `cloudPairing=true`、`INTERNET` 已声明；批次 AP 后两档离线各 270/0，debug/release 289 WARN、ohosTest **仅出包** 269 WARN、perf 在预算内。AO 破坏性设备证据、真机走查、正式签名与账号材料仍未齐，结论仍是 **NOT RELEASE READY**。本页历史段落保留原貌，当前代码与人工操作边界见 [无设备交接](../validation/2026-09-29-offline-handoff.md) 和 [开发者操作步骤](../validation/2026-09-29-operator-actions.md)。

> 对应改造文档 Task 6.4。本文件只做一件事：**把"能不能提审"拆成可判定的条目，并写清每一条现在有什么证据**。
> 逐屏操作口径不在这里重复，全部在 [真机验收清单](../testing-checklist.md)（下面记作 `TC §n`）。

> **最终复核（2026-09-23）：** 统一门禁已独立复跑为 0 类型错误 / 195 passed、debug/release/ohosTest
> 349/349/260 WARN、性能全绿，但仍判 `NOT RELEASE READY`。除本页已有的账号、签名和设备缺口外，
> 最终复核新增两项：启用系统备份恢复与隐私政策“数据只在这台手机”承诺冲突；清空本机数据后已丢失
> 投影句柄，却仍提示“可稍后重试”。证据、修法与最终 Go/No-Go 以
> [全阶段改造最终验收](../validation/2026-09-23-final-redesign-acceptance.md) 为最高优先级口径。

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
>
> **阶段 6R.2 之后（同日）补充**：G2/B1 的**代码**部分已封口——`createInvite/joinByCode/markPaired` 第一句看档位，
> 关闭态不发 uid 生成、不发云函数、不写配对标记；`deriveKeyHex` 与 `savePairKey` 两个生产写入口**已删除**（翻开关复现不出"短码派生密钥落 Preferences"）；
> `module.json5` 首发移除 `INTERNET`；`MeView` 关闭态一格云入口都不摆。离线新增 8 条守卫用例（190 passed / 0 类型错误）。
> G3 的"构造性满足"因此更硬了一层，但 **G2 的判定仍停在待设备**（真机确认这个包确实一条请求都不出本机），
> B4/B5/B6 一项没动，本文件的"不具备提审条件"结论不变。
>
> **阶段 6R.4 之后（同日）补充**：B4 与三个定稿决策的**仓库侧**已落地——《隐私政策》全文改成随包内置半模态
> （这个包按定稿没有 `INTERNET`，"打开托管 URL"在当前形态做不到，所以入口不再是 toast；托管 URL 降为商店材料），
> 首启摘要四条与「共享等级」那句空头承诺按阶段 6R.1 的实际行为重写，创建计划类型精简为「一起吃饭 / 其他」
> 且旧 8 类保留兼容标签映射（离线新增 5 条用例钉住两半），EntryAbility 锁 `orientation: 'portrait'`。
> B5 的仓库侧做成一张待回填表（`submission-materials.md`：包身份/签名/备案/隐私政策/商店材料）。
> **B4/B5 的账号侧与设备侧一项没关**：URL 托管、`vendor` 定稿（`bundleName` 已于 2026-09-25 更新为 `com.common.fortwo`）、备案状态、签名出包、商店截图都要开发者账号或真机，
> 本文件结论仍是**不具备提审条件**（B6 零设备证据未动）。
>
> **最终验收 R1 + R2 追加整改（2026-09-23，见 [全阶段改造最终验收](../validation/2026-09-23-final-redesign-acceptance.md) §4）**：
> **R1（P0）**——`backup_config.json` 的 `allowToBackupRestore: true` 与政策里"数据只存在这台手机/不会离开这台手机"
> 是两句不能同时成立的话。按验收推荐**保留备份能力、修订披露**：全文加一节「系统备份与换机迁移」（十一节），
> 首启摘要加第二条同口径（五条），`pp_data_b`/`pp_delete_b` 里那两处绝对化表述改掉，恢复后句柄与配对的降级
> 写进政策（与 `EntryBackupAbility` 的实际行为一致）。**替代方案（关掉备份）未采用**，因此设备侧必须真跑一次
> 备份/克隆来证明这一节说出口的话成立（TC §17.3.6）。
> **R2（P1）**——`clearAllMessageOf` 不再复用"可稍后重试"：清库把计划行连同投影句柄一起删了，
> 那句话承诺的是一个已经不存在的能力，改为"本应用已无法再替你清理，请到系统日历/系统设置检查"；
> 普通取消/改期仍保留重试文案（那条路径留着 `CLEANUP_PENDING`，重试可兑现），两侧各有一条离线断言钉住。
> **另外把"三份文字同源"从注释变成门禁**：`tools/test/copy-audit.mjs` 逐字比对应用内全文、canonical md、
> 托管 html 与首启摘要，并禁止绝对化表述，违反即 `node tools/test/run.mjs` 退出码 1（负向已实测：改一个字即报两处冲突）。
> **B4 的判定不变**：文案侧的自相矛盾已消除，但"这一页话当场是否成立"仍然只能真机判（B6）。

> **批次 U·U3b 开闸追加更正（2026-09-27）**：本页按"只追加、不改写历史"的规矩保留 2026-09-23 的原文，
> 所以凡写着"首发包不带 `INTERNET`""`cloudPairing=false`""本包一格云入口都不摆"的句子，**从这一天起都是历史口径**，
> 当前档位与关闭影响一律以 [灰度发布与回退口径](rollout-and-rollback.md) §2/§3.3 为准。变化的四条：
> ① `cloudPairing = true`，`entry/src/main/module.json5` 的 `requestPermissions` 现在 **3 条**
> （`READ_CALENDAR`/`WRITE_CALENDAR`/`INTERNET`；INTERNET 是 system_grant、不弹授权框，带 `reason: $string:internet_perm_reason`）；
> ② 《隐私政策》升到 **v1.1**（「云端配对」一节写明只同步降维加密后的忙闲快照、密钥只在 HUKS、不进备份），
> 首启摘要两条随之改写，提审的权限用途说明落在 `submission-materials.md` §4b；
> ③ rollout §3.3 的第 ② 条同批条件（HUKS 托管长期密钥）已有一次设备实测：两台 API 26 模拟器、10 条 Hypium 用例，
> 记录在仓库外 `CloudDevSpike/OFFICIAL_SMOKE_STATUS.md`，摘要见 `docs/validation/clouddev-api26-spike.md`；
> ④ 离线门禁改成**两桶**（`CRD_TIER=closed` / `open` 各一遍，两桶各 0 类型错误 / 220 passed），
> 所以"关档分支"仍然每天被编译并被证明，而不是因为档位开了就失去证据。
> **G2 的语义因此翻转**：原来那条"功能开关关闭时纯本地版可发布"是由发布档位直接满足的，
> 现在发布档位是**开档**，纯本地版退成"**回退档**也必须可发布"——它的两半证据是离线闭档那一桶 + TC §18.2.8 的关档包走查。
> **G4 的判定方向也翻转**：以前"少声明权限"是安全的一侧，现在多一条 `INTERNET` 就多一份"用途说明必须与包内实际一致"的责任；
> 已按 ①② 同批补齐，仍停在待设备（TC §20.3/§20.5）。
> **本页结论不变**：**仍不具备提审条件**。开闸 ≠ 取证——协议 §11 十条设备证据一条都没勾，
> B5（备案、签名、包名回填）与 B6（商店截图、全量设备走查）一项没动，这三项都是提审硬前置。

## 0. 判定口径（先读这一节）

- **本轮没有接入任何真机或模拟器**。因此本清单里"通过"只有三种可能来源：离线套件、命令行构建、代码/配置的静态事实。渲染、权限弹窗、系统日历、通知栏、卡片、扫码、备份恢复一律标 **待设备**，不因离线通过而勾掉。
- 发布门禁共五条（改造文档 Task 6.4）：**G1 P0 流程无阻断缺陷 / G2 功能开关关闭时纯本地版可发布 / G3 云数据库无敏感明文 / G4 隐私文案与实际权限一致 / G5 所有数据删除动作可验证**。逐条判定见 §2。
- **本轮结论：不具备提审条件**。原验收登记的 4 类阻断继续成立；独立复核又增加了受管日历生命周期、测试假绿和计划级提醒残留，统一按上方独立验收 B0–B6 整改；最终验收再补 R1（备份恢复与"只在本机"自相矛盾）与 R2（清库后仍承诺可稍后重试）。阶段 6R.1–6R.4 与 R1/R2 之后 **B0/B1/B2/B3 与 B4/B5 的仓库侧已封口**，剩下的卡点收敛为两类：**账号侧材料**（隐私政策 URL 托管、`vendor` 定稿、按新包名 `com.common.fortwo` 配置备案与签名、商店截图）与 **B6 零设备证据**（TC §1–§20 全量走查，含 R1 的备份/克隆往返与 R2 的清空谎报检查）。设备接入前，G1/G2/G4/G5 的判定都停在待设备。

## 1. 构建与产物证据（本轮实测）

| 项 | 命令 | 结果 |
|---|---|---|
| 清干净 | `hvigorw clean --no-daemon` | BUILD SUCCESSFUL（7 tasks） |
| release 出包 | `hvigorw assembleHap --mode module -p product=default -p module=entry@default -p buildMode=release --no-daemon` | **首次运行失败**，修复后 BUILD SUCCESSFUL，产物 `entry/build/default/outputs/default/entry-default-unsigned.hap` |
| 告警基线 | 同上（统一入口 `node tools/verify.mjs`，先 `clean` 再比 `tools/verify-baseline.json`） | R1+R2 整改后复跑 `ArkTS:WARN` 仍 **349**（debug 与 release 同值）、ohosTest **260**、0 error，与 6R.4 同档未收紧（基线沿革 361→357→352→349 见独立验收 §9.3/§9.5） |
| 离线套件 | `node tools/test/run.mjs` | R1+R2 整改后复跑 **copy PASS / 0 类型错误 / 195 passed / 0 failed / exit 0**（用例数不变：R1/R2 的断言是加进既有用例里的正反对照，"三份全文逐字同源"由 `copy-audit.mjs` 单独一行判定，见 §2 G4 行 1/8）。阶段 6R.3 起才有"0 类型错误才算绿"的口径；此前"177 passed 但带 5 个 TypeScript 错误且返回 0"的假绿口径已撤销，见上 |
| 插桩包 | `node tools/verify.mjs --steps=ohostest` | 2026-09-23 复跑：编译通过、0 error、`ArkTS:WARN` 260，**未执行 → 待设备** |

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

- 离线 195 用例（含日历生命周期 19 条、冲突三动作、卡片六态投影、迁移与恢复决策、档位断言、云关闭态守卫 6 条与清空播报口径 2 条、计划类型精简与兼容映射 5 条）；
- 插桩 3 条端到端用例 + 7 条升级/恢复用例**编译通过、未执行**（TC §0.1、§17.2），刻意不覆盖真实日历写入与删除、通知栏、云端快照。

已知偏离（不当通过、也不判失败，逐条在原文件里）：TC §11.16（卡片点击不带窗口 id）、§13.13/§13.14（大屏双栏无设备可构造）、§14.4（ChipV2 热区未实测）、§17.4（"PAIRED 但无密钥"无运行时自愈）、§10.12（扫码整条闭环无法端到端验）。

### G2 功能开关关闭时纯本地版可发布 —— **代码已封口（阶段 6R.2）；判定停在待设备**

`cloudPairing=false` 时纯本地链路确实完整可用：全仓 `rg` 确认除 `cloud` 模块外**没有任何网络调用**
（无 `@kit.NetworkKit`、无 `http.createHttp`），TC §18.1.4 还单独验证过 `calendarFlow=false` 时关闭分支真的在链路上（169 passed / 13 failed，失败项全是日历口径 + 那条档位断言）。

**2026-09-23 复核登记的"有一个入口没有被开关拦住"已按 B1 四条整改逐条改掉**：

- `ProfileSettingsService` 新增单一判据 `cloudBlocked()`，`createInvite()` / `joinByCode()` / `markPaired()` **第一句**就返回 `FeatureFlags.cloudClosedMessage`——在其之前既不 `getOrCreateUid()`、也不 `new AgcPairingClient()`、更不写 `pairId/pairKey/pairState`；成功分支里的 `savePairKey(deriveKeyHex(code))` 三处全部删除；
- **结构保险**（防"以后只翻开关就复活不安全实现"）：`SnapshotCrypto.deriveKeyHex` 与 `SettingsStore.savePairKey` 两个方法**已从源码删除**，`getPairKey` 转为只读、`clearPairKey` 只用来清旧原型残留；
- 入口不再只在 UI 上藏：`PairingShareGateway.channels()` 把 `share`/`scan` 都以云端档位为前提，`offerFromScan()` / `shareLink()` / `offerIncoming()` 在网关层各自先拒（关闭态不开相机、不开分享面板、外来 want 不留痕也不广播 `pairOfferCount`）；`ScheduleUseCase.pullPartnerSnapshot/pushMySnapshot` 第一句看档位；
- `MeView` 关闭态一格云入口都不摆（生成/输码/扫码/二维码/分享/共享等级一起收），只留本机代录说明与**退出通道**（上一版原型留下的 `PAIRED`/`WAITING` 仍能被用户亲手撤掉——「开关只关能力，不关数据」）；
- `entry/src/main/module.json5` 移除 `ohos.permission.INTERNET`：这个包即便代码有漏网的云调用也发不出去。**（2026-09-24 D-20 连带：`requestPermissions` 现为 2 条，`READ_CALENDAR`/`WRITE_CALENDAR`——后台代理提醒权限随零通知定稿一起删掉了。）**

**证据**：离线新增 `entry/src/test/ProfileSettingsGuardTest.ets` 8 条（含"关闭态 `AgcPairingClient.calls === 0` 且 pairId/key/state 三者不变"），当轮 190 passed / 0 类型错误 / exit 0（阶段 6R.4 复跑 195 passed）；替身的云客户端**总是成功**，所以这条断言只能由守卫给出、不能靠"AGC 恰好没配"。变异验证：临时移除 `createInvite` 首句守卫 → 只有那条用例失败。

**为什么还判待设备**：G2 要的是"这个包交出去是可发布的"，而"移除 INTERNET 之后一切照常 + 飞行模式无差异 + 权限面板里没有联网项"这三条只有设备能给（TC §9.3、§9.5、§18.2.1、§20.5）。阶段 3 门禁未解除前，仍然**不允许测试性打开** `cloudPairing`。

### G3 云数据库无敏感明文 —— **通过（构造性满足）**

不是"加密做得好"，而是**当前根本没有任何数据会到云数据库**：

- `AgcSnapshotSync.pushSnapshot` 的唯一调用方 `ScheduleUseCase.pushMySnapshot()` 现在**第一句**就是 `if (!FeatureFlags.cloudPairing) return false`；其后 `pairId === '' || keyHex === ''` 那道短路仍然在，且因为 `SettingsStore.savePairKey` 已删除，本机已经没有任何代码路径能写出密钥——G2 那条违规路径不再是"配了就能同步"，而是"连钥匙都造不出来"；
- 云数据库侧：`entry/src/main/resources/rawfile` 为空，云 schema 从未部署（`docs/cloud/operations-runbook.md` §1 第 5 项仍未执行）；
- 卡片文本已按"不含课程名/班次名/地点/计划标题/昵称"实现（TC §11.11，仍**待设备**复核）。通知侧自 2026-09-24 D-20 起零通知：不发通知，也就没有通知正文可言（原先这条引的 TC §12.10 锁屏隐私判据随链路删除）。

**口径提醒**：这条只在"云端保持关闭"时成立。门禁解除（HUKS 托管长期密钥验证通过）后必须重新判：届时明文边界要看 `SnapshotCodec` 的字段集与 `shareLevel` 裁剪，见 `docs/cloud/pairing-protocol-v1.md`。

### G4 隐私文案与实际权限一致 —— **代码与材料已改（阶段 6R.4 + 最终验收 R1）；判定停在待设备**

实际权限只有 2 条（`entry/src/main/module.json5`）：`READ_CALENDAR`、`WRITE_CALENDAR`（两条带 `reason: $string:calendar_perm_reason` = 「用于将共同计划写入系统日历，并在取消计划时同步移除」）。**阶段 6R.2 已按定稿移除 `INTERNET`**；**2026-09-24 D-20 又把后台代理提醒权限一并移除**——首发零通知：不申请通知授权、不注册任何系统提醒，那条权限没有使用方，提审时少一个问答题。**阶段 6R.4 已把下表第 1/4/5/7 行的文案与材料口径统一到位**，第 3 行随 D-20 关闭；第 8/9 行是最终验收新登记的 R1（备份恢复披露）与 R2（清空后的重试承诺）。逐条比对结果：

| # | 现状 | 结论 |
|---|---|---|
| 1 | 首启弹窗的《隐私政策》全文入口只 toast「隐私政策全文即将上线」（`AppConst.PRIVACY_POLICY_URL` 是空串，`PrivacyUtil.openPrivacyPolicy` 因此不跳转） | **代码已处理（阶段 6R.4，最终验收 R1 补一节）**：全文改为随包内置半模态 `component/PrivacyPolicySheet.ets`（**十一节**，含 R1 新增的「系统备份与换机迁移」；首启弹窗与「我的 · 数据与隐私」两处入口共用同一 builder），`PrivacyUtil` 与 `privacy_fulltext_soon` 文案已删除。**为什么内置而不是跳 URL**：这个包按定稿没有 `INTERNET` 权限，用浏览器打开托管页在当前形态下根本做不到，"入口存在但只会 toast"就是这么来的。剩下的缺口是账号侧：应用市场仍要求填写可访问的隐私政策 URL，《隐私政策》全文已成文（`docs/legal/privacy-policy.md`）并附一份可直接上传的静态页（`docs/legal/privacy-policy.html`），托管动作需开发者账号执行，URL 回填到 `AppConst.PRIVACY_POLICY_URL`（空串时全文页底部显示"在线版地址尚未填写"，不阻断阅读）。**三份文字 + 五条摘要的逐字同源已进门禁**（`tools/test/copy-audit.mjs`，冲突即退出码 1），前瞻性表述已如实写明**当前未开通**（第 7 节「云端配对当前未开放」） |
| 2 | `INTERNET` **已声明但无用** | **已处理（阶段 6R.2）**：`module.json5` 删掉该权限，`requestPermissions` 只剩 3 条；纯本地版连"发不出去"都不成立——没有联网权限。隐私政策与提审"权限用途说明"里因此**不得**出现"联网权限"字样，云端档位真正打开的那个包才把它加回来（`docs/release/rollout-and-rollback.md` §3.3）。仍需设备复核：无 INTERNET 时日历/卡片链路确实无差异 |
| 3 | `PUBLISH_AGENT_REMINDER` 无 `reason` | **已随 D-20 关闭（2026-09-24）**：该权限整条从 `module.json5` 删除，本应用不再注册系统提醒，所以"是否需要用途说明"这个官方列表复核动作没有对象了。原先登记的判断（"从未走 `requestPermissionsFromUser`，与 system_grant 一致，缺 reason 很可能合规"）保留在此作为记录——它属于**判断**，本仓库没有可引的官方条款 |
| 4 | 弹窗第二句「日历事件：仅在你确认创建共同计划时写入系统日历」 | **已按三态重写（阶段 6R.4）**：该句现为 `privacy_point_calendar` =「共同计划默认写进本应用专属的「同休日」日历，改期与取消会自动跟着同步；导出到系统日历的那一条要你自己管理」，与阶段 6R.1 的实际路径一致——默认勾选走受管 `addEvent`（不弹系统确认页，TC §6.3），`editEvent` 只剩「导出到系统日历」一个出口且那条永不试删（TC §6.6），`calendarFlow=false` 关档时一次都不写（TC §18.2）。全文第 4 节「系统日历的边界」是同口径（D-20 起该节只讲日历：标题、正文与权限段一起改成"零通知、不注册任何系统提醒"）。逐字对照动作仍在设备侧（TC §20.3） |
| 5 | 弹窗末尾「你可以随时在「我的」页调整隐私共享等级（L1 忙闲 / L2 类型 / L3 完整时间）」 | **已替换（阶段 6R.4）**：这句空头承诺删掉了，改为 `privacy_level_hint` =「上面几条是《隐私政策》全文的摘要，措辞不一致时以全文为准。」——等级控件在 `cloudPairing=false` 时不渲染（6R.2 收走），首发版没有可调的等级，因此界面上不再出现做不到的承诺。全文第 7 节明写"云端配对当前未开放、等级项在界面上不出现、值仍存本机"。设备侧确认新那句对应的全文真能打开（TC §20.3） |
| 6 | OCR 页文案「照片仅用于本地识别课表（端侧 OCR），不联网、不保存原图」 | **一致**：`pages/OcrCourse.ets` 走 `cameraPicker.pick` + `PhotoViewPicker.select`（系统 Picker，无需应用侧相机/相册权限），识别用端侧 `textRecognition`；全仓无图片上传代码 |
| 7 | `AppScope/app.json5`：最初 `bundleName: com.huawei.commonrestday`，后改为 `com.rest.common`；`vendor: example`、`versionName 1.0.0 / versionCode 1000000` | **2026-09-25 再次改为 `com.common.fortwo`**，`vendor` 仍是模板值 `example` 待账号侧填。此前关于 `com.huawei.*` 前缀的风险仅为判断，并非官方强制要求；历史上"没有旧包安装设备"的结论**不可沿用**：如今设备上可能已安装 `com.rest.common`，新包会成为另一款应用，数据、授权和桌面卡片不会自动迁移。签名 Profile、AGC 应用、备案和设备命令都须使用新包名；见 `submission-materials.md` §1 |
| 8 | `backup_config.json` 的 `allowToBackupRestore: true` + `EntryBackupAbility` 已接入：系统会在**应用克隆与应用数据迁移**时带走整个沙箱（RDB + Preferences），但政策原文只说"数据只存在这台手机上" | **已按最终验收 R1 修订披露（不关能力）**：全文新增「系统备份与换机迁移」一节、首启摘要加第二条，`pp_data_b`/`pp_delete_b`/`privacy_point_local`/`privacy_point_cloud` 四处绝对化表述改掉，**连界面上那句口号一起**——`MeView.identitySub()` 在「我的」页顶部原本显示「数据只存在这台手机」，现改「数据只写在本机的应用沙箱里」（它不属于《隐私政策》，所以由 `copy-audit.mjs` 对全部随包源码生效的同一条禁令钉住），改成"写在本机应用沙箱 + 系统备份或换机迁移时可能随系统流程恢复到你的其他设备"；同时写明恢复后**系统日历句柄作废、配对回到未配对**（与 `EntryBackupAbility` + `MigrationRunner.finishRestore` 的实际行为对应；提醒句柄自 D-20 起不再新建，恢复降级仍把它归 -1，但政策正文只承诺日历这一侧）。**未采用**的另一方案（`allowToBackupRestore: false` 并停用备份扩展）理由：阶段 6.1 的恢复降级对换机用户有实际价值，而披露足以消除误导。禁止绝对化表述已由 `copy-audit.mjs` 机器把关，且这一条禁令**不只管《隐私政策》**：`entry/feature/data/cloud/commons/domain` 的 `src/main` 里任何 `.ets`/`.json` 出现同类措辞都会失败；**这一节当场是否成立仍待真机做一轮备份/克隆往返**（TC §17.3.6，B6） |
| 9 | 「清空我的全部数据」失败分支仍提示「可稍后重试」，但清库已把计划行与投影句柄一起删掉，重试无凭据（最终验收 R2） | **已处理**：`clearAllMessageOf` 不再复用 `cleanupMessageOf`，清空后的那句改成"本应用已无法再替你清理，请到系统日历/系统设置检查"；`cleanupMessageOf`（取消/改期）保留"可稍后重试"，因为那条路径留着 `CLEANUP_PENDING` 句柄与「重新清理」入口，承诺可兑现。两侧各有一条离线断言把这句话钉住（`PlanUseCaseTest` 的正反对照 + `ProfileSettingsGuardTest` 跑真实 `clearAllData()`）。设备侧仍要确认残留条目真的只能人工删（TC §20.1.4） |

### G5 所有数据删除动作可验证 —— **代码已改（阶段 6R.1 + 最终验收 R2）；判定停在待设备**

盘点（用户能触发的删除动作共 6 类）：

| 动作 | 实现 | 删到哪 | 离线断言 | 设备验证 |
|---|---|---|---|---|
| 取消计划 | `PlanUseCase` + `PlanProjectionCleanupService`（只清系统侧、不写库） | 窗口恢复空闲 + 受管日程移除（旧行上残留的提醒句柄一并撤；D-20 起没有新建的提醒）；**删不动时句柄原样留着**、状态转 `CLEANUP_PENDING`、卡片给「重新清理」 | **有**（19 条日历用例里含"删不动→留句柄→重试→补写""导出那份永不试删"） | 待设备（TC §6.9、§6.10） |
| 冲突改期 | 同上迁移 | 旧事件删 + 新事件写；旧投影没让开就**不写新的**（避免同一天两条） | **有** | 待设备（TC §6.8、§7.6） |
| 删除伴侣档案 | `ProfileSettingsService.deletePartner` | `clearPartnerProfile` + 4 张表 `owner='PARTNER'` 行；**plan 表不动**（共同计划是本机的，口径与弹窗文案一致） | 无 | 待设备（TC §3.5） |
| 解除配对 | `ProfileSettingsService.unpair` | 本机清 key 残留/pairId/状态/快照游标（**关闭态照样全执行**，因为云入口已藏起来，用户必须还能亲手撤掉上一版原型留下的标记）；云侧 `pairing-unpair` 只在 `cloudPairing=true` 时才发 | **有**（阶段 6R.2：`unpair_clears_local_marks_in_every_tier`（批次 U·U3b 改了名并改成分桶）断言本地四项清空，且 `AgcPairingClient.calls` 在闭档桶 `===0`、开档桶 `===1`；`cancel_waiting_needs_no_cloud` 同样） | 真机上的"已配对"标记是否清干净 → 待设备（TC §9.4/§9.5）；云侧解绑原先记作"本轮无法到达（`CLOUD_BLOCKED`）"，**批次 U·U3b 起这条作废**——开档包里可达，判据是 AGC 控制台里该 pair 的会话行与两行快照一起消失（协议 §11 第 9 条） |
| 清空全部数据 | `ProfileSettingsService.clearAllData` | **先**逐条清投影（`listPlansCarryingHandles` → 删日程/撤旧行提醒句柄）→ `purgeManagedCalendar()` 兜底清「同休日」那一本 → **再**清 8 张 RDB 表与全部设置（隐私同意标记刻意保留；D-20 起没有"取消周摘要提醒"这一步，那条注册链路已删）；确认弹窗与结果 toast 都按实际剩余播报，**且清库之后不再承诺可重试**（R2：句柄随计划行一起没了） | 口径**有**（`clearAllMessageOf`：没清掉的一律列出，且离线正反两条钉住"清空不得出现可稍后重试 / 取消改期必须出现"）；动作本身**无**——它删的是用户真机数据，不能放进自动化里跑一次 | 待设备（TC §20.1，含 20.1.3/20.1.4 的"真删了没有""删不动时有没有谎报"） |
| 备份恢复后的降级 | `Db` 首启消费恢复标记 | 三条 UPDATE：日历投影（含 `MANAGED_WRITTEN`/`EXTERNAL_UNMANAGED`/`CLEANUP_PENDING`/`WRITTEN`/`PENDING` 五种取值）→`LOCAL_ONLY` 并清空来源设备的事件 id、提醒句柄→`-1`、云端声明→本地 | **有**（`DbMigrationTest` 12 条 + 插桩 7 条） | 待设备（TC §17.3） |

**阶段 6R.1 已改**：`clearAllData()` 不再是"`DELETE FROM plan` 完事"——现在先清系统侧投影再删表，删不掉的按条数如实报；普通取消/改期也不再吞掉投影删除失败，句柄留着并可重试。修法与判据见独立验收 B0/B2。
**阶段 6R.2 补了半边证据**：`ProfileSettingsService` 不再是"离线 runner 里被 skip 的设备耦合源码"——`tools/test/run.mjs` 给它配了签名对齐的内存 `SettingsStore`/`ScheduleRepo` 替身与**总是成功**的 `AgcPairingClient` 替身（带 `calls` 计数），于是解除配对、取消等待、清空播报这几条动作本身第一次能在离线里跑通并被断言。
**这条门禁为什么还不算通过**：G5 要的是"可验证"，而以上每一条最终都要在设备上看见**系统日历里真的少了一条**（D-20 起提醒侧本来就不该有本应用的东西，那一半判据并入 TC §12 的"通知栏与系统提醒里都是空的"）。本轮零设备证据（B6），所以判定停在 **待设备**；替身能证的只有"本机这四个标记清没清"，证不了日历的真实现象。
**还缺的一条**：`deletePartner` 仍然连口径断言都没有（表里"无"）——它删的是 `owner='PARTNER'` 的四张表行，替身已具备条件，但属阶段 3 门禁解除后的补测范围，本轮不扩大。

## 3. 发布矩阵（改造文档 Task 6.4 指定的 9 维）

| 维度 | 本轮可判 | 待设备 / 阻断 | 指路 |
|---|---|---|---|
| 全新安装 / 升级安装 | 全新安装：`bm clean` 后首启链路（待设备）。**升级维度对首版是空集**——本应用从未上架，没有可升级的线上包；这一维现在只有离线夹具 12 条（`DbMigrationTest`）+ 插桩 7 条（编译通过、未执行）撑着。**v3 迁移（D-37：班表三表主键改 `(owner,id)`）的内部升级说明照这两句写，不要换词**：① 它**阻止的是此后的互相覆写**——迁移只把三张 owner 作用域表重建成复合主键，两侧同 id 的行从此各归各的；② 它**不能恢复此前已被覆盖的班表**——重建时 `INSERT … SELECT` 原样搬 `owner` 列、不猜哪一行本来属于谁，被改写掉的那一份在覆盖当时就已经不在库里。**不得写成"修复班表丢失"或"找回班表"**，那是把止损说成找回（判据与设备取证见差异文档 §4 的 D-37「边界」） | 老包→新包的真实覆盖安装留给第二个版本 | TC §1、§17.1/§17.2 |
| 单人 / 本机代录 / 云配对 | 单人、本机代录：离线用例 + 静态文案核对。云配对：**保持关闭**，且关闭态**不摆云入口**（阶段 6R.2 起连 `INTERNET` 权限都没有） | 两形态的渲染与重算走查 | TC §2–§4、§9 |
| 在线 / 离线 / 云停服 | **离线与在线同一份代码路径**（本机链路无网络调用，且首发包不带 `INTERNET`）；"云停服"这个概念对当前构建不成立——云客户端永不被调用，所以既没有降级 toast 也没有等待态 | 飞行模式下全量回归一次（证明没有隐藏依赖） | §2 G2/G3、TC §9.3 |
| 通知允许 / 拒绝（D-20 起这一维退化成"始终为空"） | **静态事实**：没有通知授权入口、没有后台代理提醒权限、设备侧两个门面已删（2026-09-24）。原先这一维要判的"三档默认值 + 授权弹窗 + 去重 + 锁屏隐私 + 到点真响"整批作废 | 只剩一条：`bm clean` 后跑完整链路，通知栏始终 0 条、全程不弹授权窗（TC §12.1） | TC §12 |
| 日历允许 / 取消 | 默认是**应用专属「同休日」日历的受管写入**（`addEvent`，不弹系统确认页）；拒绝授权 → `LOCAL_ONLY` + 「写入日历」/「导出到系统日历」两个出口；删不动 → `CLEANUP_PENDING` + 「重新清理」：这三处口径都有离线断言 | 权限弹窗、专属日历那一本真出现/真消失、`createCalendar` 是否真的建得出「同休日」、导出确认页、`CLEANUP_PENDING` 重新授权后真清得掉、回前台补扫真的跑 | TC §6、§18.2.2/§18.2.3 |
| 扫码支持 / 不支持 | `scanPairing=false` + `canIUse(Scan)` 双前置 → 当前构建**不出现扫码按钮**（静态判定） | 两种设备各确认一次；真扫码闭环等门禁解除 | TC §10 |
| 360vp / 横屏 / 大字体 / Senior Mode / 深色 | 令牌与断点口径为静态事实（`fp` 字号、`hit_min 44vp`、断点按容器宽度）；**横屏已按定稿锁住**（阶段 6R.4：`module.json5` 的 EntryAbility 声明 `orientation: 'portrait'`），因此"手机上横屏落进 medium/expanded 端出平板双栏"这个缺口在当前构建里不会发生——代价是平板与折叠屏展开态也保持竖屏，属已知取舍 | 真机确认横握不转（TC §20.6）。**通过不等于横屏已适配**：横屏矩阵（平板/折叠屏 + 手机横握逐屏可读）仍要单独跑通才允许删掉那行声明（TC §20.6b）。五种形态逐屏截图仍全部待设备 | TC §8、§13、§14、§15、§20.6 |
| 卡片添加 / 更新 / 移除 | 只有 2×2、六态投影、路由白名单、只从桌面添加：静态事实 + 离线用例 | 卡面渲染、跨进程刷新、伪造参数、移除重加 | TC §11 |
| 配对解除 / 清本机数据 / 备份恢复 | 恢复降级有离线断言（含新状态与 `CLEANUP_PENDING` 句柄作废）；解除与清空见 G5 | 备份→恢复往返、清空后「同休日」日历是否真没残留 | TC §17、§2 G5、§20.1 |

## 4. 灰度与回退（引用，不重复）

档位表、每档的启用条件/关闭影响/数据兼容性、以及"关档不关数据"规则见
[rollout-and-rollback](./rollout-and-rollback.md)；设备侧关档走查清单是 TC §18.2。
本项目**没有按用户分流的能力**（开关是编译期常量，一档一包），也**没有远端遥测**——放量判断只能建立在"关闭影响是否可逆 + 数据是否兼容"上。

## 5. 提审材料清单（阶段 6R.4 已把仓库侧做齐，账号侧仍全部待办）

- [x] 《隐私政策》全文成文（`docs/legal/privacy-policy.md`，G4-1；如实写了不接华为账号、当前无云端同步、**本包不带联网权限**、数据删除方式=清空本机数据/卸载、**以及系统备份与换机迁移会把数据带到其他设备**（最终验收 R1 新增一节，`allowToBackupRestore` 保持为真））+ 一份可直接上传的自包含静态页（`docs/legal/privacy-policy.html`，深浅色自适应、无外部资源）+ App 内随包全文（`PrivacyPolicySheet`，无 `INTERNET` 也能读）。三处全文与五条首启摘要的逐字同源由 `node tools/test/run.mjs` 的 `copy` 审计把关，不再依赖"记得两边一起改"
- [ ] 托管为可访问 URL 并回填 `AppConst.PRIVACY_POLICY_URL`（**账号侧动作**：上传 HTML → 拿地址 → 填常量 → 与商店页地址一致）。URL 为空不阻断 App 内阅读，页底会显示"在线版地址尚未填写"。**不要为了让链接可点而加回联网权限**（`rollout-and-rollback.md` §3.3）
- [ ] 权限用途说明与 G4 表逐条对齐（现在只有 2 条：`READ_CALENDAR`/`WRITE_CALENDAR` 的 reason 与 `privacy_point_calendar` 已跟上阶段 6R.1 的"专属日历受管写入 + 导出"三态。后台代理提醒权限已于 2026-09-24 D-20 从 `module.json5` 删除，提审材料里**不要再出现"提醒"类权限**；《隐私政策》权限段也已改成"这个版本零通知：不申请通知授权、不注册任何系统提醒"）
- [ ] 应用截图（首页/共同时间/我的/班表/卡片）+ 一句话介绍 + 分类（生活或效率）+ Age rating + 版权/开发者信息 → **0 张截图，全部待设备**（B6），登记表见 `submission-materials.md` §5/§6
- [ ] App 备案：**仓库内至今没有任何状态记录**（docs/04 M0 第 5 项只登记为"本周发起"，从未回填）→ 待设备之外的独立卡点，登记表见 `submission-materials.md` §3
- [ ] 签名配置（自动签名或正式证书）后重跑一次 release 出包，确认产物不再是 `-unsigned`：当前 `signingConfigs: []` 且 `products[0].signingConfig: "default"`，产物 `entry/build/default/outputs/default/entry-default-unsigned.hap`。规则：密钥库口令与私钥**不进仓库**（`submission-materials.md` §2）
- [ ] 包身份定稿：`bundleName` **2026-09-25 已更新为 `com.common.fortwo`**（旧值 `com.rest.common`；影响面见 `submission-materials.md` §1）；`vendor` 现在仍是模板值 `example`，待确认。签名 Profile、AGC 应用与备案材料都按 `com.common.fortwo` 走，已安装旧包的数据迁移需单独决定
- [ ] AGC：创建云资源与否的决定与 `docs/cloud/operations-runbook.md` §1 前置清单一并记录（保持关闭就明确写"首版不开通"）

## 6. 完成定义对照（改造文档末尾 8 条）

| 条件 | 状态 |
|---|---|
| 三个主入口与精简原型一致，旧四 Tab 不再存在 | 达成（Task 6.3 复验：无四 Tab 残留，`main_pages.json` 6 个入口全在用） |
| 首页、窗口详情、计划、日历和卡片形成一条真实数据链路 | 代码与离线达成（阶段 6R.1 后这条链路是"窗口 → 本机计划 → 应用专属日历受管投影 → 卡片"，取消/改期/清空都跟着投影走）；**真机端到端待设备** |
| 本地数据在无网、无云、无权限时仍可使用 | 达成且**结构性达成**（阶段 6R.2 后本机链路既无网络调用、包内也没有 `INTERNET` 权限；权限拒绝有降级分支，弹窗侧待设备） |
| 配对数据端侧加密，长期密钥由 HUKS 托管 | **未达成**——Task 0.4 判 `CLOUD_BLOCKED`，HUKS 链路未验证；现状是"云端整体关闭"。按红线**不允许**用短码派生密钥充当——那个反例（`deriveKeyHex` + `savePairKey`）已在阶段 6R.2 从源码删除，所以门禁解除前必须先补 HUKS，而不是把开关翻回来 |
| 云工程位置和运维方式有实测结论 | 部分：`docs/05` + `operations-runbook` 是文档级结论，"实测"两字仍缺（无 AGC 账号操作记录） |
| 360vp、深色、大字体、读屏和 Senior Mode 达标 | 代码口径达成，**达标与否待设备**（§3 第 7 行）；横屏一维已按定稿锁竖屏，因此"手机横屏端出平板双栏"在首发包里不会发生，但横屏矩阵本身仍未验证（TC §20.6/§20.6b） |
| 所有阶段构建、自动化测试与手工验收记录齐全 | 构建/自动化齐全（§1）；手工验收记录=空，全部待设备 |
| 文档不再保留与实现相冲突的旧技术结论 | 达成（Task 6.3；本轮再更正 TC §9.3 的 BuildProfile 表述与 `docs/05` 一处路径） |

**净结论**：8 条里 3 条达成（三主入口 / 本机数据自足 / 文档与实现不再冲突）、1 条按门禁承诺未达成（HUKS 托管长期密钥）、4 条卡在"证据只到代码与离线这一层"（真机端到端、云侧实测、五种显示形态、手工验收记录）。
提审前还欠的账（阶段 6R.4 之后）：D1 计划类型精简、D2 锁竖屏、G4 三处文案（隐私政策成文 + 日历那句 + 共享等级那句）**已全部在代码与文档里落地**；`INTERNET` 随 6R.2 移除。剩下的是**这个仓库替你做不完的两类**——
① 账号侧：隐私政策 URL 托管并回填 `AppConst.PRIVACY_POLICY_URL`、`vendor` 定稿（`bundleName` 已更新为 `com.common.fortwo`）、备案状态、配置签名后重出 release 包、商店截图与分类/Age rating（逐项见 `submission-materials.md`）；
② 设备侧 B6：接 API 26 真机按 TC §1–§20 全量勾一遍。G1 与 G5 的判定都卡在②上：代码与离线口径已经改完（含 G2 的云守卫、D-20 的零通知）；缺的是"系统日历里真的少了那条"这类只有设备能给的证据，而通知侧要的的证据正好相反——**通知栏与系统提醒里始终没有本应用那一条**（TC §12.1）。
