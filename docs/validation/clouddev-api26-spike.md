# CloudDev 与 HUKS 技术门禁结论（阶段 0 / Task 0.4）

> 复核日期：2026-09-22，2026-09-23 就 HUKS 参数表逐条重读并做了一次静态更正（§0 第 1 条、§1 六行、§2 实验 5、§3.1/§3.2），
> **2026-09-27 按设备实测改写 §0 结论并同步 §2/§4 状态**（批次 U·U3b 开闸同日）　工程版本：schema v2、`targetSdk/compileSdk/compatibleSdk = 26.0.0`
> 本文件是阶段 3 的唯一开门依据。结论变化时必须改写本文件的「结论」小节，不允许在别处另立口径。

## 0. 结论（三选一，2026-09-27 起取第二项）

**`SEPARATE_CLOUD_REPO`** —— 阶段 3（云端配对与加密快照）**已启动、并已于 2026-09-27 批次 U·U3b 开闸**
（`FeatureFlags.cloudPairing = true` ＋ `ohos.permission.INTERNET` ＋ 隐私政策 v1.1 同批出入包，
三条同批条件与整批回退口径见 `docs/release/rollout-and-rollback.md` §3.3/§5）。云侧实现落在仓库外的向导工程、
本仓库只放纯镜像 `cloud-backend/`（不参与任何 App 侧构建），这就是"三选一"里的第二项。

**历史结论 `CLOUD_BLOCKED`（2026-09-22/23）不删，按本页"改写而非另立"的规矩说明它为什么不再成立**：
它当时的唯一依据是"六项实验一项都没跑过、`hdc list targets` 为空"，而 §0 第 2 条自己就把解除成本写成了
"装一台 API 26 模拟器"。那台设备与第二台设备现在都在（`127.0.0.1:5555` / `127.0.0.1:5557`），
#5 的判定问题已有实测答复（§2 第 5 行），所以门禁从"未知"变成"已核"。
**这不等于"云配对已验收"**：能力面的十条设备证据（`docs/cloud/pairing-protocol-v1.md` §11）一条都还没勾，
提审仍被 B5/B6 挡着（`docs/release/2026-api26-release-checklist.md`）。

当时成立、今天仍然成立的两条事实性结论：

1. `[事实]` **API 26 的能力面不缺，而且比上一版登记的更贴合设计**：Cloud Foundation Kit、HUKS 的 ArkTS 类型表在本机 SDK 齐全（§1）。上一版说"没有'不可导出'标签、密钥建立可能要改走 wrap/KEM"是**读漏了一条枚举**——`HUKS_STORAGE_ONLY_USED_IN_HUKS`（`@since 10`）配合 `HUKS_TAG_DERIVED_AGREED_KEY_STORAGE_FLAG`（注释原文覆盖 derived **or agreed** key）就是"长期密钥只待在 HUKS 内、由 HUKS 管理"的一等公民表达，设计里那条主张不需要绕道。真正的两处摩擦改记为：`[事实]` ①独立的 HKDF 派生依赖三个 `@deprecated since 9` 的标签（`DERIVE_MAIN_KEY/FACTOR/ALG`），所以密钥建立应以"协商 + 存储标记"为主路、HKDF 当可选加固；②**[更正 2026-09-27]** 当时记的"`HUKS_TAG_AAD` 是 `@since 24`，所以 AAD 绑定是版本门槛"是**读错了一条枚举的用途**：`HUKS_TAG_AAD(527)` 确实 `@since 24`，但它不是 AES-GCM 的 AAD 入口——GCM 用的是 `HUKS_TAG_NONCE` 与 `HUKS_TAG_ASSOCIATED_DATA`，**两个都 `@since 8`**（本机 SDK `@ohos.security.huks.d.ts` 实测；用 `IV`/`AAD` 会加密"成功"而解密 `initSession` 报 `401`，见 `docs/cloud/pairing-protocol-v1.md` §6 与 `cloud/src/main/ets/api/PairKeyStore.ets:16`）。**所以"AAD 绑定 pairId/ownerUid"根本没有版本门槛**，那条"下调 compatibleSdkVersion 第一个要砍 AAD"的推论一并作废。新登记一条同源事实：GCM 解密必需的 `HUKS_TAG_AE_TAG` **`@deprecated since 9`**，而官方 AES/GCM 示例自己就在用它——"用了一个废弃标签"在这里是官方路线，不是我们的选型错误。
2. `[事实]` **阻塞点是没有可跑环境，而不是账号或资格**。2026-09-23 再测仍为空：`toolchains/hdc.exe list targets` → `[Empty]`；`%LOCALAPPDATA%/Huawei/Emulator/deployed/` 下只有 `privacy.json` 与 `versionInfo.txt`，**连一个模拟器实例都没建过**。`[事实]` 但六项实验对 AGC 的依赖并不相同（拆分见 §3.1）：**决定阶段 3 生死的 #5（HUKS）与 #3（工程落点）都不需要 AGC、不需要网络、不需要 `INTERNET` 权限**，只缺一台设备/一次向导；真正必须账号持有者本人的只有 #2 的签名关联与 debugToken 注册。`[推断]` 所以本项阻塞的解除成本是"装一台 API 26 模拟器"，不是"跑通端云一体化"。

