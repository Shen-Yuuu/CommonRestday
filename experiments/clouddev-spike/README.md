# CloudDev / HUKS 一次性实验（throwaway）

配合 `docs/validation/clouddev-api26-spike.md` 使用。**本目录不是 hvigor 模块**（根 `build-profile.json5` 的 `modules` 里没有它），只放实验说明和实测记录；实验工程本身建在仓库外，跑完即可删。

目标：用一次真机/模拟器 + AGC 会话（约 30 分钟）给出 §2 六项实验的实测结论，从而把门禁结论从 `CLOUD_BLOCKED` 改写为 `IN_REPO_CLOUDPROGRAM` 或 `SEPARATE_CLOUD_REPO`。

## 前置（账号侧，docs/05 §7）

- [ ] AGC「开发与服务」能看到并开通"云开发（Serverless）"
- [ ] 项目数据处理位置只启用"中国"，且此前未选过其他区域
- [ ] 账号无欠款，已开消费提醒 + 余额提醒
- [ ] DevEco 已登录该账号；`File → Project Structure → Signing Configs` 勾选自动签名可用

## 实验 1 · 端云工程长什么样（先跑，成本最低、否决权最大）

1. `New Project → [CloudDev] Empty Ability`，**仓库外**新建，Device type 选 Phone，Bundle name 用一个专用的实验包名（如 `com.yourname.crdspike`）。
2. 记录根目录结构：是否只有 `Application/` + `CloudProgram/` 两个文件夹，`CloudProgram` 内含什么（`cloud-config.json`、`cloudfunctions/`、`clouddatabase/`？）。
3. 打开 `CloudProgram/cloud-config.json`，抄下字段名（项目 ID / 应用 ID / 数据处理位置 / deviceType）。
4. **关键判定**：把这些目录**手工拷进**现有 CommonRestday 工程根（不移动 `entry/feature/...`），看 DevEco 是否还认云侧（右侧 CloudDev 面板出现函数列表即算认）。
   - 认 → 候选结论 `IN_REPO_CLOUDPROGRAM`（仍要做实验 2/4/5/6 才能真开工）
   - 不认，且必须把模块下移到 `Application/` 才认 → 候选结论 `SEPARATE_CLOUD_REPO`
   - 云侧根本开通不了 → 维持 `CLOUD_BLOCKED`

记录：根目录树、`cloud-config.json` 字段、是否要求重排。

## 实验 2 · 包名关联 / 自动签名 / debugToken

- [ ] 向导按 bundle name 在 AGC 找到同包名应用（无则新建；类型必须一致：应用 vs 元服务不能混）
- [ ] 自动签名完成后 `build-profile.json5` 的 `signingConfigs` 出现内容（本工程当前是空数组）
- [ ] 模拟器：跑一次任意云接口 → `hdc hilog` 里搜 `clouddevelopproxy.debugToken` → 到 AGC 控制台注册该 token；不注册时端侧调用应看到 **401**（签名校验失败）或 **403**（凭据未注册/绑错应用，改后等约 30 分钟）
- [ ] 真机：同一接口直接调通，无需 debugToken

记录：401/403 的实际错误消息原文、真机与模拟器差异。

## 实验 3 · 多 HAR 工程能否共存（同实验 1 第 4 步，单列以便记结论）

工程落点二选一，写回门禁文件 §0：`IN_REPO_CLOUDPROGRAM` / `SEPARATE_CLOUD_REPO`。
若为后者：**不得重排本仓库根目录**，阶段 3 只在本仓库提交协议与运维文档，函数实现放到经用户另行授权的独立云仓库。

## 实验 4 · Node.js 20 echo 函数 + 30 秒超时口径

1. 实验工程里新建 `cloudfunctions/echo`（Node.js 20 / latest），入口 `handler.myHandler`，写法：
   ```js
   exports.myHandler = async function (event, context) {
     let body = event.body ? JSON.parse(event.body) : event;
     return new context.HTTPResponse(context, JSON.stringify({ echo: body, srv: Date.now() }));
   };
   ```
   入口文件须在部署包根目录；`function-config.json` 的 `functionType` 一经部署不可改（0=云函数 / 1=云对象）；HTTP 触发器 `authType` 用 `apigw-client`（端侧 App 调用），用错报 `mismatched authType`。
2. Windows 部署：右击函数目录 → `Deploy`，等状态栏 `Deploy successfully`。
3. 端侧调用并**显式传 timeout**（默认 70s 超过同步调用 55s 上限，必须收敛）：
   ```ts
   const r = await cloudFunction.call({ name: 'echo', version: '$latest', data: { ping: 1 }, timeout: 30000 });
   ```
4. 记录：正常回包耗时、冷启动是否明显（重复调用间隔 20 分钟再试一次）、断网时的错误码（预期 1008210001）、把 `timeout` 设为 3000 时端侧提前失败的行为（用于确定重试与降级文案）。
5. 顺便验证本地联调：DevEco 本地跑函数 → `localUrl: 'http://localhost:18090'`（部署后该参数不可用）。

