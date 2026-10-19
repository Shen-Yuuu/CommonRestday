# 2026-10-17 保守冗余清理清单

## 范围与结果

按用户确认的保守范围：精简界面文案，删除确认无用的代码和生产资源；保留历史设计、测试、兼容及部署材料。

检查覆盖 entry / feature / domain / data / cloud / commons 的主源码、cloud-backend、路由和资源声明，并交叉检查 tests / tools / experiments / docs 中的消费者。最终主源码扫描包含 **169 份 ArkTS/TypeScript 文件**。目录清点排除了依赖、构建输出、IDE 缓存和测试转译产物；它是引用审查，不宣称对所有动态平台行为做了自动证明。

相对本轮操作前独立备份，而不是相对包含用户大量未提交改动的 Git HEAD：

- 生产目录净减少 **316 行**源码（含废弃实现、注释和界面说明的缩减）。
- 移走 **11 个**非现用素材：生产 media 文件从 **30 → 19**。
- 原始资源总量从 **9,754,067 → 7,423,313 字节**，减少 **2,330,754 字节，约 2.22 MiB / 23.9%**。这是源资源量，不等于 HAP、安装后占用或运行内存的减少量。
- 删除 **7 个**未使用导入、**1 个**无调用方法、**4 个**未使用字符串资源；拆出旧连接 UI 和历史动作代码。
- 当前扫描无未使用命名导入、无未被生产引用的 media 候选。扫描仍列出隐私摘要组件、四个响应式订阅字段和一组背景图重复，均人工核对后保留，理由见下文。

## 界面文案改动

| 页面 / 区域 | 本轮处理 |
| --- | --- |
| 安排日程入口 | 删除“自己的日程自己决定”等引言；两个入口只保留用途，个人安排明确“仅安排自己的时间”。 |
| 个人安排表单 | 删除与入口和配对说明重复的“无需 TA 确认”等长段；“个人日程 · 点选可修改”缩为“个人日程”，编辑/删除操作不变。 |
| 工作排班编辑 | 删除每次打开都会出现的“已标记休息 / 未安排工作”说明块；保留状态按钮、清除已有班次确认、错误提示、列表及安全页脚。 |
| 周班表 | 休息行缩为“休息”；保留精简后的“未安排不占用工作时间，作息和其他日程照常计算”。 |
| 历史循环兼容提示 | 缩为“历史循环保留，仅替换已编辑日期；新班表不自动延长”，不删除兼容逻辑。 |
| 复制 / 重复班表 | 缩短样本与整周范围说明；保留“仅复制工作与休息”“不影响个人安排”“班次重叠不可保存”的边界。 |
| 常用班次页 | 两段页尾说明合并为“休息间隔不占用；修改班次不影响已排日期”。 |
| 课程导入 | 删除收起时重复展示的默认节次时刻备注（自定义后也会继续说默认，容易误导）；节次编辑提示缩为“每行对应一节课”；粘贴区标题缩短，格式示例仍在输入框。 |
| 月班表涂排 | 操作提示缩为“点按标记，再点清除 · 可拖动连续标记”；操作行为和读屏说明不变。 |
| 创建共同计划 | 规则缩为“双方确认后占用时间”；系统日历说明缩为“改期、取消会同步到系统日历”，保留开关与权限处理。 |
| 待核实请求 | 缩为“本机请求，送达结果待核实；未确认不新增占用”。保留原请求标题/时间、核实/重试、安全关闭、失败诊断；“不新增”不会暗示原已确认计划空闲。 |
| 改期与待确认卡片 | 缩短状态说明，保留“改期待确认 · 原计划有效”和待确认不占用时间的语义。 |
| 配对入口及流程 | 删除配对码上下重复的说明，集中由 waitingNote 给出当前步骤；加入确认、过期后重新生成、配对恢复与错误提示保留。 |
| 伴侣称呼 | 缩为“仅本机可见，可随时修改”；不改变昵称保存和分享规则。 |
| 首页 / 共同时间 / 日详情空态 | 删除重复的结果解释和推测，保留可执行下一步；缺 TA 数据不再重复解释“现在只显示你的日程”。 |
| 日程管理入口及统计失败 | 入口副标题缩短；失败提示缩为“统计读取失败，班表已保留，请重新进入”。 |

未压缩隐私政策/权限告知全文。与备份对比，**39 个**隐私及权限资源条目逐项完全一致。OCR 本地处理/保存前核对、危险操作确认、未知写入结果和系统日历管理边界均保留。没有删除无障碍文字来换取视觉上的简洁。

## 源码清理明细

### 删除的旧实现