**（历史）2026-09-22 取 `CLOUD_BLOCKED` 而非"结论待定"的理由**：计划要求门禁必须落到一个确定值；在证据缺失时假定"可以做"会诱导阶段 3 提前动工，而假定"不可以做"只损失一个可后移的功能（配对入口在 UI 上保持已有的降级提示），代价不对称。

## 1. 本次已完成的静态核验（本机 SDK，可复查）

所有路径相对 `D:/local/DevEcoStudio/sdk/default/`。

| 核验点 | 结果 | 出处 |
|--------|------|------|
| Cloud Foundation Kit 是否随 API 26 提供 | `[事实]` 提供：`cloudCommon / cloudFunction / cloudStorage / cloudDatabase / cloudResPrefetch`，`@since 5.0.0(12)`，`@stagemodelonly`，syscap `DeviceCloudGateway.CloudFoundation` | `hms/ets/kits/@kit.CloudFoundationKit.d.ts` |
| 端侧调用超时口径 | `[事实]` `FunctionParams.timeout` 默认 **70×1000ms**，"value range is unrestricted" → 55s 上限只存在于云函数同步调用侧，**客户端必须显式传 ≤55000**（本计划统一 30000） | `hms/ets/api/@hms.core.deviceCloudGateway.cloudFunction.d.ts:98-111` |
| 本地联调入口 | `[事实]` `localUrl`（`http://localhost:18090` 形态）存在，与 docs/05 §5.6 一致 | 同上文件 :120+ |
| HUKS 密钥用途 | `[事实]` `HUKS_KEY_PURPOSE_DERIVE = 16`、`HUKS_KEY_PURPOSE_AGREE = 256`、`WRAP/UNWRAP` 均在 | `openharmony/ets/api/@ohos.security.huks.d.ts:2914-2962` |
| HUKS 算法常量 | `[事实]` `HUKS_ALG_ECDH = 100`、`HUKS_ALG_HKDF = 51`、`HUKS_ALG_ECC = 2`、`HUKS_ALG_AES = 20`、`HUKS_ALG_X25519 = 101`，另有 `HUKS_ALG_ML_KEM = 200` / `ML_DSA = 201`（PQC） | 同上 :3504-3702 |
| HUKS 协商/派生参数 | `[事实]` `HUKS_TAG_AGREE_ALG(19) / AGREE_PUBLIC_KEY_IS_KEY_ALIAS(20) / AGREE_PRIVATE_KEY_ALIAS(21) / AGREE_PUBLIC_KEY(22) / DERIVE_MAIN_KEY(16) / DERIVE_FACTOR(17) / DERIVE_ALG(18) / DERIVE_KEY_SIZE(24) / DERIVED_AGREED_KEY_STORAGE_FLAG(29)` 齐备（括号内为标签序号） | 同上 :4528-4637 |
| **HUKS 没有独立的 agree()/deriveKey() 函数** | `[事实]` 模块导出函数只有 generate/import/export/wrap/unwrap/`encapsulate`/`decapsulate`/会话族（`initSession`/`updateSession`/`finishSession`/`abortSession`）→ ECDH 协商与 HKDF 派生**只能走会话式流程**，其可用性、参数组合与错误码必须在真机上验证。函数全集共 31 个函数名 / 57 条重载声明（callback 与 Promise 各占一条）（`generateKey/KeyItem`、`deleteKey/KeyItem`、`importKey/KeyItem`、`importWrappedKeyItem`、`exportKey/KeyItem`、`getKeyProperties/KeyItemProperties`、`isKeyExist/KeyItemExist/hasKeyItem`、`init`、`initSession`、`update`、`updateSession`、`finish`、`finishSession`、`abort`、`abortSession`、`attestKeyItem`、`anonAttestKeyItem(Offline)`、`getSdkVersion`、`listAliases`、`wrapKeyItem`、`unwrapKeyItem`、`encapsulate`、`decapsulate`） | 同上 :46-1636 |
| ~~"不可导出"在本 SDK 没有对应标签~~ → **有，是 `HUKS_STORAGE_ONLY_USED_IN_HUKS`** | `[事实]` 全文确实 0 命中 `NON_EXPORTABLE` 这个**名字**，但上一版据此推出"只能靠 wrap/unwrap 或 KEM 间接表达"是**读漏了**：`HuksKeyStorageType` 里 `HUKS_STORAGE_ONLY_USED_IN_HUKS = 2`（`@since 10`）的原文就是"密钥存放在 HUKS 内、由 HUKS 管理"，而 `HUKS_TAG_DERIVED_AGREED_KEY_STORAGE_FLAG`（`@since 10`）的注释原文是 "Storage type of the derived key **or agreed key**"——即**协商密钥同样归它管**。两条合起来 = 阶段 3 需要的"长期密钥不出安全环境"在 ArkTS 上有**一等公民表达**，不需要 NDK、也不需要退回 wrap/KEM 方案 | 同上 `:3856-3865`、`:4628-4637` |
| `HUKS_STORAGE_TEMP / PERSISTENT` 是**废弃**取值（上一版登记反了） | `[事实]` 两者均 `@deprecated since 10`，`PERSISTENT` 的注释直接写明"密钥管理里不用它，派生场景改用 `ONLY_USED_IN_HUKS` 或 `KEY_EXPORT_ALLOWED`"。→ 生成 ECC 密钥对时**不该带** `KEY_STORAGE_FLAG`（`generateKeyItem` 的别名本身就是持久的） | 同上 `:3838-3855` |
| **HKDF 派生这条路建立在废弃标签上** | `[事实]` `HUKS_TAG_DERIVE_MAIN_KEY(16)`、`DERIVE_FACTOR(17)`、`DERIVE_ALG(18)` 三个**全是 `@deprecated since 9`**，且参数表里没有未废弃的替代（`HUKS_TAG_KEY(10006)` 的注释只有 "Reserved"）。hvigor 编译时会逐条报 deprecated。`[推断]` 所以阶段 3 的密钥建立**优先做"协商 + `DERIVED_AGREED_KEY_STORAGE_FLAG`"这一条**，把独立 HKDF 当可选加固；两者都要在实验 #5 里实测 | 同上 `:4519-4548`、`:5176-5184` |
| ~~AAD 支持是版本门槛，不是形态差异~~ **[更正 2026-09-27：这一行整行作废]** | `[事实]` GCM 的 AAD 入口是 `HUKS_TAG_ASSOCIATED_DATA`（**`@since 8`**），配 `HUKS_TAG_NONCE`（同 `@since 8`）；`HUKS_TAG_AAD(527) @since 24` 是另一条路，拿它当 GCM 参数会**加密成功、解密 `initSession` 报 `401: The parameter does not exist`**（一次性工程实测，已回写协议 §6）。所以"AAD 绑定 pairId/ownerUid"**没有版本门槛**，下调 `compatibleSdkVersion` 时不必砍它。新登记的真实门槛只有一个：`HUKS_TAG_AE_TAG` 虽 `@deprecated since 9` 却是 GCM 解密的必需参数（官方示例同此），它废弃的是标签名而不是能力 | 同上 `:4993-5001`、`:5205-5213` |
| ECC 曲线如何指定（上一版的问号） | `[事实]` **没有独立曲线标签**，曲线由 `HUKS_TAG_KEY_SIZE` 隐含：`HuksKeySize` 提供 `HUKS_ECC_KEY_SIZE_224/256/384/521`。实验 #5 待测项 1 的这条问号可以划掉 | 同上 `:3294-3324` |
| API 26 新增面 | `[事实]` `HuksReturnResult.sharedSecret?: Uint8Array` **`@since 26.0.0`**；`encapsulate(keyAlias, params, sharedKeyAlias?, sharedKeyParams?)` 与 `decapsulate(...)` 支持把 KEM 共享密钥**直接收进另一个别名**；另有 `HUKS_ALG_ML_KEM = 200`、`HUKS_ALG_ML_DSA = 201`、`HUKS_TAG_KEY_SECURITY_LEVEL(526) @since 26.0.0`。`[推断]` KEM 这条路是否真不外交裸密钥，同样归实验 #5 的 KEM 探针判 | 同上 `:1601,1636`、`:1863-1871`、`:4988-5009` |
| NDK 兜底 | `[事实]` `native_huks_type.h` 同样有 `OH_HUKS_KEY_PURPOSE_DERIVE = 16` / `AGREE = 256`，头文件目录 `native/sysroot/usr/include/huks/` → ArkTS 表面不足时可走 NDK，代价是工程要引入 native 模块 | `openharmony/native/sysroot/usr/include/huks/native_huks_type.h:206,222` |
| 云数据库端侧直连 | `[事实]` 端侧可直连读写，因此"禁止端侧直连"只能靠**安全规则默认拒绝**实现（docs/05 §5.5），不是 API 缺失问题 | docs/05 §5.5 |
| 根目录能否容纳 `CloudProgram/` | `[缺证据]` 本工程根目录为扁平多 HAR（`entry / feature / domain / data / cloud / commons` + `AppScope` + `hvigorfile.ts`）。docs/05 §5.2 记的"根目录只允许 `Application` + `CloudProgram`"来自新建向导文档，`[推断]` 现结构需整体下移到 `Application/` 才能被识别为端云一体化工程；**能否手工加目录不改结构 = 实验 #3，未跑** | 本仓库 `build-profile.json5`、docs/05 §5.2 |

