# 页面精简与伴侣称呼 Implementation Plan

> **For agentic workers:** 按任务顺序在当前会话实施，不委派、不提交混合工作树。

**Goal:** 精简页面入口、保留功能，并支持云伴侣本机称呼。

**Architecture:** 复用现有读模型与 sheet。称呼按配对会话存本机设置，读取统一使用 SettingsStore；详情 UI 复用原 Builder，避免另写业务逻辑。

**Tech Stack:** ArkTS、ArkUI V1、Preferences、现有离线测试门禁。

**Spec:** docs/plans/2026-10-01-navigation-simplification-design.md

## Global Constraints

- 不操作模拟器；不删除用户数据；保留已有未提交修改。
- 不改云载荷、不产生新的代录档案，空称呼显示 TA。
- 同步错误、隐私及删除后果不得隐藏或弱化。

### Task 1: 共同页

Files: entry/src/main/ets/view/CoTimeView.ets

- [x] 三个 segment 项：`[{text:'列表'}, {text:'周历'}, {text:'计划'}]`。
- [x] 根据 segment＋viewMode 映射索引；移除二级 viewPill；回列表时设 `viewMode = VIEW_LIST`。
- [x] 检查筛选和跨页导航状态不被重置。

### Task 2: 本机称呼

Files: data/src/main/ets/settings/SettingsStore.ets；feature/src/main/ets/usecase/CommonTimeQueryService.ets；entry/src/main/ets/view/MeView.ets；tools/test/run.mjs

- [x] 添加 pairId 绑定的 `getCloudPartnerName`、`isCloudPartnerNamePrompted`、`saveCloudPartnerName`。
- [x] 统一 `getPartnerDisplayName()`：已配对读云称呼，否则读代录昵称。
- [x] 配对成功和页面重读均检查提示标记；取消也记已提示；保存失败留在表单且可重试；详情提供再次修改。
- [x] 离线测试覆盖称呼在首页与共同页读模型、取消默认 TA、代录名字不变；设备侧列入手工验收。

### Task 3: 我的页摘要与详情

Files: entry/src/main/ets/view/MeView.ets

- [x] 摘要替代常驻 partnerSyncCard／rhythmCard／dataCard 详细内容。
- [x] 单一 details sheet 按 kind 渲染现有表单，隐私 sheet 保持独立宿主。
- [x] 详情取消关闭不落库；编辑状态显式恢复；同步故障摘要保留手动重试。
- [x] 简化用户文字，去除改动区过时及重复源码注释。

### Task 4: 切侧加固

Files: entry/src/main/ets/view/ScheduleHub.ets；entry/src/main/ets/component/WeekScheduleView.ets

- [x] `pickSide` 同侧直接返回；sidePill 改单对象参数。
- [x] 周历保持网格，切侧清除旧侧图块；加载提示不替换整个图表。
- [x] `aboutToDisappear(): void { this.landing.begin(); }` 使退出组件的未完成查询不能回写。

### Task 5: 验证与交付

- [x] 执行 `node tools/verify.mjs --steps=offline,debug,release,ohostest`；修复新增错误，不提高告警基线。
- [x] 输出本轮文件清单和设备手工步骤，明确闪烁尚未设备复验。

### Task 6: 用户指定的半屏作息与计算选项展开（2026-10-01）

Files: `entry/src/main/ets/view/MeView.ets`；`tools/test/me-settings-regression.mjs`；`tools/test/run.mjs`。Spec 为设计文档本轮新增三条交互。继续当前会话，不委派、不提交 WIP；writing-plans 的执行子技能本会话未提供，按本节逐项实施。

- [x] 新建结构回归，先在旧代码上验证失败（冗余云说明/折叠仍存在），实现后通过：

```js
assert.doesNotMatch(me, /配对同步需要云服务能力|更多计算设置|this\.advanced\b|advancedHead/);
assert.match(me, /detents: this\.detailKind === 'rhythm' \? \[SheetSize\.MEDIUM\] : \[SheetSize\.LARGE\]/);
assert.match(me, /preferType: this\.detailKind === 'rhythm' \? SheetType\.BOTTOM : undefined/);
```

- [x] 删除旧说明、advanced 状态/重置/折叠 Builder；展开查看摘要与原表单（advancedForm 改名 calculationForm），补最短共同时段标签。保存仍传 `horizonText: this.myHorizon, minSlotMin: this.myMinSlot`，取消仍 reloadMyParams，不更改持久化代码。
- [x] 详情 sheet 按 kind 指定单一高度：

```ts
detents: this.detailKind === 'rhythm' ? [SheetSize.MEDIUM] : [SheetSize.LARGE],
preferType: this.detailKind === 'rhythm' ? SheetType.BOTTOM : undefined,
dragBar: this.detailKind === 'rhythm', showClose: false,
```

保留 detailsSheet 的标题行 + Scroll.layoutWeight(1)；其他面板/绑定节点不变。
- [x] runner 引入新结构回归，offline closed/open 各 271 passed / 0 failed；低内存参数 clean debug 出包 BUILD SUCCESSFUL / WARN 287，基线未调整；修改文件 diff --check 通过。
- [x] 记录本机结果与用户半屏/编辑保存/取消复验步骤。不操作模拟器；不将上一轮标题闪烁判定为已修复。
- [ ] 用户运行确认半屏、内滚动、键盘输入与关闭，不遮挡保存/取消；伴侣与隐私面板没有被改成半屏。
