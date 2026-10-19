# 共同计划连接：CloudDB Long 回包兼容

日期：2026-10-08。接公钥兼容补丁，不部署云、不操作模拟器。

## 设备回报与定位

用户在点击「生成短码」后回报：

```json
{"tag":"FORTWO_PLAN_LINK_DIAG","build":"2026-10-08-diag2","stage":"reply.validate","code":"INVALID_REPLY","sdkCode":""}
```

页面停在「操作结果待确认，可手动继续检查」，已有请求保留。
这说明已越过本次设备公钥准备并收到可解析的、`code=OK` 的业务回包，但具体哪项校验失败不能仅凭原粗阶段确定。
没有读取或打印真实回包，不把此日志视为计划连接已成功。

本机实际安装的 `@hw-agconnect/cloud-server@1.0.5` 中，
`database-service/utils/Utils.js` 的 `isFieldTypeNumber` 列举 Integer 等类型，但不含 Long。
`deserializeObjects` 因而保留 Long 十进制文本；`expiresAt` 在 PairMemberBinding 模型中正是 Long，
服务端 `body()` 原样返回 `row.getExpiresAt()`。`revision` 是 Integer，会转换为数字。
模型 `.d.ts` 写 `getExpiresAt(): number` 并不能改变 SDK 的实际反序列化行为。

使用该 SDK 的真实反序列化器、生产模型及生产客户端编排，构造 Long 文本有效期，
新增用例修前得到 `INVALID_REPLY`，修后得到 `OK / WAITING` 并展示短码。
此处是已复现的 SDK 与客户端类型兼容缺口；用户设备上的实际有效期字段仍未采样，若另有字段不匹配，新诊断会继续分层定位。

本机 FortwoCloud 的 pairing／dateplan 均安装 SDK 1.0.5，仓库与两套 CloudProgram 的 `service.ts` SHA256 一致。
这只核对本机源文件，不证明 AGC 当前运行版本与它一致。

## 客户端改动

- 仅将连接回包 `expiresAt` 接受范围扩为安全的非负整数数字，或其规范十进制文本。
  文本限 1–16 位、只接受 `0` 或不带前导零的正整数；转换后仍要求 `Number.isSafeInteger`。
- 拒绝空串、前后空格、前导零、负数、正号、小数、指数、十六进制、超长／超安全整数、null、布尔、数组与对象。
- 解码后的本机连接进度仍存数字，不迁移数据库、不修改云 schema、不转换其他回包字段。
  协议／能力／revision／身份／伙伴公钥校验不放宽；未确认仍不激活计划会话。
- 保留原 flowId、匿名 UID、公钥与密封凭据。手动恢复仍使用原创建请求，不能静默再生身份、密钥或新连接。
- `reply.validate` 拆出十组固定子阶段：status／identity／capability／revision／expiry／binding／transition／peer／invite／proof。
  业务码仍是 `INVALID_REPLY`，只给出失败组，不复制任何真实字段值。
- 诊断版本为 `2026-10-08-diag3`，仍只有 tag／build／stage／code／sdkCode 五字段。
  不输出 token、UID、公钥、短码、确认凭据或原始回包。
- 仅修改客户端 SecurePairingUseCase、诊断 helper、两份已有专项脚本及验证文档。
  服务端代码、已部署云、签名、权限和功能开关均未修改；其他 WIP 不整理、不提交。

## 本机验证

- `node tools/test/secure-pairing-regression.cjs`：33 passed / 0 failed（较 28 项新增 5 项）。
- 实际 SDK 反序列化器在 VM 中运行；只载入无网络常量模块，其余未调用的 schema／异常依赖隔离，不初始化 Auth／Cloud 实例或 HTTP。
  这不是自制 Long 转换桩，也不是真实 AGC 请求或设备证据。
- 新用例覆盖真实 SDK Long 文本、创建／加入／确认／ACTIVE 检查的字符串有效期与零，异常值拒绝、原请求恢复，以及固定失败字段分组／隐私过滤。
- `node tools/test/shared-plan-secure-regression.cjs`：30 passed / 0 failed，公钥三格式九组合及密码学回归保持通过。
- `node tools/verify.mjs --steps=offline,debug,release,ohostest`：exit 0，ALL PASS。
  离线关闭／开启两档各 typecheck 0 errors、337 passed / 0 failed，专项脚本均通过。
- debug／release／ohosTest 均 BUILD SUCCESSFUL；ArkTS:WARN 为 277／275／257，
  原基线 289／289／269 未上调。ohosTest 仅编译，未运行设备测试或锁屏通知。
- `git diff --check` 与六份本批变更文件的尾部空白检查通过；未提交 Git。
  两档离线与三档编译日志在 `E:/desktop/Code/harmony/.crdtest/verify-*.log`，会被后续门禁覆盖。

## 用户操作

1. 主项目 CommonRestday 覆盖 Run 到两台设备；不要卸载、清数据、解除班表配对或另造匿名身份。
2. 当前截图这台已有操作进度，直接点「检查连接 / 重试」，不要找「生成短码」或先解绑。
   原创建请求能恢复到等待状态时，应显示六位短码。
3. 另一台输入短码点「申请加入」；邀请方检查后确认加入，另一台再检查。双方应显示共同计划连接已确认。
4. 若仍失败，提供 `FORTWO_PLAN_LINK_DIAG` 中 `build=2026-10-08-diag3` 的新记录或页面失败阶段截图。
   如变为 `reply.validate.peer` 等其他子阶段，按新字段证据继续查，不做自动空值兜底或放宽身份校验。
5. 连接成功后再用一条未来、不冲突的计划验证跨端邀请与确认；不能仅凭短码出现就勾掉协商／计划验收。

无需重新部署云对象／云模型、更新 Profile／证书或新增权限。
设备连接与计划跨端验收仍待用户复测。