## 2. 六项实验逐项状态（2026-09-27 全部改写：五项已跑，一项半）

> 状态值现在都有了，逐条给出"证据在哪"。工程落点：仓库外三个一次性工程 `CloudDevSpike`（私有云侧实现路线）、
> `CloudDevSpikeOfficial`（官方 `@hw-agconnect` 路线）、`CloudDevSpikePrivate`（对照），
> 正式镜像在本仓库 `cloud-backend/`。**两台设备都是 API 26 模拟器**，"真机"这一半仍然缺，别把模拟器证据写成真机证据。

| # | 实验 | 状态 | 阻塞原因 / 已得结论 |
|---|------|------|--------------------|
| 1 | `[CloudDev] Empty Ability` 一次性工程，记录 `Application + CloudProgram` 结构 | `DONE`（2026-09-26） | 向导跑通三次，结构记录在三个 spike 工程与 `cloud-backend/README.md` §2。连带结论：`CloudProgram/` 不能塞进多 HAR 扁平根目录（会污染 App 侧构建）→ 见 #3 |
| 2 | 同 bundle name 关联、自动签名、模拟器 debugToken、真机调用 | `DONE_ON_EMULATOR` | 关联与自动签名已通；两台模拟器的 `clouddevelopproxy.debugToken` 已注册，端云调用全绿（24 步全生命周期探针 `not_clean=0`，`docs/cloud/operations-runbook.md` §2.4 第 14 行）。**注意两条不可逆的坑**：①云工程的"关联云工程"一旦定了就改不动（用户 2026-09-27 实拍）；②runtime/超时只能在 AGC 控制台改，且**重新部署会按向导默认值把超时推回 60s**。**"真机调用"这一半仍未做**（无真机） |
| 3 | 现有多 HAR 工程能否不重排根目录加入 `CloudProgram` | `DONE` → 答案是否 | `SEPARATE_CLOUD_REPO`（§0）。硬塞会污染 App 侧构建；云侧实现落在 `cloud-backend/` 纯镜像，部署时复制进仓库外的向导工程 |
| 4 | Node.js 20 echo 函数 + 端侧 `timeout = 30000` | `PARTIAL` | 端侧 `timeout: 30000` 已显式传入（协议 §3.3/#4）；控制台两个云对象的 runtime 已改 Node.js 20、超时改 20s（2026-09-27 由账号持有者本人改，处于最后一次部署之后）。**但"真实 30s 截断报哪个码"一次也没观察到**——网络类失败归 `1008210001 → NETWORK`、AGC 未就绪归 `201/1008210009 → LOCAL`，截断本身仍是猜，余项收敛到协议 §11 第 6 条 |
| 5 | HUKS 非导出 ECDH/HKDF/AES-GCM 组合，记录算法参数、别名生命周期、错误码 | `DONE_ON_EMULATOR`（2026-09-27，10 条 Hypium 用例） | 那一问有了答复：**`ONLY_USED_IN_HUKS` 不把裸共享秘密交回应用**——`updateSession`/`finishSession` 交回的 `outData` 全零、`sharedSecret` 为空，而 A→B、B→A 的 AES-256-GCM 往返（随机 12 字节 NONCE）都能解回原文，AAD 里换 `ownerUid` 被拒。所以托管主张成立，不需要改走 wrap/unwrap 或 NDK，HKDF 那条废弃标签路也不必碰。证据：`CloudDevSpike/OFFICIAL_SMOKE_STATUS.md` §"HUKS 托管"（AES-256 别名存在性 = `HUKS_STORAGE_ONLY_USED_IN_HUKS`）。**它没证的**：真机的 `HUKS_TAG_KEY_SECURITY_LEVEL` 实际档位、别名在卸载重装/清数据/备份恢复后的存留 → 协议 §11 第 5 条 |
| 6 | 云数据库由云函数访问、端侧规则禁止直连 | `DONE` → 前提被推翻 | AGC 云数据库**根本没有**"端侧直连安全规则"这一层（原稿设想的 `2001015:permission denied` 路径不存在，协议 §10 第 4 项）。封口方式换成两条：集合的 `permissions` 四角色全空 + 一切读写都穿云对象，成员关系折进 `PairSession` 两列。实测：越权访问（第三次设备拿旧码/旧 `pairId`）全部 `FORBIDDEN`、级联删除逐条对上（探针 §2.4 第 14 行）。**余项**：真正的"第三台设备"越权复验仍要按协议 §11 第 10 条做一次 |

