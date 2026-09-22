# CloudDev 与 HUKS 技术门禁结论（阶段 0 / Task 0.4）

> 复核日期：2026-09-22　工程版本：schema v2、`targetSdk/compileSdk/compatibleSdk = 26.0.0`
> 本文件是阶段 3 的唯一开门依据。结论变化时必须改写本文件的「结论」小节，不允许在别处另立口径。

## 0. 结论（三选一，本次取第三项）

**`CLOUD_BLOCKED`** —— 阶段 3（云端配对与加密快照）**暂停**，按本地版推进阶段 1、2、4、5。

同时成立的两条事实性结论：

1. `[事实]` **API 26 的能力面不缺，但形态与设计假设有偏差**：Cloud Foundation Kit、HUKS 的 ArkTS 类型表在本机 SDK 齐全（§1）；不过 HUKS 没有 `deriveKey()`/`agree()` 函数、也没有"不可导出"标签，协商/派生只能走会话流程，`[推断]` 阶段 3 的密钥建立方式要在 spike 后重新定形（更可能落在 `wrapKeyItem`/`unwrapKeyItem` 或 KEM `encapsulate`/`decapsulate` 上）。
2. `[事实]` **阻塞点是没有可跑环境**。写本文件时 `hdc list targets` 返回空（无真机、无运行中的模拟器），而门禁的六项实验全部要求真机/模拟器 + AGC 控制台侧操作，其中 AGC 开通、签名关联、debugToken 注册三项只能由账号持有者本人完成。`[推断]` 因此无法在本次改造中给出 `IN_REPO_CLOUDPROGRAM` 或 `SEPARATE_CLOUD_REPO`。

**取 `CLOUD_BLOCKED` 而非"结论待定"的理由**：计划要求门禁必须落到一个确定值；在证据缺失时假定"可以做"会诱导阶段 3 提前动工，而假定"不可以做"只损失一个可后移的功能（配对入口在 UI 上保持已有的降级提示），代价不对称。

## 1. 本次已完成的静态核验（本机 SDK，可复查）

所有路径相对 `D:/local/DevEcoStudio/sdk/default/`。

| 核验点 | 结果 | 出处 |
|--------|------|------|
| Cloud Foundation Kit 是否随 API 26 提供 | `[事实]` 提供：`cloudCommon / cloudFunction / cloudStorage / cloudDatabase / cloudResPrefetch`，`@since 5.0.0(12)`，`@stagemodelonly`，syscap `DeviceCloudGateway.CloudFoundation` | `hms/ets/kits/@kit.CloudFoundationKit.d.ts` |
| 端侧调用超时口径 | `[事实]` `FunctionParams.timeout` 默认 **70×1000ms**，"value range is unrestricted" → 55s 上限只存在于云函数同步调用侧，**客户端必须显式传 ≤55000**（本计划统一 30000） | `hms/ets/api/@hms.core.deviceCloudGateway.cloudFunction.d.ts:98-111` |
| 本地联调入口 | `[事实]` `localUrl`（`http://localhost:18090` 形态）存在，与 docs/05 §5.6 一致 | 同上文件 :120+ |
| HUKS 密钥用途 | `[事实]` `HUKS_KEY_PURPOSE_DERIVE = 16`、`HUKS_KEY_PURPOSE_AGREE = 256`、`WRAP/UNWRAP` 均在 | `openharmony/ets/api/@ohos.security.huks.d.ts:2914-2962` |
| HUKS 算法常量 | `[事实]` `HUKS_ALG_ECDH = 100`、`HUKS_ALG_HKDF = 51`，另有 `HUKS_ALG_ML_KEM = 200`（PQC） | 同上 :3555-3691 |
| HUKS 协商/派生参数 | `[事实]` `HUKS_TAG_AGREE_ALG / AGREE_PRIVATE_KEY_ALIAS / AGREE_PUBLIC_KEY / DERIVE_MAIN_KEY / DERIVE_FACTOR / DERIVE_ALG / DERIVE_KEY_SIZE / DERIVED_AGREED_KEY_STORAGE_FLAG` 齐备 | 同上 :4528-4637 |
| **HUKS 没有独立的 agree()/deriveKey() 函数** | `[事实]` 模块导出函数只有 generate/import/export/wrap/unwrap/`encapsulate`/`decapsulate`/会话族（`initSession`/`updateSession`/`finishSession`/`abortSession`）→ ECDH 协商与 HKDF 派生**只能走会话式流程**，其可用性、参数组合与错误码必须在真机上验证 | 同上 函数清单（:46-1636） |
| **"不可导出"在本 SDK 的 HUKS 参数表中没有对应标签** | `[事实]` 全文 0 命中 `NON_EXPORTABLE`；可用的是 `HUKS_TAG_KEY_STORAGE_FLAG`（`HUKS_STORAGE_TEMP/PERSISTENT`）、`HUKS_TAG_IS_ALLOWED_WRAP`、`DERIVED_AGREED_KEY_STORAGE_FLAG`，另有 `wrapKeyItem/unwrapKeyItem`（含 `HUKS_UNWRAP_SUITE_ECDH_AES_256_GCM_NOPADDING`、`..._X25519_...`）与 KEM `encapsulate/decapsulate`（含 `HUKS_ALG_ML_KEM = 200`）。`[推断]` 阶段 3 的"密钥不出安全环境"要靠 wrap/unwrap 或 KEM 表达，而不是照搬旧文档的 non-exportable 写法 | 同上（标签枚举、`:3704-3712`、`:3842-3855`、`:5028`） |
| NDK 兜底 | `[事实]` `native_huks_type.h` 同样有 `OH_HUKS_KEY_PURPOSE_DERIVE = 16` / `AGREE = 256`，头文件目录 `native/sysroot/usr/include/huks/` → ArkTS 表面不足时可走 NDK，代价是工程要引入 native 模块 | `openharmony/native/sysroot/usr/include/huks/native_huks_type.h:206,222` |
| 云数据库端侧直连 | `[事实]` 端侧可直连读写，因此"禁止端侧直连"只能靠**安全规则默认拒绝**实现（docs/05 §5.5），不是 API 缺失问题 | docs/05 §5.5 |
| 根目录能否容纳 `CloudProgram/` | `[缺证据]` 本工程根目录为扁平多 HAR（`entry / feature / domain / data / cloud / commons` + `AppScope` + `hvigorfile.ts`）。docs/05 §5.2 记的"根目录只允许 `Application` + `CloudProgram`"来自新建向导文档，`[推断]` 现结构需整体下移到 `Application/` 才能被识别为端云一体化工程；**能否手工加目录不改结构 = 实验 #3，未跑** | 本仓库 `build-profile.json5`、docs/05 §5.2 |

