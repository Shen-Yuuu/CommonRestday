# 同休日全阶段改造最终验收

> 验收日期：2026-09-23  
> 提交基线：`d1f0a6b`；当前工作树另有 `PaintMonth.ets`、`ScheduleEditor.ets` 两个用户 WIP  
> 核验范围：阶段 0–6 与阶段 6R.1–6R.4；阶段 6R.5 真机验收和账号侧提审材料单独判定  
> 核验方法：提交与源码静态审计、本机 API 26 SDK 声明、统一验证脚本、HDC 设备探测、发行配置与隐私口径交叉核对  
> **最终结论：主体工程整改有条件通过；整体验收不通过，当前仍为 `NOT RELEASE READY`。**
>
> **整改回执（同日，2026-09-23）**：§4 的 R1、R2 已在仓库侧闭环，逐条对账与复跑数字见 **§4.1**；本文的结论**不改**——
> B5（包身份/签名/备案/URL）与 B6（零设备证据）与本轮整改无关，仍为空。

## 1. 结论摘要

本轮确认 `d1f0a6b` 所述整改大部分真实落地，且统一门禁可复现：

- 日历默认路径已从不可管理的 `editEvent` 改为应用专属「同休日」日历的受管写入；显式导出独立标记为 `EXTERNAL_UNMANAGED`；
- 取消、改期、补扫和清空均已接入投影清理服务，失败句柄在普通计划操作中可保留并重试；
- `cloudPairing=false` 已成为 service/integration 层真实边界，旧的短码派生长期密钥写入口已删除，首发包不再申请 `INTERNET`；
- 离线 runner 不再允许类型错误假绿，debug/release/ohosTest/性能已统一为一个验证入口；
- 创建计划只暴露「一起吃饭 / 其他」，旧 8 类仍可正确展示；EntryAbility 已锁竖屏；
- 隐私全文已随包内置，首启和「我的」页不再指向空白的外部页面。

但最终审计新发现两项尚未闭环的产品事实冲突，并且账号、签名、真机证据仍为空。因此不能把“所有阶段大致完成”改写成“已可提审”。

## 2. 本轮独立证据

### 2.1 仓库与提交

- `d1f0a6b`：30 files changed，`+718/-149`，与改造结论一致；
- 验收前后 `git status --short` 均只有：
  - `entry/src/main/ets/pages/PaintMonth.ets`
  - `entry/src/main/ets/pages/ScheduleEditor.ets`
- 两个文件是用户 WIP；本轮未编辑、未暂存、未提交。

### 2.2 统一门禁实跑

执行：

```powershell
node tools/verify.mjs --steps=offline,debug,release,ohostest,perf
```

结果：

| 步骤 | 结果 |
|---|---|
| offline | `typecheck=0 errors`，`195 passed / 0 failed`，exit 0 |
| debug | `BUILD SUCCESSFUL`，ArkTS:WARN 349 / 基线 349 |
| release | `BUILD SUCCESSFUL`，ArkTS:WARN 349 / 基线 349 |
| ohosTest | `BUILD SUCCESSFUL`，ArkTS:WARN 260 / 基线 260；仅编译，未在设备执行 |
| perf | exit 0；全部预算内 |
| 汇总 | `verify: ALL PASS` |

注意：全量命令逐步 `clean`，最后保留的是 ohosTest unsigned HAP；release 步骤日志仍明确打印 `Will skip sign`。这不影响 release 编译结论，但说明它不是可提审签名包。

### 2.3 设备与发行状态

- `hdc list targets`：`[Empty]`；
- `build-profile.json5`：`signingConfigs: []`；
- release 日志：`Will skip sign 'hos_hap'. No signingConfigs profile is configured`；
- `AppScope/app.json5`：`vendor: "example"`，`bundleName: "com.huawei.commonrestday"` 尚未确认主体归属；
- 隐私政策在线 URL、备案、开发者信息、商店截图与年龄分级仍待人工回填。

## 3. 阶段与阻断项复验

