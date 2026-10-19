# Schedule Editing Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [x]`) syntax for tracking.

**Goal:** 实现已确认的局部视觉调整、循环星期、选日改班和弹窗班次编辑。

**Architecture:** 轮转与星期口径放 domain；持久化通过 ScheduleRepo 和事务迁移。页面只管理未保存草稿和展示状态，写入仍经 ScheduleCommandService 统一重算。颜色与班次编辑共用单一 sheet。

**Tech Stack:** API 26 ArkTS/ArkUI、UIDesignKit HdsColorPicker、RDB、Hypium 离线 runner、Hvigor。

**Spec:** `docs/plans/2026-10-03-schedule-editing-design.md`

## Global Constraints

- API 26；不操作模拟器、安装、卸载、清数据或部署云服务。
- 不改桌面图标、不覆盖原图，不加启动等待。
- 周一到周日低七位；默认 127；自然日推进；单日覆盖优先。
- 页头只改视觉缩放，不改占位高度，不在 HomeView 读取滚动偏移。
- 未选星期不影响课程或计划；不改云载荷结构。
- 不自动提交、暂存或撤销其他 WIP。执行技能未安装，本次按任务内联实施、自己复核，不派子代理。

---

### Task 1: 星期规则与回归

**Files:** `domain/src/main/ets/model/Types.ets`、`domain/src/main/ets/expand/CycleExpander.ets`、`domain/src/test/CycleExpanderTest.ets`

**Interfaces:** `CycleTemplate.weekdaysMask?: number`；`cycleWeekday(epochDay: number): number`；`cycleWeekdaysMask(mask?: number): number`；`cycleAppliesOn(tpl: CycleTemplate, epochDay: number): boolean`。

- [x] 增加测试：2026-09-28 周一起点，`['A','A','B','']`、mask=31，周末不生成、下周一仍处于序列第 4 项；周末覆盖 `X` 仍生成。缺字段与 127 结果完全相同。
- [x] 运行 `node tools/test/run.mjs` 验证新增规则；未另留存 domain 红轮，静态接线的初始失败记录见 Task 3。
- [x] 使用以下规则，两条读路径都调用同一判断：

```ts
const weekday = ((epochDay + 3) % 7 + 7) % 7 + 1;
const applies = (cycleWeekdaysMask(tpl.weekdaysMask) & (1 << (weekday - 1))) !== 0;
```

- [x] 验证负 epochDay、空选择、非法 mask 回退每天、覆盖为休息、预览与展开逐日一致。

### Task 2: v4 本地持久化

**Files:** `data/src/main/ets/db/MigrationRunner.ets`、`data/src/main/ets/repo/ScheduleRepo.ets`、`entry/src/test/DbMigrationTest.ets`、`entry/src/ohosTest/ets/test/UpgradeMigrationTest.ets`

**Interfaces:** `SCHEMA_VERSION=4`；既有 repo 签名不变；`getTemplate` 返回归一化 mask。

- [x] 增加 v3 补列、v4 幂等、补列异常保留旧版本、v3 重建之后再补列的离线断言。
- [x] 新装 DDL 与 v4 补列共享同一字段定义；保留历史 v3 重建列清单，避免从旧库 SELECT 不存在的新列。

```sql
ALTER TABLE cycle_template ADD COLUMN weekdays_mask INTEGER NOT NULL DEFAULT 127
```

- [x] `saveTemplate` 将删旧／插新放进已有 `runInTransaction`，插入、查询 `weekdays_mask`；旧记录默认 127。
- [x] 增加真实 RDB 测试，保存两侧不同 mask 读回并恢复原模板。只编译、不执行设备测试。
- [x] 运行离线全量确认迁移及现有恢复、owner 隔离断言未退化。

### Task 3: 循环编辑 UI

**Files:** `entry/src/main/ets/pages/CycleEditor.ets`、`tools/test/schedule-editing-regression.mjs`、`tools/test/run.mjs`

**Interfaces:** 页面 `weekdaysMask=127`；`previewTemplate(): CycleTemplate`；读回、取消清空、保存均带 mask。