## 3. 翻闸最小路径（一次真机 30 分钟）

步骤与逐项目测记录写在 `experiments/clouddev-spike/README.md`（一次性实验目录，不进构建）。顺序刻意把"会一票否决"的放在前面：

1. **实验 #3 先跑**（决定工程落点，成本最低、影响最大）：新建 `[CloudDev]Empty Ability` 实验工程 → 只观察它生成的根结构，再判断本工程加 `CloudProgram/` 是否需要重排。
2. 实验 #1/#2/#4：同一实验工程里部署 echo 函数，端侧 `cloudFunction.call({ name, timeout: 30000 })` 打一次通（模拟器需先取 `clouddevelopproxy.debugToken` 注册到 AGC，docs/05 §5.6）。
3. 实验 #5：HUKS spike（本工程 `entry` 里加一个临时调试页，或实验工程里加），跑 ECDH 会话 + HKDF 派生 + AES-GCM 加解密闭环，记录参数集与错误码。
4. 实验 #6：云数据库 + 安全规则。

四项 PASS → 把本文件结论改写为 `IN_REPO_CLOUDPROGRAM` 或 `SEPARATE_CLOUD_REPO`（由 #3 决定），并在 §0 记录日期与设备/SDK 版本；任一 FAIL → 维持 `CLOUD_BLOCKED` 并把 FAIL 项写进 §2。