| 项目 | 当前判定 | 验收意见 |
|---|---|---|
| B0 日历生命周期 | **代码通过 / 待设备** | 受管写入与外部导出已分开；API 26 真机仍须验证创建、撤权、改期、取消与系统侧提前删除 |
| B1 云关闭安全边界 | **通过** | 云动作在副作用前检查开关；短码派生长期密钥的生产写入口已移除；`INTERNET` 已移除 |
| B2 系统投影清理 | **代码有条件通过 / 待设备** | 普通取消/改期具备 tombstone 与补扫；清空全部数据另有 R2 文案缺陷 → **R2 已整改**（§4.1），提示不再承诺不可能的重试，残留位置改为指向系统侧人工检查 |
| B3 测试假绿 | **通过** | 类型失败停止测试并非零退出；统一门禁本轮独立复跑通过 |
| B4 隐私与权限 | **不通过** → 整改后为**冲突已消除 / 判定停在待设备**（§4.1） | 随包全文与权限口径已改善，但启用系统备份恢复与“仅在本机”承诺冲突，见 R1 → 按“保留能力 + 修订披露”闭环，绝对化措辞由 `tools/test/copy-audit.mjs` 机器把关；仍待设备：备份/克隆往返后句柄是否真降级（TC §17.3.6）、屏上文字当场是否成立（TC §20.3） |
| B5 包身份与提审材料 | **不通过** | unsigned、`vendor=example`、包名归属、备案、URL、截图与开发者信息仍未完成 |
| B6 API 26 设备证据 | **不通过** | 本机无 target；渲染、权限、日历、提醒、卡片、备份恢复、无障碍与真机性能均不能判通过 |
| D1 计划类型 | **通过** | 新建只显示「一起吃饭 / 其他」，旧 key→label 兼容保留 |
| D2 首发横屏策略 | **代码通过 / 待设备** | `orientation: portrait` 已落地；仍需真机确认横握不转，解除锁定必须另跑横屏矩阵 |
| 阶段 3 云配对 | **按门禁保持关闭** | 不是首发缺陷；不得把关闭态描述为“云端能力已完成” |

## 4. 必须继续整改

### R1 — P0：系统备份恢复与隐私政策“只在本机”承诺冲突

**证据：**

- `entry/src/main/resources/base/profile/backup_config.json` 为 `allowToBackupRestore: true`；
- `EntryBackupAbility.onBackup()` 明确依赖系统整体备份沙箱中的 RDB 与 Preferences；
- 当前隐私政策写着“全部写进应用自己的本机数据库”“本机代录数据同样只存在这台手机上”“不上传任何服务器”；摘要也写“仅存储在本机”。

华为官方《应用数据备份恢复概述》说明，接入 `BackupExtensionAbility` 后，应用数据备份恢复会在应用克隆和应用数据迁移中被系统触发。即使应用自身没有 `INTERNET` 权限，这些数据仍可能经系统流程离开当前设备、恢复到另一台设备。因此“这台手机上的本地存储”与“不会经应用自己的网络上传”必须分开表述。

**推荐修法：保留备份恢复能力，修订披露。**

1. 在首启摘要、随包全文、canonical Markdown/HTML 同时增加“系统备份/换机迁移”一节；
2. 明确数据类别：RDB 班表、课表、计划、伴侣代录档案与 Preferences 设置可能被系统备份/迁移；
3. 明确触发方与边界：应用不主动联网、不自行上传服务器；备份/迁移由用户或系统流程触发，传输与保存由系统能力管理；
4. 说明恢复后会清除来源设备的日历事件 ID、提醒 ID、配对状态等设备本地句柄；
5. 将“同样只存在这台手机上”改为“保存在应用沙箱；启用系统备份或换机迁移时，可能随系统流程恢复到你的其他设备”；
6. 若不接受这项产品口径，则把 `allowToBackupRestore` 改为 `false` 并移除/停用 backup extension，再重新构建验证。两种方案只能选一种，不能保留能力却继续承诺绝不离开当前设备。

**复验标准：** 三份全文与首启摘要逐字核对通过；真机完成一次备份/恢复或数据克隆，恢复后的设备句柄降级符合设计；隐私政策不再出现绝对化冲突表述。

### R2 — P1：清空数据后的提示仍承诺“可稍后重试”

**证据：**

1. `ProfileSettingsService.clearAllData()` 先尝试清理系统投影，随后无论系统侧是否成功都会执行 `ScheduleRepo.clearAllData()` 与 `SettingsStore.clearAllSettings()`；
2. 清库后 event/reminder 句柄已消失，应用内没有下一次重试所需的记录；
3. `clearAllMessageOf()` 复用了 `cleanupMessageOf()`，失败时仍返回“X 项日历/提醒没清掉，可稍后重试”；现有离线用例还把这句固定成期望值。

这不影响普通取消/改期的“稍后重试”——那两条路径会保留 tombstone；问题只存在于“清空我的全部数据”。

**整改方式：**