- [x] 增加静态检查，要求星期选择、两周预览、空星期禁止保存，先跑红。
- [x] 每天=127，工作日=31，周末=96；周几点击切换对应 bit，选中状态可朗读。
- [x] 保存空 mask 提示“请至少选择一天”；14 格从 anchor 开始，以 `cycleShiftAt` 显示班次，未知 id 显示已删除班次。
- [x] 旧模板、删除取消和清空后新增默认每天；重算仍经原命令入口。

### Task 4: 选日期临时调整

**Files:** `entry/src/main/ets/component/DayShiftSheet.ets`、`tools/test/schedule-editing-regression.mjs`

**Interfaces:** `@Prop epochDay` 保留作为入口日期；新增内部 `selectedDay`、`datePick` 和 `datePicking`；`LatestLanding` 拦截过时读数。

- [x] 静态断言不再直接向 `this.epochDay` 写班次，读写均取 selectedDay，保存中禁选日期。
- [x] 日期模式与班次模式同一面板，DatePicker 2020～2035；确认才改 selectedDay，取消不改。
- [x] 点击今天刷新今天；watch owner/epochDay 时重置目标并重新查询；离页废弃未完成查询。
- [x] load/catch/finally 只允许最新查询落状态；write/clearOverride 在发起时固定 day 和 owner。

### Task 5: 班次弹窗与调色草稿

**Files:** `entry/src/main/ets/pages/ScheduleEditor.ets`、`tools/test/schedule-editing-regression.mjs`

**Interfaces:** `editorVisible`、`colorPicking`、`colorDraft`、`pickerInitialColor`、`submitting`；`closeEditor()`、`openColorPicker()`、`applyColor()`。

- [x] 回归断言只有一处 bindSheet，List 中无编辑器，onColorSelected 不关闭／不直接写 color。
- [x] 打开编辑装载草稿再显示 72% sheet；编辑 Scroll、保存／取消固定，已有班次删除需确认。
- [x] 自定义颜色打开时复制 color 到两份状态；初始颜色不随回调变动，回调只写 colorDraft；返回丢弃草稿，使用才写 color。
- [x] 提交闩覆盖保存和删除；关闭与输入在提交中禁用，失败不关 sheet。所有色块热区至少 44vp，Flex 可换行。

### Task 6: 日期缩放、共享底色与作息单排

**Files:** `commons/src/main/ets/util/ScrollHeaderMotion.ets`、`entry/src/main/ets/component/FadingHeader.ets`、`entry/src/main/ets/view/HomeView.ets`、`entry/src/main/ets/view/MeView.ets`、`entry/src/main/ets/theme/DesignTokens.ets`、两档 `element/color.json`、`tools/test/contrast-audit.mjs`、`tools/test/schedule-editing-regression.mjs`

- [x] 共用 `ScrollHeaderMotion.titleScale(offset, reduceMotion)`；新日期组件作为叶节点以 ObjectLink 读 offset，Home 只传对象。48vp 固定布局，用 scale 改绘制尺寸。
- [x] 新 `share_selected_bg`：浅色 `#F8DEE8`、深色 `#472C42`；选中行只用专用令牌。检查前景 text_accent、text_secondary 对新底色 >=4.5；该行选中说明改用 textSecondary，不改其他行的全局令牌。
- [x] 作息 label 与 Flex 选择同排，选项布局自适应；保留 minSlotChoices 的历史自定义值，不降低热区。
- [x] 运行 header、motions、contrast 和新增静态回归，确认没有全局布局动画。

### Task 7: 原生启动页圆角资产

**Files:** 新 `tools/design/round-start-icon.ps1`、新 `entry/src/main/resources/base/media/start_icon_rounded.png`、`entry/src/main/resources/base/profile/start_window.json`、`entry/src/main/module.json5`、`tools/test/start-window-regression.mjs`

- [x] 查看当前 jim1_resized.png，使用内置 imagegen 两次尝试非覆盖式圆角版本；均因透明边缘杂点未采用。用户后续明确同意本地纯圆角裁剪，改用确定性像素 alpha 掩膜，只改变四角透明度。
- [x] 检查透明四角与标识，独立 PNG 验证全图 RGB 不变；增强配置和旧版 startWindowIcon 同时引用派生图；app.icon 与 ability.icon 保留。
- [x] 修改启动回归要求新引用、原文件仍在、品牌字标不变、首页无延时。