### 3.1 六项实验可按"要不要 AGC"拆成两段

`[推断]` 依 §2 各项自己登记的依赖推导（非官方条款），六项不必攒齐一次跑：

| 段 | 实验 | 需要什么 | 不需要什么 |
|----|------|----------|------------|
| A（本地即可，决定阶段 3 生死） | **#5 HUKS** | 任意一台真机或一台模拟器；探针已编译通过，接线三步见 `experiments/clouddev-spike/README.md` §5.1 | 不需要 AGC 项目、不需要云函数、不需要网络、不需要 `INTERNET` |
| A | **#3 / #1 工程结构** | DevEco 已登录 + `[CloudDev]Empty Ability` 向导跑完一次，只看目录树 | 不需要 AGC 里真的开通云开发，也不需要任何设备 |
| B（账号侧） | #2 签名与 debugToken、#4 echo 调用、#6 云数据库规则 | AGC 项目、云开发开通、真机或模拟器 + debugToken 注册 | —— |

`[判断]` 排期上应先清 A 段：它把"阶段 3 会不会因 HUKS 而永久关闭"这个不可逆的问题先判掉，成本是一台模拟器；B 段的三项都是可后移的功能验证。

### 3.2 门禁之外的合规连带项（docs/05 未覆盖）

`[事实]` docs/05 §4 否掉的是**域名备案**前置（`cloudFunction.call` 走华为网关下发的触发 URL，客户端不拼域名）。这不等于免备案：纯单机/离线 App 在 APP 备案流程里可走「单机 APP」免备案路径，而**一旦 `module.json5` 声明 `ohos.permission.INTERNET` 并提供云同步，就必须走完整 APP 备案**（备案主体须与开发者主体一致，周期以周计）。

