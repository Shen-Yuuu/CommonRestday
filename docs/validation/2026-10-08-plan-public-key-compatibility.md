# 共同计划连接：P-256 公钥格式兼容

日期：2026-10-08。用户同意后的客户端修复；不部署云、不操作模拟器。

后续设备已越过密钥阶段，回报生成短码时 `reply.validate / INVALID_REPLY`。
该下一轮 CloudDB Long 兼容与 `diag3` 记录见 [回包兼容报告](2026-10-08-plan-reply-long-compatibility.md)；下文保留本轮 `diag2` 历史回执。

## 原因与证据边界

用户回报 `FORTWO_PLAN_LINK_DIAG / 2026-10-08-diag1 / key.identity / RESULT_UNKNOWN`，SDK 码为空。
这个阶段可以包括索引计算、HUKS 查询／生成／导出、公钥格式校验，单凭该日志不能确定其中哪一步。

源码中存在已复现的格式缺口：`planPublicPoint` 原来只接受 64 字节坐标和 65 字节 SEC1 点，拒绝 X.509 DER。
以 Node 真正生成的 P-256 X.509 SPKI（91 字节）调用生产实现，新增回归先得到 `PLAN_PUBLIC_KEY_FORMAT`；修复后通过。
华为[密钥导出文档](https://developer.huawei.com/consumer/en/doc/harmonyos-guides-V13/huks-export-key-arkts-V13)
规定 `exportKeyItem` 的 `outData` 为 X.509 DER 公钥；[密钥导入算法规格](https://developer.huawei.com/consumer/cn/doc/harmonyos-guides-v5/huks-key-import-overview-V5)
亦列明 ECC／ECDH 公钥为 X.509 DER。引用用于公钥格式依据，不将该文档版本当 API 26 设备实测。
原班表 HUKS 协商路径使用导出公钥直接回填 `updateSession`，本次只为共同计划补齐相同表示转换。

尚未读取用户这台设备实际导出的字节，也没有完成修复后的设备验收；不宣称设备故障已结案。

## 实施范围

- 对外仍是原来的 65 字节未压缩 P-256 点及 Base64，不改云协议、模型、计划信封或数据库。
- 支持原 64 字节 XY、65 字节 SEC1，以及规范 91 字节 P-256 X.509 SPKI。
- DER 严格匹配整体长度、嵌套长度、`ecPublicKey` 与 `prime256v1` OID、BIT STRING 长度与零 unused bits、`04` 未压缩点前缀。
  不截取任意 DER 尾部；拒绝尾随数据、损坏头、其他曲线、压缩点和私钥 DER。点的密码学有效性仍由 HUKS 协商验证。
- 协商输入根据本机 HUKS 导出的表示回填：XY 去掉 `04`，SEC1 保持点，DER 用固定规范头包装对端点。
- 不删除／重建现有身份密钥，不改旧班表密钥路径；已存在派生密钥仍直接复用，失败无静默再生或自动重试。
- 诊断版本升级 `2026-10-08-diag2`；只扩充固定阶段名单，保留有界数字 SDK 码，不输出异常正文、UID、别名、公钥、私钥或 token。
- 仅改 `SecurePlanKeyStore.ets`、`PairKeyStore.ets` 的计划路径、`PlanConnectionDiagnostic.ets`、已有安全专项脚本及本报告。
  其他 WIP 未提交、未整理、未重置。

## 诊断细分

| 阶段 | 操作 |
| --- | --- |
| `key.hash` | 计算密钥索引 |
| `key.identity.lookup` / `generate` / `export` | 查询／生成设备身份密钥／导出公钥 |
| `key.identity.format` / `encode` | 公钥格式校验／Base64 编码 |
| `key.agree.lookup` / `format` | 检查已有密钥／准备协商公钥表示 |
| `key.agree.init` / `update` / `finish` / `available` | 初始化／传入公钥／完成协商／检查派生密钥 |

若还失败，请提供对应 `diag2` 记录。`key.identity.format` 不带 SDK 数字是正常的应用侧格式拒绝，不能因此推断 AGC 未部署。

## 本机验证

- `node tools/test/shared-plan-secure-regression.cjs`：30 passed / 0 failed，较前次 23 项新增 7 项。
- 新增覆盖真实 SPKI 正向转换、DER 各头字段损坏／长度／尾随／私钥／压缩点拒绝、其他曲线拒绝，
  三格式九种双端 ECDH 组合及 AES-GCM 跨端解密，身份不再生、已有密钥不替换，安全诊断和失败会话 abort。
  测试 DER 编解码参考独立 Node `createPublicKey`，不借生产解析器验证自身。
- `node tools/test/secure-pairing-regression.cjs`：28 passed / 0 failed，持久化恢复与连接编排回归保持通过。
- `node tools/verify.mjs --steps=offline,debug,release,ohostest`：exit 0，ALL PASS。
  离线关闭／开启两档各 typecheck 0 errors、337 passed / 0 failed；专项脚本均通过。
- debug／release／ohosTest 均 BUILD SUCCESSFUL，ArkTS:WARN 为 277／275／257，原基线 289／289／269 未调整。
  ohosTest 只编译，未运行设备测试。构建日志位于 `E:/desktop/Code/harmony/.crdtest/verify-{debug,release,ohostest}.log`；日志会被下次门禁覆盖。
- `git diff --check` exit 0。以上 Node 适配器不是设备 HUKS／Auth／AGC 证据；本批没有重新运行设备 perf 或锁屏通知。

## 用户复测步骤

1. 在 DevEco 用主项目 **CommonRestday** 原有签名配置，分别向两台模拟器 Run 覆盖安装。两台都更新；不要卸载、清数据或解除已有班表配对。
2. 确认原班表配对还在，打开「我的 → 伴侣与同步 → 共同计划连接」。
3. 若 A 是「尚未建立」则点一次「生成短码」。若已有「操作结果待确认」等进度，点「检查连接 / 重试」，不要另造新连接。
4. A 显示六位短码后，B 输入该短码并点「申请加入」。A 点「检查连接 / 重试」，看到申请后点「确认对方加入」。
5. B 点「检查连接 / 重试」；必要时 A 再检查一次。双方均应显示「共同计划连接已确认」。仅显示短码不是验收完成。
6. 再创建一个未来、不与班表冲突的测试共同计划。另一端手动刷新，应看到可读标题／时间和「待确认」；同意后双方刷新，应为已确认并参与计算。
   此步骤确认真实 HUKS 协商及跨端解密；锁屏 Push 不在本补丁验收范围。
7. 如有失败，复制 DevEco HiLog 中 `FORTWO_PLAN_LINK_DIAG`、`build=2026-10-08-diag2` 的那一条，或发页面失败阶段截图。不要据此清数据／更换证书。

本次不需要重新部署 CloudDevSpikeOfficial／ForTwoCloud，不需要新权限、Profile 或证书。
真实连接／计划解密：待用户回报，不自动勾选。