### Task 8: 综合验收与用户交接

**Files:** 新 `docs/validation/2026-10-03-schedule-editing-acceptance.md`

- [x] `node tools/verify.mjs --steps=offline,debug,release,ohostest,perf`，收尾后再次 ALL PASS，退出码 0；两档各 296 passed / 0 failed、0 type error，WARN 287／287／267，不调宽 baseline。
- [x] 使用 `git -c core.whitespace=cr-at-eol diff --check -- <本轮文件>`，逐文件核对保留原有 WIP；新增文件另做逐行空白检查通过。
- [x] 写设备清单：滚动日期、深浅色选择、作息单排、星期预览、切日改班、班次保存取消、连续拖动调色。区分编译与真正上屏证据；圆角未改，不登记上屏通过。
- [x] 给出课程导入分步建议，不宣称已实现课表改造。

### Task 9: 用户要求精简循环模板（替代 Task 3 的预览布局）

**Files:** `entry/src/main/ets/pages/CycleEditor.ets`、`tools/test/schedule-editing-regression.mjs`、`docs/plans/2026-10-03-schedule-editing-design.md`、`docs/validation/2026-10-03-schedule-editing-acceptance.md`。

**Interfaces:** 保留 `weekdaySettings()`、`weekdaysMask: number`、`save(): Promise<void>`，删除页面专用 `previewTemplate()`、`previewDays()`、`previewLabel(day: number)`、`templatePreview()`；领域层预览／展开方法不变。

**约束：** 用户已指定删除预览和七日单排，不另换风格；不改数据库、云协议、星期选择语义和自然日轮转；不操作模拟器，不提交、回退或覆盖其他 WIP。

- [x] 更新原有静态回归：删除要求预览存在的两个断言，改为要求预览代码缺席、星期等宽单排，保留星期读写与空选择校验。

```js
assert.doesNotMatch(cycle, /templatePreview|previewTemplate|previewDays|previewLabel|未来两周|cycleShiftAt/);
const weekdays = cycle.slice(cycle.indexOf('  weekdaySettings()'), cycle.indexOf('  build()'));
assert.match(weekdays, /Row\(\{ space: 4 \}\) \{\s*ForEach\(\['一', '二', '三', '四', '五', '六', '日'\]/);
assert.match(weekdays, /Button\('周' \+ label\)\s*\.layoutWeight\(1\)\.height\(44\)/);
assert.match(weekdays, /\.padding\(\{ left: 0, right: 0 \}\)/);
assert.doesNotMatch(weekdays, /FlexWrap|minWidth: 44/);
assert.match(weekdays, /this\.weekdaysMask = this\.weekdaysMask \^ \(1 << i\)/);
```

- [x] 运行 `node tools/test/schedule-editing-regression.mjs`，确认旧页面因预览仍存在而失败，退出码 1。
- [x] 移除 `cycleShiftAt` 页面导入、三项预览辅助方法、预览 builder 和 build 中调用；星期行使用下列布局，选中配色、可访问性与点击处理保持原样。

```ts
Row({ space: 4 }) {
  ForEach(['一', '二', '三', '四', '五', '六', '日'], (label: string, i: number) => {
    Button('周' + label)
      .layoutWeight(1).height(44)
      .padding({ left: 0, right: 0 })
      .fontSize(DesignTokens.fontCaption)
      .fontColor((this.weekdaysMask & (1 << i)) !== 0 ? DesignTokens.heroText : DesignTokens.textPrimary)
      .backgroundColor((this.weekdaysMask & (1 << i)) !== 0 ? DesignTokens.primary : DesignTokens.fillWeak)
      .accessibilityChecked((this.weekdaysMask & (1 << i)) !== 0)
      .accessibilityText('周' + label + ((this.weekdaysMask & (1 << i)) !== 0 ? '，已选择' : '，未选择'))
      .enabled(!this.submitting)
      .onClick(() => { this.weekdaysMask = this.weekdaysMask ^ (1 << i); })
  }, (label: string) => label)
}.width('100%')
```

- [x] 运行同一静态回归通过；`node tools/verify.mjs --steps=offline,debug` 退出码 0、ALL PASS：两档离线各 300 passed / 0 failed、0 type error，debug WARN 287（基线 289）。本次纯布局不重复 release／ohosTest 编译，不替代设备验收。
- [x] 实际结果写入验收记录，本轮文件空白检查通过；交用户重新 Run 后检查预览消失、七日单排、点选与保存读回（设备效果仍待确认）。