`[推断]` 因此云配对不是"翻一个 `FeatureFlags` 开关"的体量，它会把上架排期的主导不确定性从开发量换成备案周期。与 §6 的账号前置一并排在提审窗口之前，且**首发包保持无 `INTERNET`**（现有 `docs/release/rollout-and-rollback.md` 的三条同批条件仍然正确）。

## 4. 门禁规则（2026-09-27 逐条复核：五条全部成立，第 1 条由设备实测满足）

> 这一节原来是"启动前必须全部满足"的前置清单。阶段 3 已经启动并开闸，所以它换成了**逐条现状**——
> 五条里没有一条是被绕过去的，第 1 条是刚补上的，第 3/5 条仍要在提审前拿现场证据。

1. HUKS 安全链路（实验 #5）未验证通过 → **不启动阶段 3**。`[已满足 2026-09-27]` 两台 API 26 模拟器 10 条用例：
   `HUKS_STORAGE_ONLY_USED_IN_HUKS` 下协商密钥不出 HUKS（`outData` 全零、`sharedSecret` 空）、A↔B GCM 往返成立、
   换 owner 的 AAD 被拒。**未满足的一半**：真机硬件安全等级、别名在卸载/清数据/备份恢复后的语义（协议 §11 第 5 条）；
2. **不允许退回"邀请码/短码直接派生长期密钥"**；
3. 长期密钥不得写入 Preferences、源码、二维码或日志；
4. 云端任何失败不得阻断本机计算与本机代录；
5. `pairId` / `ownerUid` 明文落云（安全规则与查询所需），班表载荷加密——云端明文里不得出现日程名、课程名、地点、备注、计划标题、长期密钥与邀请历史。

## 5. 当前代码与目标设计的差距（只登记，不改）

| 位置 | 现状 | 门禁通过后的动作 |
|------|------|------------------|
| `cloud/src/main/ets/api/SnapshotCrypto.ets` | `encryptWithKey(keyHex, …)`：AES-256-GCM，**密钥 hex 由调用方给出**；`EncryptedPayload` 只有 `ciphertext/iv`（authTag 拼进密文 hex，无 `algorithm` 字段），AAD 为固定常量 `'crd-v1'` | Task 3.2 换成 HUKS 别名托管的协商密钥，AAD 改为 `pairId\|ownerUid\|version\|schemaVersion`，`EncryptedPayload` 补齐 `authTag/algorithm` |
| `data/.../SettingsStore.ets` `getPairKey`（`savePairKey` 已删除） | `[更正 2026-09-23]` 上一行登记"写入口已在 HEAD"已过期：阶段 6R.2 把 `savePairKey` 与 `SnapshotCrypto.deriveKeyHex` 一并删除，本机**没有任何写密钥的路径**，§4 第 2、3 条的违规实现在结构上已不成立。余下的是**读口子**：`getPairKey` 仍返回密钥 hex 字符串，`ScheduleUseCase.ets:212`（push）与 `:256`（pull）各读一次 | 把 `getPairKey()` 换成 `getPairKeyAlias()`，密钥材料改由 HUKS 别名承载（别名可存 Preferences）；解除配对时 `deleteKey` 删别名 |
| `cloud/.../CloudApi.ets:118` `cloudFunction.call({name, version, data})` | **未传 `timeout`** → 走 SDK 默认 70s，超过云函数同步调用 55s 上限（§1）。行号自上一版登记后从 111 移到 118 | Task 3.1 统一显式 `timeout: 30000` + `requestId` 幂等；错误码补 401/403 |
| `FeatureFlags.cloudPairing` / `scanPairing` | `false` | 保持 `false`，直到本文件结论改写且阶段 3 完成 |
| `MeView` 配对入口 | 已有不可用降级提示 | 保持（与"云端可降级"定位一致） |
| 根目录 | 扁平多 HAR，无 `CloudProgram/` | 由实验 #3 决定：本仓库加目录，或独立云仓库（届时阶段 3 只在本仓库提交协议与运维文档） |

