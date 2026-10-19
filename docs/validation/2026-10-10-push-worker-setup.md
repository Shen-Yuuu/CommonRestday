# Push 分段密钥与通知补送 worker：操作步骤

适用于“两人份”正式项目；2026-10-10。用户已确认 WORK 权益通过、已下载服务账号密钥、精简 JSON 仍无法保存。
本次已修改代码、同步两个云项目源文件并重建部署 ZIP；没有读取真实密钥、登录 AGC 或部署。手机客户端无需为分段配置重新打包。

## 1. 先部署支持分段的 dateplan

1. 在 DevEco 打开 `E:/desktop/Code/harmony/FortwoCloud/Application`，确认关联正式“两人份”项目。
2. 本次同步的 `CloudProgram/cloudfunctions/dateplan/push-account.ts`、`push.ts`、`dispatch.ts` 已到位。
3. 右键 `dateplan` → Deploy，部署整个云对象目录。入口仍是 `dateplan.DatePlan`，保留原客户端网关鉴权。
4. 确认云端配置没有被部署重置。先保持 `FORTWO_ENABLE_PLAN_PUSH=false`，填完密钥后再启用。
5. 这次没有改云数据库模型，不需要重新部署五个模型，更不用删表、删区或解除配对。

不要把主 App 通知配置到隔离的 CloudDevSpikeOfficial 项目。其源码也已同步，仅用于隔离验证。

## 2. 在你本机生成分段，不发给 AI

打开 PowerShell。将下面路径换成你下载的真实服务账号文件路径，文件应放在仓库外：

```powershell
$pushKeyPath = 'C:\你的私有目录\服务账号密钥.json'
powershell.exe -NoProfile -ExecutionPolicy Bypass -File 'E:\desktop\Code\harmony\CommonRestday\tools\prepare-push-account.ps1' -Path $pushKeyPath
```

默认仅显示分段数、变量名和长度，不显示密钥。不上传文件、不写配置文件、不更改剪贴板。
每段默认最多 512 字符。若控制台单项限制仍小于 512，可在**所有命令**中统一加 `-PartLength 256`（支持 128–512）。
分段只能解决**单项**值长度限制；若提示全部环境变量总量超限，不再继续缩短单段，须改用平台允许的秘密存储方式。

### 逐项复制（推荐）

```powershell
# 复制总段数 N 的值，粘贴到 FORTWO_PUSH_SERVICE_ACCOUNT_PARTS
powershell.exe -NoProfile -ExecutionPolicy Bypass -File 'E:\desktop\Code\harmony\CommonRestday\tools\prepare-push-account.ps1' -Path $pushKeyPath -CopyPart 0

# 复制第 1 段的值，粘贴到 FORTWO_PUSH_SERVICE_ACCOUNT_1
powershell.exe -NoProfile -ExecutionPolicy Bypass -File 'E:\desktop\Code\harmony\CommonRestday\tools\prepare-push-account.ps1' -Path $pushKeyPath -CopyPart 1
```

把最后的 `1` 依次改为 `2`、`3`……直至工具显示的 N。每次复制后立刻粘贴到对应云端变量；不是把 N 填到所有段里。
工具已处理 JSON 的换行转义，粘贴原样，不额外加引号、不删除反斜杠、不插入空格/换行、不自行把私钥裁短。