## 2. 六项实验逐项状态

| # | 实验 | 状态 | 阻塞原因 / 已得结论 |
|---|------|------|--------------------|
| 1 | `[CloudDev] Empty Ability` 一次性工程，记录 `Application + CloudProgram` 结构 | `NOT_STARTED` | 需 DevEco 向导 + 华为账号登录 |
| 2 | 同 bundle name 关联、自动签名、模拟器 debugToken、真机调用 | `NOT_STARTED` | 需 AGC 控制台与设备；当前 `hdc list targets` 为空 |
| 3 | 现有多 HAR 工程能否不重排根目录加入 `CloudProgram` | `NOT_STARTED` | 决定 `IN_REPO_CLOUDPROGRAM` 还是 `SEPARATE_CLOUD_REPO`，是本次结论的核心未知项 |
| 4 | Node.js 20 echo 函数 + 端侧 `timeout = 30000` | `NOT_STARTED` | 依赖 #1/#2；`§1` 已确认端侧默认 70s，故这一项是**必须实测**的口径收敛 |
| 5 | HUKS 非导出 ECDH/HKDF/AES-GCM 组合，记录算法参数、别名生命周期、错误码 | `PARTIAL_STATIC` | 常量与参数齐备（§1），但 ArkTS 无 `deriveKey()`/`agree()`、也无"不可导出"标签 → 只能靠会话流程 + wrap/unwrap/KEM 落地；能否跑通、派生密钥是否以裸字节交回应用、别名在卸载与恢复后的生命周期，全部需真机实测（步骤见 `experiments/clouddev-spike/README.md` 实验 5） |
| 6 | 云数据库由云函数访问、端侧规则禁止直连 | `NOT_STARTED` | 需 #1/#2 + 安全规则实测（`2001015:permission denied` 路径） |

## 3. 翻闸最小路径（一次真机 30 分钟）

步骤与逐项目测记录写在 `experiments/clouddev-spike/README.md`（一次性实验目录，不进构建）。顺序刻意把"会一票否决"的放在前面：