## 6. 账号侧前置（个人开发者本人操作，见 docs/05 §7）

AGC 项目开通云开发、配额截图核对、确认无欠款并开消费/余额提醒、数据处理位置锁"中国"（一经选择不可改）。另有三条硬约束会影响发布节奏：免费档用尽即停（不自动扩容）、连续 6 个月无有效调用判闲置回收、仅中国大陆。

## 7. 证据清单

- 本机：`D:/local/DevEcoStudio/sdk/default/{hms,openharmony}/ets/...`、`native/sysroot/usr/include/huks/`（§1 逐行引用）；`hdc list targets` → `[Empty]`（2026-09-22 与 2026-09-23 各测一次）；`%LOCALAPPDATA%/Huawei/Emulator/deployed/` 只有 `privacy.json`、`versionInfo.txt`，无模拟器实例。
- 静态探针的编译凭据：`experiments/clouddev-spike/HuksCustodySpike.test.ets` 临时接进 `entry/src/ohosTest` 后，`hvigor --mode module -p module=entry@ohosTest -p buildMode=debug assembleHap` → **BUILD SUCCESSFUL**，该文件自身产出 46 条 `ArkTS:WARN`（35 条 syscap "not supported on all devices"、8 条"可能抛异常"、3 条 deprecated 标签）。接线/撤线步骤与不进构建的理由写在 `experiments/clouddev-spike/README.md` §5.1。**这只是"类型表里这些调用签名成立"的凭据，不是"设备上跑得通"的凭据**——#5 后来的实测发生在仓库外的一次性工程（见下一条），本仓库这份探针至今仍刻意不进构建。
- **设备实测凭据（2026-09-27）**：两台 API 26 模拟器（`127.0.0.1:5555` Mate 系列 / `127.0.0.1:5557`，`hdc list targets -v` 均 `TCP Connected`）+ 一次性工程 `com.common.fortwo.cloudspike`。HUKS 侧 10 条定向 Hypium 全绿（`CloudDevSpike/OFFICIAL_SMOKE_STATUS.md` 的「2026-09-27 补充：两台 API 26 模拟器跨端 HUKS 实验」一节：`outData` 全零、`sharedSecret` 为空、A↔B GCM 往返、换 owner 的 AAD 被拒）；云侧 24 步全生命周期探针 `not_clean=0`（`docs/cloud/operations-runbook.md` §2.4 第 14 行）。**边界照抄源文件，不扩写**：不证明真机硬件安全等级、不证明卸载/清数据/备份恢复后的别名语义、不覆盖正式配对与快照落库——那三条分别是协议 §11 第 5 条与第 1/2 条还没勾的原因。
- 仓库内调研：`docs/05-云端配对前置条件调研.md`（§5.2/§5.3/§5.5/§5.6/§7/§8）、`docs/06-API26能力与精简版优化调研.md`（§3.7-B HUKS + 加密 RDB，P1）。
- 备案连带项（§3.2）：`[事实]` 来自华为云《App 备案前准备》——纯单机/离线 App 可勾选「单机 APP」走免备案路径，个人主体用身份证即可。**该条只否掉"需要域名/服务器"，不否掉"需要 APP 备案"**；docs/05 §4 排除的是域名备案，两者不是同一件事。
- 设计口径：`docs/plans/2026-09-21-overall-project-redesign-design.md` 第 189-200 行（HUKS 协商六步、无最终用户身份时不得端侧直连云数据库）。
- 官方文档（docs/05 §9 已附链接与实读日期 2026-09-21）：端云一体化 `cloudfoundation-*`、`huks-key-use-overview`、`huks-key-import-overview`。