- 为 clear-all 单独生成失败文案，例如“本机数据已清空；2 项系统日历/提醒可能仍存在，本应用已无法再次清理，请到系统日历/系统设置中检查”；
- 或者在清库前把清理队列保留到独立、用户可见且可再次清除的最小存储中。但这与“清空全部数据”语义冲突，不推荐；
- 同步更新 `PlanUseCaseTest`、隐私政策“怎么删除”段和真机清空用例。

**复验标准：** 系统清理失败后不再出现“可稍后重试”；用户知道本机数据已删、残留位置和人工处理方式；普通取消/改期仍保留原重试文案。

### 4.1 整改回执（2026-09-23，仓库侧完成，设备侧未验）

本回执只登记**改了什么、按哪一条判据**，不改动本文任何判定。§7 的 Go/No-Go 结论**未变**：R1/R2 关闭的是产品事实冲突，B5/B6 仍是阻断，整体仍为 `NOT RELEASE READY`。

**R1 — 采用方案一（保留能力、修订披露），`allowToBackupRestore` 保持 `true`。** 推荐修法的 6 点逐条对账：

| 判据 | 落地 |
|---|---|
| 1 四处同时增节 | 全文新增「系统备份与换机迁移」（`pp_backup_t/pp_backup_b`）并插在「你录入的内容…」之后，首启摘要新增第 2 条 `privacy_point_backup`；`docs/legal/privacy-policy.md`、`privacy-policy.html`、`docs/prototype/index.html`（镜像）同批改，全文由十节变**十一节**、摘要由四条变**五条** |
| 2 数据类别 | `pp_backup_b` 逐项列出：班次与课程、共同计划、伴侣代录档案、设置（即 RDB + Preferences 整个沙箱） |
| 3 触发方与边界 | 同节写明“由系统能力管理，传输与存放都不经过本应用，本应用也不会主动上传到任何服务器”；`pp_data_b`/`privacy_point_local` 的“不上传任何服务器”收窄为“**本应用**不联网、不上传”，并把“只存在这台手机上”改成“写进应用沙箱里的本机数据库” |
| 4 恢复后设备句柄作废 | 同节写明日历与提醒句柄被清掉、配对回到未配对、条目要在新设备重写——与 `EntryBackupAbility` + `MigrationRunner.finishRestore` 的实际行为一致，不是前瞻承诺 |
| 5 措辞改写 | `pp_data_b`、`privacy_point_local`、`privacy_point_cloud`、`pp_delete_b` 四处；`pp_delete_b` 另加“已经随系统备份出去的要在系统备份管理里删”。**同类口号在政策之外还有一处**：「我的」页顶部身份副标题（`MeView.identitySub()`）原写「数据只存在这台手机」，一并改为「数据只写在本机的应用沙箱里」——所以禁令也覆盖了全部随包源码（见下） |
| 6 备选方案 | **未采用**：关能力换来的只是让口号继续成立，而恢复降级对换机用户有实际价值；理由记在发布清单 G4 第 8 行 |

“三份全文与首启摘要逐字核对”这一半**已升级为机器门禁**：`tools/test/copy-audit.mjs` 在 `node tools/test/run.mjs` 跑用例之前逐字比对五处产物（`string.json`、`PrivacyPolicySheet.ets` 节序、`PrivacyDialog.ets` 摘要序、md、html），并禁止“只存在这台手机上/不会离开这台手机/仅存储在本机数据库”等绝对化措辞，违规即退出码 1、不产出绿灯。负向验证过两次：临时改 md 一处措辞 → 报 2 条冲突（逐字漂移 + 绝对化表述）；把旧口号回填进 `MeView.ets` → 报出该文件 1 条；两次改回后均为 0 条，确认它不是空跑。唯一豁免是 `pp_version_b`：托管页要在此填在线 URL 与联系方式，包内那份写“随提审材料提供”，豁免写在代码与 html 文件头。绝对化措辞的禁令**不只作用于这五处产物**：`entry/feature/data/cloud/commons/domain` 的 `src/main` 下每个 `.ets`/`.json` 同样被扫一遍——政策改口、界面口号留在原地的情形（本次实测就撞上一个：「我的」页身份副标题）由此结构上不可能再发生；`docs/` 刻意不在扫描范围内，因为验收记录要引用旧措辞，那是记录不是承诺。**“真机完成一次备份/恢复或数据克隆”仍未做**（TC §17.3.6，本机 `hdc list targets` 为 `[Empty]`），所以 §3 的 B4 判定停在待设备。