## 实验 5 · HUKS ECDH 协商 + HKDF 派生 + AES-GCM（决定阶段 3 生死）

静态前提（门禁文件 §1，已在 API 26 本机类型表中核对）：

- ArkTS HUKS **没有** `agree()` / `deriveKey()` 函数，协商与派生只能走 `initSession → updateSession → finishSession` 会话流程；
- 可用常量：`HUKS_KEY_PURPOSE_DERIVE = 16`、`HUKS_KEY_PURPOSE_AGREE = 256`、`HUKS_ALG_ECC = 2`、`HUKS_ALG_ECDH = 100`、`HUKS_ALG_X25519 = 101`、`HUKS_ALG_HKDF = 51`、`HUKS_ALG_ML_KEM = 200`；
- **参数表里没有 `IS_KEY_NON_EXPORTABLE` 一类的"不可导出"标签**（本机 d.ts 全文 0 命中）→ "非导出"必须靠实测确认其等价表达，见下面第 5 项；
- 本次只允许使用上表已确认存在的标签名（`HUKS_TAG_AGREE_*`、`HUKS_TAG_DERIVE_*`、`HUKS_TAG_IV`、`HUKS_TAG_AE_TAG`、`HUKS_TAG_AAD`、`HUKS_TAG_KEY_STORAGE_FLAG`、`HUKS_TAG_DERIVED_AGREED_KEY_STORAGE_FLAG` 等），不要照抄旧文档里已不存在的标签名。

待实测（每一项都要抄参数集与返回码原文）：

1. 生成本端协商密钥对：`HUKS_TAG_ALGORITHM = HUKS_ALG_ECC`（或 `HUKS_ALG_X25519`）、`HUKS_TAG_KEY_TYPE = HUKS_KEY_TYPE_KEY_PAIR`、`HUKS_TAG_PURPOSE = AGREE`、`HUKS_TAG_KEY_SIZE`（ECC 曲线如何指定？——本表无曲线标签，记录实际可行组合）、`HUKS_TAG_KEY_STORAGE_FLAG = HUKS_STORAGE_PERSISTENT`。
2. 协商：`HUKS_TAG_AGREE_ALG = HUKS_ALG_ECDH` + `HUKS_TAG_AGREE_PRIVATE_KEY_ALIAS` + `HUKS_TAG_AGREE_PUBLIC_KEY`（或 `..._IS_KEY_ALIAS`）→ `finishSession` 返回的共享秘密是 inline 字节还是别名？把 `HuksReturnResult` 结构原样抄下来。
3. HKDF 派生：`HUKS_TAG_ALGORITHM = HUKS_ALG_HKDF` + `HUKS_TAG_DERIVE_MAIN_KEY` / `DERIVE_FACTOR` / `DERIVE_ALG` / `DERIVE_KEY_SIZE = 32` + `DERIVED_AGREED_KEY_STORAGE_FLAG`（`HUKS_STORAGE_TEMP` 与 `PERSISTENT` 两种都试）。
4. 派生密钥直接做 AES-256-GCM：`HUKS_TAG_ALGORITHM = HUKS_ALG_AES`、`HUKS_TAG_PURPOSE = ENCRYPT|DECRYPT`、`HUKS_TAG_BLOCK_MODE`、`HUKS_TAG_PADDING`、`HUKS_TAG_IV`、`HUKS_TAG_AE_TAG`、`HUKS_TAG_AAD` —— 验证 AAD 能承载 `pairId|ownerUid|version|schemaVersion`，并确认**裸密钥是否全程不出 HUKS**（若 `finishSession` 把密钥以 inline 字节交回应用，就属于"密钥进应用内存"，需在门禁文件里如实记录）。
5. **"非导出"验证（安全主张的落点）**：对第 1 步生成的私钥别名调用 `exportKey`，记录它是否只给公钥、是否报错、错误码是多少；再确认 `HUKS_TAG_IS_ALLOWED_WRAP` / `wrapKeyItem` / `unwrapKeyItem`（`HUKS_UNWRAP_SUITE_ECDH_AES_256_GCM_NOPADDING`）是否才是本 SDK 设计的"密钥不出安全环境"通道 —— 若是，阶段 3 的密钥建立优先走 wrap/unwrap 或 KEM（`encapsulate`/`decapsulate`）而不是自拼 ECDH→HKDF。
6. 别名生命周期：`isKeyExist` → 应用重启 → 备份/恢复 → 卸载重装 → 换机；记录哪一步密钥丢失，据此定"重新配对"的产品口径。
7. 删除：`deleteKey` / `deleteKeyItem` 后 `isKeyExist` 为 false（解除配对路径依赖它）。

