# 作息设置与系统调色直达实施计划

**Goal:** 实施已获确认的紧凑作息面板，并让班次编辑页直接打开系统调色窗口。

**Architecture:** 保留现有 `ProfileSettingsService` 和班次保存服务，改变视图与草稿接线。作息使用独立面板布局，系统时间选择的接受回调更新草稿。系统调色入口直接嵌入班次表单，移除应用内第二层选色面板。

**Tech Stack:** ArkTS、ArkUI、API 26 UIDesignKit；Node 源码回归检查、离线 Hypium、Hvigor 本机构建。

**Spec:** `docs/plans/2026-10-03-rhythm-color-picker-design.md`。用户已批准；本计划在当前会话内实施，不创建子任务、不操作设备、不暂存或提交用户的工作区。

## Task 1：先更新回归判据

文件：`tools/test/me-settings-regression.mjs`、`tools/test/schedule-editing-regression.mjs`、`tools/test/ui-refinement-regression.mjs`（原 38% 高度断言同步为已确认的 40%，其余判据不动）。

- [x] 作息检查改为 40% 独立面板、两块时间按钮、系统时间接受回调、分组数字参数、右侧紧凑选择和底部留白。
- [x] 调色检查改为系统组件位于 `shiftForm`，只写草稿，不再存在中间页及其按钮和状态。
- [x] 先运行两个检查，确认现有旧实现失败，再修改实现。分别失败于旧 38% 高度与系统调色入口仍位于中间页。

命令：`node tools/test/me-settings-regression.mjs`；`node tools/test/schedule-editing-regression.mjs`。

## Task 2：作息面板

文件：`entry/src/main/ets/view/MeView.ets`。

- [x] 独立 `rhythmSheet`，固定标题与底部操作，中间滚动。
- [x] 两个时间按钮使用 24 小时制系统弹窗；接受才更新草稿，过期回调不覆盖已关闭面板。重新打开作息或打开另一次选择器均使旧请求失效。
- [x] 两个数值参数使用整行标签、右侧数值和单位；保留原校验、保存和取消流程。
- [x] 默认最短时段在同一行右侧，选中项浅粉深字；保留历史自定义值与窄屏/大字体换行能力。

复查：时间按钮的 Builder 内直接读取 `myWake/myBed` 状态，而不是把动态时间按值传参，避免选择后时间读数不刷新的问题；回归检查已钉住。

## Task 3：系统调色直达

文件：`entry/src/main/ets/pages/ScheduleEditor.ets`。

- [x] 在颜色预设末尾直接放置 `HdsColorPicker` 原生入口；组件布局盒为 44vp，不覆盖组件自身点击。实际触摸范围仍待设备验证。
- [x] 删除 `colorPicking`、`colorDraft` 与中间页面；编辑面板仅保留班次表单和取消/保存。
- [x] 初始化与选择回调只更新班次草稿；保存期间禁用入口，关闭编辑后拒绝迟到回调。
- [x] 重跑 Task 1 检查通过。

## Task 4：本机验证与交接

- [x] `node tools/verify.mjs --steps=offline,debug,release,ohostest,perf`；不抬警告基线。两档离线均 300 passed / 0 failed，debug/release WARN 287，ohostest WARN 267，perf exit 0，ALL PASS。
- [x] 仅对本轮文件做差异与空白检查，确认无顺手改动数据/云/签名。
- [x] 新建 `docs/validation/2026-10-03-rhythm-color-picker-acceptance.md`，记录真实输出与待用户实测项。
- [x] 更新本计划完成状态，交付用户测试步骤。设备行为全部保留待验收。

验证记录：首次全量离线被 `ui-refinement-regression.mjs` 中旧 38% 断言拦下。将这一条与新需求对齐后，从头重跑五步全部通过；未删判据、未更改警告基线。

## Task 5：依据用户实测进行对齐与间距微调

本节为第二轮，用户明确要求作息再高些、标题不要贴顶、两个数据行末对齐，以及自定义颜色与预设色对齐。Task 1–4 的数字是第一轮历史记录；当前规格以设计文档为准。仍在本会话内实施，不提交 Git、不操作模拟器。

文件：`entry/src/main/ets/view/MeView.ets`、`entry/src/main/ets/pages/ScheduleEditor.ets`；测试仍为上述三个脚本。

- [x] 先将作息高度断言更新为 `46%`，内边距断言更新为 `{ left: 20, right: 20, top: 20, bottom: 24 }`；检查两项数字都为 `width(80).textAlign(TextAlign.End).padding({ left: 0, right: 0 })`，单位在左侧标签中。
- [x] 选色检查要求 `Stack({ alignContent: Alignment.Center })` 的 44vp 格子内嵌 26vp 系统按钮，无附加 `onClick` 拦截；先执行两个脚本，确认旧布局未通过新判据。分别被旧 40% 高度、没有居中 Stack 拦下。
- [x] 修改 `MeView` 的高度、顶部内边距、间距，以及两行数字布局，保持保存、取消、系统时间选择接线不变。

```ets
height: this.detailKind === 'rhythm' ? '46%' : this.partnerSheetHeight()
// rhythmSheet
Column({ space: 10 }) { /* 已有标题、滚动正文、底部按钮 */ }
  .padding({ left: 20, right: 20, top: 20, bottom: 24 })
// 两项数字在各自一行的末尾，不在右侧再放单位。
Text('睡前准备（分钟）').layoutWeight(1)
TextInput({ text: this.myWind }).width(80).textAlign(TextAlign.End).padding({ left: 0, right: 0 })
Text('往后计算（天）').layoutWeight(1)
TextInput({ text: this.myHorizon }).width(80).textAlign(TextAlign.End).padding({ left: 0, right: 0 })
```

- [x] 将当前 `HdsColorPicker` 原样移入 `Stack({ alignContent: Alignment.Center })`，仅其尺寸改为 26vp，Stack 尺寸 44vp；初始色、回调与保存闩不变，不重新加入第二层面板。
- [x] 重跑 `node tools/test/me-settings-regression.mjs`、`node tools/test/schedule-editing-regression.mjs`、`node tools/test/ui-refinement-regression.mjs`。三项均通过。
- [x] 执行 `node tools/verify.mjs --steps=offline,debug,release,ohostest`，不改基线；两档各 300 passed / 0 failed、0 type errors，debug/release WARN 287、ohostest WARN 267，`verify: ALL PASS`。在原交接文档追加本轮结果、版本变化及待用户实测项。