### Task 10: 日详情／改单日弹窗内容高度适配

**Files:** `entry/src/main/ets/component/DayDetailSheet.ets`、`entry/src/main/ets/component/DayShiftSheet.ets`、`entry/src/main/ets/view/CoTimeView.ets`、`entry/src/main/ets/view/ScheduleHub.ets`、`tools/test/schedule-editing-regression.mjs`、本设计与验收记录。

**Interfaces:** 保留 `DayDetailSheet`、`DayShiftSheet` 所有入参和写操作；仅更改布局。计划时间条与 `PLAN_KINDS` 只核实、解释，不扩充类型或另造设置入口。

**约束：** API 26；系统 `SheetSize.FIT_CONTENT` 自适应内容，`LayoutPolicy.wrapContent`（基础组件自 API 20 支持）取消内部全屏撑高。加载、失败、详情、改班和日期选择均应可达；内容多时仍滚动。只改日详情／改班 sheet，不改创建计划、作息或其他弹窗；不操作设备、不清数据、不部署云、不提交 WIP。

- [x] 增加接线回归，覆盖宿主 FIT_CONTENT、内部无百分百高度和撑满权重、长正文可收缩滚动、日期选择不再用权重撑满。

```js
const detail = read('entry/src/main/ets/component/DayDetailSheet.ets');
const detailBody = detail.slice(detail.indexOf('  build()'), detail.indexOf('  windowRow('));
assert.doesNotMatch(detailBody, /\.height\('100%'\)|\.layoutWeight\(1\)/);
assert.match(detailBody, /\.height\(LayoutPolicy\.wrapContent\)\s*\.flexShrink\(1\)/);
const dayLayout = day.slice(day.indexOf('  dateSelection()'));
assert.doesNotMatch(dayLayout, /\.height\('100%'\)/);
const dayDatePicker = dayLayout.slice(dayLayout.indexOf('      DatePicker('), dayLayout.indexOf('      Row('));
assert.doesNotMatch(dayDatePicker, /\.layoutWeight\(1\)/);
assert.doesNotMatch(dayLayout.slice(dayLayout.indexOf('  build()')), /\.layoutWeight\(1\)/);
assert.match(dayLayout, /Scroll\(\)[\s\S]*\.height\(LayoutPolicy\.wrapContent\)\.flexShrink\(1\)/);
```

- [x] `node tools/test/schedule-editing-regression.mjs` 先因旧全屏布局失败（退出码 1），实施后通过。
- [x] 两个宿主的日详情／改班 sheet 设为下列单档自适应；创建计划的 MEDIUM／LARGE 档保持原样。

```ts
height: SheetSize.FIT_CONTENT,
detents: [SheetSize.FIT_CONTENT],
preferType: SheetType.BOTTOM,
```

- [x] `DayDetailSheet` 根 Column 设置 `.height(LayoutPolicy.wrapContent)`；页头 `.flexShrink(0)`。编辑容器与概览 Scroll 均改为 `.height(LayoutPolicy.wrapContent).flexShrink(1)`。`DayShiftSheet` 根 Scroll 同样自适应；日期模式移除 DatePicker 的 `.layoutWeight(1)` 和根 `.height('100%')`，让滚轮与操作栏自然撑高。保留原取数、提交闩、覆盖读写、关闭与返回逻辑。
- [x] 接线回归通过；最终 `node tools/verify.mjs --steps=offline,debug` 退出码 0、ALL PASS，两档各 300 passed / 0 failed、0 type error，debug WARN 287（基线 289）。设备未操作，交用户复测加载后的弹窗高度、改班返回、日期选择、内容多时的滚动。

**依据：** 用户提供的两张大留白截图；本机 SDK `component/common.d.ts` 的 `SheetSize`／`LayoutPolicy` 声明；[华为半模态弹窗高度说明](https://developer.huawei.com/consumer/cn/doc/doccenter-dev-faq/faqs-arkui-1039)。不用滚动偏移或内容测量回调持续写高度，避免再次引入布局反馈闪烁。