**R2 — 只改这一句话，不新建重试队列。** `clearAllMessageOf()` 不再复用 `cleanupMessageOf()`：失败项改为“N 项系统日历/提醒可能仍在，本应用已无法再替你清理，请到系统日历/系统设置检查”，并分别列出“导出的那条由系统日历管理”与“「同休日」日历没有清空”；`cleanupMessageOf()`（取消/改期）的“可稍后重试”原样保留，因为那条路径留着 `CLEANUP_PENDING` 句柄与「重新清理」入口。离线断言**正反都钉**：`PlanUseCaseTest` 同时断言清空句不含“稍后重试”、取消句含；`ProfileSettingsGuardTest` 跑真实 `ProfileSettingsService.clearAllData()`。隐私政策“系统日历与提醒的边界”“怎么删除”两段与 TC §20.1.4 同步换判据。采纳了推荐文案的语义，未采纳“把清理队列保留到独立可再清除存储”那一条（与“清空全部数据”的产品语义冲突）。

**本轮门禁复跑**：`node tools/verify.mjs --steps=offline,debug,release,ohostest,perf` → `verify: ALL PASS`；离线 `copy: PASS / typecheck 0 errors / 195 passed / 0 failed / exit 0`（用例总数不变，新增的是既有用例里的正反断言与独立的 `copy` 一行）；三条 clean 出包 `BUILD SUCCESSFUL`、0 ERROR，`ArkTS:WARN` 349 / 349 / 260 与本轮之前同档，`tools/verify-baseline.json` 未调整。

## 5. 账号与设备侧完成条件

### 5.1 账号侧

1. 定稿开发者主体、`bundleName` 与 `vendor`；
2. 配置正式签名，release 产物不再带 `-unsigned`；
3. 完成 App 备案并登记编号与日期；
4. 托管 `docs/legal/privacy-policy.html`，回填在线 URL、开发者名称与联系方式；
5. 完成截图、介绍、分类、Age rating、版权信息；
6. 继续保持 `cloudPairing=false / scanPairing=false`，首发不创建云能力假象。

### 5.2 API 26 真机（阶段 6R.5）

按 `docs/testing-checklist.md` 执行，至少覆盖：

1. 全新安装、隐私拒绝/接受、飞行模式启动；
2. 单人和本机代录的三答案、四类录入链路；
3. 受管日历创建—改期—取消—清空，权限拒绝/撤回、系统侧提前删除；
4. ReminderAgent 允许/拒绝、计划提醒与周摘要清理；
5. 服务卡片添加、刷新、点击回流、移除重加；
6. 360vp、深色、2× 字体、读屏、Senior Mode、降低透明度；
7. 竖屏锁、后台/回前台补扫、备份恢复/数据克隆；
8. ohosTest 在设备真实执行，以及一轮设备性能采样。

每条记录设备型号、API/系统版本、时间、预期、实际、截图/日志位置与结论。没有这些证据时，“待设备”仍是阻断，不等同于通过。

## 6. 下一步执行顺序

1. ~~**先修 R1、R2**，新增对应离线断言并重跑统一门禁~~ —— **仓库侧已完成**（2026-09-23，见 §4.1 回执）：披露修订 + `copy-audit.mjs` 机器门禁 + 清空文案改口并正反钉住，统一门禁 `ALL PASS`。R1 的“真机备份/克隆往返”那一半仍随 6R.5 执行；
2. **再完成账号侧材料与正式签名**，生成可安装的 signed release HAP；
3. **接入 API 26 真机执行 6R.5**，优先跑日历/提醒/清空/备份四条高风险链路，再跑视觉与无障碍矩阵；
4. 回填 `submission-materials.md` 与发布清单；
5. 只有当 R1/R2、B5、B6 全部关闭后，才进行最后一次 clean signed release 验证，并把状态改为 `READY FOR SUBMISSION`。

## 7. 最终 Go / No-Go

| 目标 | 判定 |
|---|---|
| 继续以当前精简原型和阶段 6R 代码为后续基线 | **GO** |
| 合并/认可 `d1f0a6b` 的主体整改方向 | **GO（有条件）** |
| 宣称所有阶段均已完整验收 | **NO-GO** |
| 生成正式提审包或提交应用市场 | **NO-GO** |

最终判词：**项目已经从“结构性发布风险”进入“少量明确整改 + 账号/真机收口”阶段，主体重构不需要返工；但 R1、R2 与 B5、B6 未关闭前，最终验收不得签字。**

