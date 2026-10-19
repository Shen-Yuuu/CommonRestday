# 原邀请恢复与工作排班弹窗修复

## 原因及改动

截图中的「原请求尚未确认，同时出现日程冲突」是本机重试校验返回，不代表对方拒绝，也不是云端计划创建成功。此前 11:15 的邀请在 11:26 再试时，`canArrange` 会因开始时间已过返回 false；旧逻辑却一律显示冲突。此外，计划页只展示 unresolved 布尔状态，没有把持久化 outgoing command 的原标题和时间展示出来。

- 仍优先查询原 requestId/原密文对应回执，已提交即恢复，时间已过也不阻止读取已提交结果。
- 确认仍未查到回执后，开始时间已过单独显示，未过期则重新检查日程；只排除同一 planId 的本机投影，保留其他工作、课程、个人安排及计划冲突检查。不创建新 requestId、不改原密文。
- 页面展示本机原请求的标题、完整日期时间、操作及「结果待核实」，不冒充已送达或已确认；存在待核实请求时不再展示引导重复新建的空态。
- 增加需用户确认的「关闭未提交请求」：`closeRequest` 在与 mutate 相同的 binding CAS 事务内检查原回执，没有回执才保存不可变的 `REQUEST_CLOSED` 负回执。迟到重放也只能得到已关闭。已提交时返回原回执并恢复记录，绝不在此取消已确认计划。网络未知、权限错误、会话切换、坏回执均保留本机请求。
- 关闭负回执沿用现有 V2 压缩归档/防重复证明，计入 requestCount；不增加 planCount、change sequence 或通知事件，不改变数据库 schema。

工作排班弹窗此前由 FIT_CONTENT + wrapContent Scroll + flexShrink 循环依赖测高，内容未完整展开。现在编辑器有可测量的数字高度（窗口 vp 高度的 82%，最高 720vp；日详情内扣除外层页头），列表用剩余高度滚动，页脚不收缩且保留 `bottomSafe + 12vp`。窗口变化/前台更新重新测量，不影响小内容的日详情、入口选择或其他弹窗自适应布局。

## 本地验证

- `node tools/test/real-device-feedback-regression.mjs`：PASS，含真实 UseCase/Gateway 控制逻辑、过期前先恢复回执、关闭失败不清队列、已提交关闭恢复、动态窗口/底部安全区及布局约束。
- `node tools/test/shared-plan-experience-regression.cjs`：14/0，实际读模型输出原请求、过去请求仍可核实，阻止误导性空态。
- `node cloud-backend/test/dateplan-contract.mjs`：62/0，真实服务逻辑 + 实际 SDK Long 反序列化，包含双向 close/mutate 并发、关闭回复丢失、授权/摘要不符拒绝、幂等及 CAS 反事实。
- `node cloud-backend/test/dateplan-storage-v2.mjs`：13/0，包含 151 个关闭负回执经过真实归档路径后仍阻止重放，计数不增加计划/事件。
- ES5 目标同步验证（最终结果见同目录外 `.crdtest/request-recovery-*-es5.log`）。
- `node tools/verify.mjs --steps=offline`：closed/open 均 368/0，typecheck 0 errors。
- ArkTS 技能脚本首轮失败：`10311009: Failed to execute es2abc`。停止并行构建后执行项目构建 clean，再运行同一脚本：`BUILD SUCCESSFUL`，日志 `../.crdtest/request-recovery-sheet-build2.log`。未清除用户应用数据。
- 尚未覆盖安装到用户设备验证原生弹窗，也未部署/调用线上 AGC；这些不属于本地回归证明范围。

## 你需要执行

1. 在实际关联主 App 的云工程中重新部署**整个 dateplan 云对象目录**（不是仅上传入口文件），使 `service.ts` 和 `dateplan.ts` 的新 `closeRequest` 方法生效。两份本地云工程目录均已同步，选择你平时部署主项目的那一份：
   - `E:/desktop/Code/harmony/CloudDevSpikeOfficial/CloudProgram/cloudfunctions/dateplan/`
   - `E:/desktop/Code/harmony/FortwoCloud/CloudProgram/cloudfunctions/dateplan/`
2. 覆盖安装本次重新构建的 App/在 DevEco 重新运行。**不要卸载、清数据或解除配对**，否则无法保留和核实本机原请求。本次不需要更新 CloudDB 模型/索引、环境变量、证书/Profile。此次新增代码不在 worker 依赖中，已更新上一轮 Long 修复 worker 的情况下，无需再次更新 `dateplanpush/dateplanwake`。
3. 进入「共同休时 → 计划」，应看到原请求的标题/起止时间和「结果待核实」。点「核实 / 重试」：如果原请求已提交，应恢复计划；开始时间已过，则明确提示未重新发送。此时可点「关闭未提交请求」并确认；只有云端成功安全关闭后，才能重新选择未来时间创建。若云端其实已提交，会恢复原计划而非取消。
4. 打开「两人份 → 今天 → +日程 → 工作排班」，以及「我的班表」点某天、周班表点某天，检查班次列表可滚动、保存按钮固定可见且不压系统手势条；自填分段模式亦检查返回/加入当天可见。不保存测试内容即可退出。

如果关闭操作仍失败，保留屏幕诊断；旧云对象未部署新方法时客户端不会擅自清掉记录。云端存储计数错误仍需先完成上一轮 BAD_COUNTER 修复，不能靠关闭或清表绕过。