- `entry/src/main/ets/component/SecurePairingSetup.ets`：旧的独立共同计划输码流程；当前 App 用 `UnifiedPairingStatus` 统一配对。全项目主源码无消费者，路由也未注册它。底层安全连接 use case 仍供统一流程使用，没有删除。
- `QuickAnswerRow.stateWord()`：没有任何调用；现有标题、状态配色、读屏分组及操作说明保持不变。
- `entry/src/main/ets/util/CompanionNarrative.ets`：已退出 App 的四段角色动作，移到历史工具目录。
- `CompanionRig.ets`：生产版仅保留 6 个正在使用的固定站位常量，移出旧耳朵/爪子裁切定义、间距函数和叙事类型依赖。
- `CompanionMotion.companionBreath()`：当前 App 已不播放整组呼吸，旧原型所需实现保存在历史快照。

### 删除的未使用导入

| 文件 | 导入 |
| --- | --- |
| ScheduleHub.ets | ownerFromParams |
| WeeklyRosterView.ets | RosterSaveResult |
| CourseImport.ets | TermConfig |
| ScheduleEditor.ets | DateLabel |
| CycleExpander.ets | MIN_PER_DAY |
| ScheduleOverviewQueryService.ets | ShiftInstance |
| ProfileSettingsService.ets | isCrossMidnight |

`string.json` 删除的未使用 key：`computing`、`cotime_empty_single`、`home_subtitle_partner`、`home_subtitle_single`。其余本轮字符串变动仅为空态文案缩短。

### 历史材料如何保留

- 旧 Motion / Narrative / Rig 快照保存于 `tools/design/legacy/`。两份原型生成器及历史叙事回归测试已调整读取路径。
- 两份历史原型 JS 重新生成前后 **SHA256 完全一致**，没有把当前 App 的眨眼动作改回旧动画。
- 11 个旧素材原封不动移到 `docs/prototype/assets/legacy-app-assets-2026-10-17/`；旧整组角色网页的图片路径已更新。头部/表情测试继续读取归档资源，仍校验尺寸、透明边缘和表情差异，没有删测试来让清理通过。
- 素材名称：`startIcon.png`、`mascot_peek.svg`、`mascot_peek_bunny.svg`、`mascot_bunny_sleep.svg`、`companions_peek_b.png`、两张 `companions_*_head.png`、布布和休休的 `face_1.svg / face_2.svg` 四张表情。
- 当前 plate、face_0/3、扒卡片兔子、确认框熊、睡眠兔子、桌面和现用启动素材均未改图像内容。

## 人工核对后保留

- `CoTimeView.colorMode / sharedPlanTick` 和 `SharedPlansPanel.recomputeTick / sharedPlanTick`：通过 `@StorageProp + @Watch` 接收主题或数据变更。名称只出现一次并不代表没有运行作用，删除会丢失刷新。
- `PrivacyDialog.ets`：当前入口使用商店托管隐私服务，但该文件仍是 `copy-audit.mjs` 与两份隐私发布文档逐项核对摘要的契约来源。保守范围下保留，不顺带重构合规审计。
- AppScope 和 entry 的同名背景 PNG：资源作用域/应用分层图标各自引用；不能只因字节相同就删除其中之一。
- 数据库迁移、旧循环/班表读取、幂等回执、失败重试、通知 worker、feature/cloud 公开导出、测试、实验、设计原稿、部署清单、构建证据和本机签名配置均保留。

## 恢复位置

本轮修改前 34 个精确生产文件已复制并校验 SHA256，位置：

`E:/desktop/Code/harmony/.crdtest/conservative-cleanup-backup-2026-10-17/`

其中包括被删除的旧连接组件、全部移出资源及旧动作源码。不需要恢复整个目录；如要撤回单项，按原相对路径取对应文件即可。当前工作区另有用户大量修改，本次未 reset、未提交，也未覆盖无关改动。历史素材在项目归档目录另有可直接使用的一份。

## 验证与使用

- `node tools/test/conservative-cleanup-regression.mjs`：通过，覆盖短文案、关键提示/操作、归档素材和生产资源边界。
- `companion-assets / companion-motion / companion-narrative / schedule-editing` 回归：通过；当前眨眼/点击、扒卡片接触位置与历史动作采样保留原校验。
- `node tools/verify.mjs --steps=offline`：closed/open 均 **368 passed / 0 failed**，typecheck **0 errors**。
- ArkTS 技能构建：完整 clean build **BUILD SUCCESSFUL**，日志 `../.crdtest/conservative-cleanup-build.log`；最终文案复核后的构建日志 `../.crdtest/conservative-cleanup-build-final.log`。
- 只读检查工具：`node tools/audit-redundancy.mjs`。输出候选及模块清点，不会自动删除。首轮和最终结果分别为 `.crdtest` 上级目录中的 `conservative-cleanup-before.json / conservative-cleanup-after.json`。

本轮没有修改服务端，无需重新部署 dateplan、worker、模型或配置。覆盖安装/重新运行主 App 即可查看。没有清应用数据、解除配对或操作线上存储。本地编译/测试不等于原生页面观感已验收，最终滚动与留白仍应在设备上复看。