若用控制台“JSON 格式编辑”，可以一次复制账号相关的整个环境变量对象：

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File 'E:\desktop\Code\harmony\CommonRestday\tools\prepare-push-account.ps1' -Path $pushKeyPath -CopyEnvironmentJson
```

将这些键值对**合并**进原环境变量对象，保留原项目 ID、区名、开关等，不整体覆盖原对象。
如果你当前正好只有用户提供的四项，以下命令可在本机生成包含四项和分段的完整 JSON，不在终端输出密钥：

```powershell
# 前提：刚执行完上面的 -CopyEnvironmentJson，剪贴板里是工具生成的账号分段对象
$accountVariables = Get-Clipboard -Raw | ConvertFrom-Json
$planVariables = [ordered]@{
  FORTWO_ENABLE_PLAN_PUSH = 'true'
  FORTWO_SHARED_PLAN_ZONE = 'FortwoPlans'
  FORTWO_ENABLE_SHARED_PLAN_V1 = 'true'
  FORTWO_AUTH_PROJECT_ID = '101653523865149102'
}
foreach ($accountProperty in $accountVariables.PSObject.Properties) {
  $planVariables[$accountProperty.Name] = [string]$accountProperty.Value
}
Set-Clipboard -Value ($planVariables | ConvertTo-Json -Depth 4)
```

随后到云端 JSON 编辑框 Ctrl+A / Ctrl+V，保存。**仅在原配置确实只有这四项时整体替换**；已有其他配置时应先保留它们。
此处开启 Push 的前提是新 dateplan 源码已部署，配置在同一次保存中完整提交。不要将工具产生的字符串再手动解析成嵌套对象。
若控制台会记录/明文导出变量，应限制项目成员访问；不要将变量导出文件发聊天或提交仓库。
剪贴板包含凭据，粘贴完清除；若开启 Windows 剪贴板历史/跨设备同步，还应清除历史中的这些条目。

## 3. dateplan 与 dateplanpush 都填同一组配置

| 变量 | 值 |
|---|---|
| `FORTWO_AUTH_PROJECT_ID` | 当前正式项目 ID；本机现有清单为 `101653523865149102`，不是 appId |
| `FORTWO_SHARED_PLAN_ZONE` | 现有计划区准确名称，例如 `FortwoPlans`；保留数据 |
| `FORTWO_ENABLE_SHARED_PLAN_V1` | `true` |
| `FORTWO_ENABLE_PLAN_PUSH` | 配置完成并保存后改成 `true` |
| `FORTWO_PUSH_SERVICE_ACCOUNT_PARTS` | 工具显示的 N（数字字符串） |
| `FORTWO_PUSH_SERVICE_ACCOUNT_1` … `_N` | 对应每段的原样值 |

删除旧的 **`FORTWO_PUSH_SERVICE_ACCOUNT` 配置项**，也删除超过 N 的旧片段，避免混用或额外段。
只删除这些账号配置项，不删其他凭据、变量或数据库记录。轮换密钥时先关闭 Push/暂停定时器，再更新整组并恢复。
服务账号 `project_id` 必须与部署项目 ID 相同；不可复用隔离项目的密钥。

## 4. 创建独立补送云函数

最新本地包：`E:/desktop/Code/harmony/.crdtest/dateplanpush.zip`。
需要重建时：主仓库执行 `node tools/build-dateplan-push-worker.mjs`。这是普通 Node.js 云函数包，不是手机 App 包。

1. AGC → 开发与服务 → 正式“两人份”项目 → 云开发（Serverless）→ 云函数 → 创建函数。
2. 名称：`dateplanpush`；触发方式：**事件调用**。不要把 `dateplan` 删除或改成这个入口。
3. 运行环境选 Node.js（平台提供时选 20.x）；入口填 **`dispatch.handler`**；超时先设 **20 秒**。
4. 在函数代码步骤选择上传 ZIP，选择上述文件。根部含 `dispatch.js`、`push.js`、`push-account.js`、`identity.js`、`models.js`、`package.json`、`node_modules`，没有外层 `dateplanpush/` 文件夹。
5. 配置第 3 节的同一组环境变量；先不启用定时器，完成函数创建/保存。
6. Server SDK 需要平台注入的本项目服务凭据。**纠正旧说明：`PROJECT_CREDENTIAL` / `AGC_` 为系统保留名称，不能手工新增。**
   SDK 能读取这些名字，不等于控制台允许创建。若运行时没有项目凭据，先暂停测试并给出脱敏错误，需要再适配平台允许的注入方式。
   Push 服务账号与 AGC Server SDK 项目凭据是两套凭据，不能互换；也不在 ZIP 中放凭据文件。

控制台向导、事件调用和环境变量 JSON 编辑方式，参考[华为创建并配置函数](https://developer.huawei.com/consumer/cn/doc/AppGallery-connect-Guides/harmony-api6-create-and-config-func-0000001665128304)。

## 5. 配置补送任务专用密钥并控制台测试

此密钥不是 Push 私钥，也不是六位配对短码。只配置在 worker 和它的定时触发器中。
可本机随机生成 64 个十六进制字符并复制，不在终端打印：

```powershell
$dispatchBytes = New-Object byte[] 32
$dispatchRng = [System.Security.Cryptography.RandomNumberGenerator]::Create()
$dispatchRng.GetBytes($dispatchBytes)
$dispatchRng.Dispose()
Set-Clipboard -Value ([BitConverter]::ToString($dispatchBytes).Replace('-', '').ToLowerInvariant())
```

1. worker 新增 `FORTWO_PLAN_DISPATCH_SECRET`，粘贴这个值，保存配置。
2. 打开 worker 的控制台测试，测试输入填（占位文字换成刚才同一个值）：

```json
{"dispatchSecret":"你的64字符任务密钥"}
```

3. 正确密钥、开关和凭据有效时，返回 `{"code":"OK","providerAccepted":0}` 或非零计数。
   `0` 通常表示没有本趟需发送的事件，不证明手机已收到通知；若 Push 开关关闭，也会返回 0，先核对开关。
4. `DISPATCH_REJECTED`：任务密钥缺失/错误；`PUSH_CONFIG_INVALID`：缺段、混填、JSON/字段/私钥格式错误；
   `PUSH_PROJECT_MISMATCH`：服务账号与项目不同；`PUSH_DEFERRED`：检查项目 SDK 凭据、区名、数据库访问或运行时错误。
   只给 AI 固定错误码和不含密钥的配置名截图，不发测试输入中的密钥。

## 6. 添加定时触发器

1. 进入 **dateplanpush** 的触发器页 → 添加 → **定时/CRON**。
2. 名称可用 `plan-push-retry`，执行周期先选 **每 5 分钟**。以控制台的周期选择/表达式字段说明为准，不把 Linux 五段表达式或华为云 FunctionGraph 示例直接套到 AGC。
3. 在触发器“用户数据/输入数据”（具体名称随版本变化）填与控制台测试相同的 JSON：
   `{"dispatchSecret":"同一个64字符任务密钥"}`。
4. 当前代码接受顶层该对象/JSON 字符串，或单层 `data` / `userData` / `user_event` 包装下的对象/JSON 字符串。
   `user_event` 为防御性兼容格式，不表示已验证 AGC 当前控制台必然使用此字段；仍以实际日志 `inputShape` 为证据。
   不接受多重包装、多个冲突的输入来源或超过 4096 字节的 JSON 字符串；所有格式都必须通过同一任务密钥校验。
   **若页面没有输入数据字段、只有未明确格式的表达式，或事件包装不同，先发不含密钥的页面截图；不能删任务鉴权或添加公开 HTTP 触发器绕过。**
5. 测试通过后启用触发器，核对它绑定的是刚上传的版本及正确配置。
6. 等待至少两个周期，查 worker 日志中 `FORTWO_PLAN_PUSH` 并刷新监控调用次数。若鉴权日志一直为 `DISPATCH_REJECTED`，暂停触发器并核对任务输入，而不是打开匿名 HTTP。

5 分钟一次每天 288 次调用；费用/配额需按当前 AGC 套餐核对。补送不是定时提醒约会开始：新操作即时尝试，失败才由 worker 续发，每事件最多三次、一小时内尝试，每趟最多两条。

## 7. 用两台真机验证

两端共同计划连接正常，分别在「共同 → 计划」开启计划通知并允许系统通知/锁屏显示。
A 发新邀请，B 前台/后台/正常划走/锁屏分别测；B 确认后测 A 的确认通知。每格用新计划避免去重。
核对 `PairPlanOutbox` 状态与日志；`SENT` / `providerAccepted` 只证明平台接受，不是送达证明。
通知正文保持通用文字，不显示计划明文、时间或昵称；点击后取最新计划状态，不自动同意旧邀请。
模拟器不能代替应用关闭/锁屏的最终真机验收。停用时同时关闭两个函数的 Push 开关并暂停 cron。

## 8. 2026-10-10 日志适配修复与定时调度排查

用户提供的截图：规则为 `@every 5m`，异步调用，启用开关打开；监控仅出现两次手动调用。截图不足以确定调度未执行的根因，不能把事件解析问题说成“平台没有调用”的原因。

### 已修改的代码

- worker 优先使用本次调用第四参数的 `logger.info()`，否则使用 `globalThis.logger.info()`；仅无平台 logger 的本地运行使用 console。
- 诊断标记为 `FORTWO_PLAN_PUSH`，构建标记为 `2026-10-10-worker-diag1`。
- 每次调用有独立 `invocationId`；记录 `start`、`auth`、`config`（开关开启时）、`dispatch`、`finish`。
- `auth / DISPATCH_REJECTED` 现在也有日志，且拒绝后不访问 SDK/数据库。
- 日志只含固定状态、计数、耗时、开关布尔值和已知格式枚举，不包含 event、env、密钥、token 或原始错误。
- 日志失败不影响 callback；同步抛错和异步拒绝都安全返回 `PUSH_DEFERRED`。

官方 Node.js 日志接口及 callback 约定：[开发 Node.js 云函数](https://developer.huawei.com/consumer/cn/doc/AppGallery-connect-Guides/develop-func-nodejs-0000001713076049)。

### 用户在控制台执行

1. 暂停现有 `dateplanpush` 定时触发器，记录原规则与事件值（只保留在你的私有位置）。不要删除函数、数据区或配对。
2. 给 **dateplanpush** 重新上传 `E:/desktop/Code/harmony/.crdtest/dateplanpush.zip`，入口仍为 `dispatch.handler`。保留原环境变量与任务密钥，无需重新部署 dateplan、云数据库或手机 App。
3. 保存后核对触发器绑定的是此次手动测试的同一版本，而非旧的已发布版本/别名。平台版本配置以实际控制台为准。
4. 使用原事件值手动测试一次。日志选择业务日志，函数名 `dateplanpush`，清除版本/message 等其他过滤；时间范围覆盖测试时间，再查 `FORTWO_PLAN_PUSH`。
5. 正常应看到 build 标记，以及 start → auth/AUTHORIZED → config/VALIDATED（两个开关为 true）→ dispatch → finish/OK。`providerAccepted: 0` 仍不证明通知已送达。
6. 将原定时触发器重新启用并保存，刷新页面确认状态未回退。暂保留截图的 `@every 5m`；没有验证当前 AGC 的 Cron 字段说明前，不更换为其他平台的五段/六段表达式。
7. 记录启用时间与调用次数，在不再手动调用的情况下，经过 10–15 分钟刷新日志和监控。排除监控延迟、项目/数据处理位置/版本过滤不一致。
8. 若调用次数仍不增加且没有自动 start 日志：这是调度/绑定层的问题，不能靠 handler 更改恢复。可在保存好原事件值后，仅删除并重建**这个定时触发器**，使用控制台提供的每五分钟规则，绑定测试通过的版本；不添加匿名 HTTP 或绕过密钥。
9. 重建后仍无调用：向 AGC 提交工单，提供函数名称、项目/地域、触发器名称、版本、启用时间、监控计数与脱敏截图。不要提供服务账号 JSON、任务密钥或事件值明文。查询“触发器请求入队/积压数”指标（若页面提供）可辅助判断平台调度路径。
10. 若有自动 start 但 auth 拒绝：重新在本机复制任务密钥到事件值；据 `inputShape` 区分无效 JSON/未知包装/已支持格式。若格式不在支持列表，提供去除所有值的结构样例，不导出真实 event。

日志与调用次数属于不同证据，参考[华为监控函数说明](https://developer.huawei.com/consumer/cn/doc/appgallery-connect-Guides/quickgame-monitor-func-0000001713016837)。本次本地修复不能证明你的云端定时器或真机推送已恢复。

## 本机证据

- 最新 `node cloud-backend/test/dateplan-contract.mjs` 与 `--es5`：各 57 条通过，0 失败，真实 SDK strict/noEmit 通过；新增平台 logger、脱敏、格式与拒绝、并发 logger 隔离、同步/异步错误测试。
- `node tools/test/push-account-tool-regression.mjs`：4 条通过；使用临时生成的测试 RSA 密钥，剪贴板函数被替身覆盖，不读写你的剪贴板。
- worker 已本地重建，三个改动模块与两个云项目同源。仍需你部署 dateplan、上传 worker、配置分段与任务、真机验收。