失败判据：任一环节 ArkTS 表面跑不通 → 评估 NDK（`native/sysroot/usr/include/huks/`，`OH_HUKS_KEY_PURPOSE_AGREE = 256`）；NDK 也不可行 → **维持 `CLOUD_BLOCKED`，禁止退回短码派生长期密钥**。
> `[更正 2026-09-23]` 上一句里"现有 `SettingsStore.savePairKey` 那条路径"已不成立：阶段 6R.2 把 `savePairKey` 与 `deriveKeyHex` 从源码删掉了，现在余下的只是 `getPairKey` 这个**读**口子（见门禁文件 §5）。

### 5.1 本项已有可跑用例：`HuksCustodySpike.test.ets`

上面 7 待测项里的 1/2/3/4/5/7 已经写成一份 instrument 用例（同目录，**刻意不放进构建**，理由见下）。它不需要 AGC、不需要云函数、不需要网络权限——**插上台设备或起个模拟器就能把"阶段 3 生死"这一项判掉**。

三步接线（跑完记得撤）：

1. `cp experiments/clouddev-spike/HuksCustodySpike.test.ets entry/src/ohosTest/ets/test/HuksCustodySpikeTest.ets`
2. 在 `entry/src/ohosTest/ets/test/List.test.ets` 里 `import huksCustodySpike from './HuksCustodySpikeTest';` 并在 `testsuite()` 末尾加 `huksCustodySpike();`
3. DevEco 里右键 `entry@ohosTest` → Run（或 `tools/verify.mjs` 那条 ohosTest 步骤的等价命令）；日志过滤词 `CRD-HUKS`

**跑法要求按声明顺序**（hypium 默认满足）：用例之间存在有意的依赖——第 2 项造的托管别名是第 3、4 项的输入，第 1 项造的 ECC 别名是第 2 项的输入。

**为什么要撤掉**：这份文件本身打 46 条 `ArkTS:WARN`（35 条 syscap 提示 + 8 条"可能抛异常" + 3 条废弃标签），直接超过 `tools/verify-baseline.json` 里 ohosTest 那一档"告警只降不升"的门禁。它是探针，不是交付物。

已核对过的静态前提（都在本机 `@ohos.security.huks.d.ts` 上核过，不再靠猜）：

- 曲线没有独立标签，由 `HUKS_TAG_KEY_SIZE = HUKS_ECC_KEY_SIZE_256` 隐含 → 上面待测项 1 的那个问号可以划掉；
- `HUKS_STORAGE_PERSISTENT` / `HUKS_STORAGE_TEMP` **自 API 10 起废弃**，d.ts 原文明确让派生/协商场景改用 `HUKS_STORAGE_ONLY_USED_IN_HUKS` 或 `HUKS_STORAGE_KEY_EXPORT_ALLOWED` → 生成本端密钥对时**不要**带 `KEY_STORAGE_FLAG`；
- `HUKS_TAG_DERIVE_MAIN_KEY` / `DERIVE_FACTOR` / `DERIVE_ALG` 三个**全是 `@deprecated since 9`**，且表里没有未废弃的替代（`HUKS_TAG_KEY` 注释只有 "Reserved"）→ 这就是第 4 项要实测的原因：跑通了也要记"建立在废弃标签上"，跑不通就退回"协商时直接给 `DERIVED_AGREED_KEY_STORAGE_FLAG`"那条；
- `HUKS_TAG_AAD` 是 **@since 24**（`AE_TAG` 自 8 就有）→ 今天 `compatibleSdkVersion` 是 26 所以无感，**但哪天为了装机量往下调版本，先砍的是 AAD 绑 pairId 这一步**，托管链路本身在 API 12 上仍成立。

## 实验 6 · 云数据库只经云函数访问

1. 建对象类型 `snapshot`：`pairId`(明文)、`ownerUid`(明文)、`peerUid`(明文)、`cipher`、`version`、`updatedAt`；注意**全程加密字段在安全规则里恒为 null**，所以明文规则字段不可省。
2. 安全规则先写"默认拒绝"，只允许云函数侧访问；端侧直连读取应报 `2001015:permission denied`。
3. 云函数用云侧 SDK 读写该对象类型（同一 `CloudProgram` 内），验证配对双方各自只能读写自己 ownerUid 的记录。
4. 记录：端侧 2001015 原文、云函数访问是否需要额外凭据、`fieldType` 部署后不可改的实际表现、单对象 2MB 与查询 5MB/1000 条上限对本设计的实际影响。

## 结果回填

| 实验 | 结果 | 关键错误码/参数原文 | 日期 |
|------|------|--------------------|------|
| 1 端云工程结构 |  |  |  |
| 2 包名/签名/debugToken |  |  |  |
| 3 现工程共存 |  |  |  |
| 4 echo + 30s 超时 |  |  |  |
| 5 HUKS 链路 |  |  |  |
| 6 云数据库规则 |  |  |  |

跑完把结论（含设备型号、系统版本、DevEco 版本）写回 `docs/validation/clouddev-api26-spike.md` 的 §0/§2，并保持"只有一项结论"。