1. **实验 #3 先跑**（决定工程落点，成本最低、影响最大）：新建 `[CloudDev]Empty Ability` 实验工程 → 只观察它生成的根结构，再判断本工程加 `CloudProgram/` 是否需要重排。
2. 实验 #1/#2/#4：同一实验工程里部署 echo 函数，端侧 `cloudFunction.call({ name, timeout: 30000 })` 打一次通（模拟器需先取 `clouddevelopproxy.debugToken` 注册到 AGC，docs/05 §5.6）。
3. 实验 #5：HUKS spike（本工程 `entry` 里加一个临时调试页，或实验工程里加），跑 ECDH 会话 + HKDF 派生 + AES-GCM 加解密闭环，记录参数集与错误码。
4. 实验 #6：云数据库 + 安全规则。

四项 PASS → 把本文件结论改写为 `IN_REPO_CLOUDPROGRAM` 或 `SEPARATE_CLOUD_REPO`（由 #3 决定），并在 §0 记录日期与设备/SDK 版本；任一 FAIL → 维持 `CLOUD_BLOCKED` 并把 FAIL 项写进 §2。

## 4. 门禁规则（阶段 3 启动前必须全部满足）

1. HUKS 安全链路（实验 #5）未验证通过 → **不启动阶段 3**；
2. **不允许退回"邀请码/短码直接派生长期密钥"**；
3. 长期密钥不得写入 Preferences、源码、二维码或日志；
4. 云端任何失败不得阻断本机计算与本机代录；
5. `pairId` / `ownerUid` 明文落云（安全规则与查询所需），班表载荷加密——云端明文里不得出现日程名、课程名、地点、备注、计划标题、长期密钥与邀请历史。

## 5. 当前代码与目标设计的差距（只登记，不改）

| 位置 | 现状 | 门禁通过后的动作 |
|------|------|------------------|
| `cloud/src/main/ets/api/SnapshotCrypto.ets` | `encryptWithKey(keyHex, …)`：AES-256-GCM，**密钥 hex 由调用方给出**；`EncryptedPayload` 只有 `ciphertext/iv`（authTag 拼进密文 hex，无 `algorithm` 字段），AAD 为固定常量 `'crd-v1'` | Task 3.2 换成 HUKS 别名托管的协商密钥，AAD 改为 `pairId\|ownerUid\|version\|schemaVersion`，`EncryptedPayload` 补齐 `authTag/algorithm` |
| `data/.../SettingsStore.ets` `savePairKey/getPairKey`（已在 HEAD） | 配对密钥 hex 落在 **Preferences** —— 直接违反 §4 第 2、3 条，属"短码派生长期密钥"形态 | 删除该持久化路径，改为只保留 HUKS 别名（别名可存 Preferences，密钥材料不可）；解除配对时删别名 |
| `cloud/.../CloudApi.ets:111` `cloudFunction.call({name, version, data})` | **未传 `timeout`** → 走 SDK 默认 70s，超过云函数同步调用 55s 上限（§1） | Task 3.1 统一显式 `timeout: 30000` + `requestId` 幂等；错误码补 401/403 |
| `FeatureFlags.cloudPairing` / `scanPairing` | `false` | 保持 `false`，直到本文件结论改写且阶段 3 完成 |
| `MeView` 配对入口 | 已有不可用降级提示 | 保持（与"云端可降级"定位一致） |
| 根目录 | 扁平多 HAR，无 `CloudProgram/` | 由实验 #3 决定：本仓库加目录，或独立云仓库（届时阶段 3 只在本仓库提交协议与运维文档） |

## 6. 账号侧前置（个人开发者本人操作，见 docs/05 §7）

AGC 项目开通云开发、配额截图核对、确认无欠款并开消费/余额提醒、数据处理位置锁"中国"（一经选择不可改）。另有三条硬约束会影响发布节奏：免费档用尽即停（不自动扩容）、连续 6 个月无有效调用判闲置回收、仅中国大陆。

## 7. 证据清单

- 本机：`D:/local/DevEcoStudio/sdk/default/{hms,openharmony}/ets/...`、`native/sysroot/usr/include/huks/`（§1 逐行引用）；`hdc list targets` → 空。
- 仓库内调研：`docs/05-云端配对前置条件调研.md`（§5.2/§5.3/§5.5/§5.6/§7/§8）、`docs/06-API26能力与精简版优化调研.md`（§3.7-B HUKS + 加密 RDB，P1）。
- 设计口径：`docs/plans/2026-09-21-overall-project-redesign-design.md` 第 189-200 行（HUKS 协商六步、无最终用户身份时不得端侧直连云数据库）。
- 官方文档（docs/05 §9 已附链接与实读日期 2026-09-21）：端云一体化 `cloudfoundation-*`、`huks-key-use-overview`、`huks-key-import-overview`。
