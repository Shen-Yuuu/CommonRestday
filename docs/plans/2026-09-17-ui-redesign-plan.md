# UI 情感化温度风重构 — 实施计划

> **For agentic workers:** 按任务逐个执行，步骤使用 `- [ ]` 复选框跟踪。每个任务完成后必须通过验证步骤再进入下一任务。

**Goal:** 按 `docs/plans/2026-09-17-ui-redesign-design.md` 完成 4-Tab 导航归并与情感化温度风视觉重构。

**Architecture:** 先铺设计系统资源层（新增颜色资源 + 暗色对），再按"共同页合并 → Index 去 Tab → 首页重排 → 列表行升级 → 班表/我的重排 → 半模态与编辑页轻改"顺序推进，每步保持可编译。功能逻辑、数据流、领域层零改动。

**Tech Stack:** ArkTS（API ≤ 21 组件）、ArkUI（SymbolGlyph/Chip/Refresh/QRCode）、base/dark 双 color.json 资源机制。

**Spec:** `docs/plans/2026-09-17-ui-redesign-design.md`

## Global Constraints

- ArkTS 严格模式：禁 any/unknown、禁 `as` 断言（既有存量除外）、对象字面量需显式类型、禁动态属性访问
- 组件 API 门槛 ≤ API 21（compatibleSdkVersion "6.0.1(21)"）：可用 SymbolGlyph(11)/Chip(11)/Refresh(8)/SubHeader(10)/linearGradient/swipeAction；禁 HDS 系 23+/26+ 组件
- 每个新增颜色资源必须同时写入 `base/element/color.json` 与 `dark/element/color.json`
- 不改业务逻辑/数据流/领域层；`domain` 模块单测必须保持 67/67 绿
- 本目录**非 git 仓库**：所有"提交"步骤省略，以构建通过代替
- 验证命令：
  - 静态检查：对改动的 .ets 文件运行 `arkts_check`（工具）
  - 构建：`build_project`（工具，模块 `entry`，debug）
  - 单测：`D:\local\DevEcoStudio\tools\hvigor\bin\hvigorw.bat test --mode module -p module=domain@default -p product=default`（仅最终任务需要）
- SymbolGlyph 的 `.fontColor()` 参数是**数组**：`.fontColor([$r('app.color.x')])`
- `sys.symbol.*` 名称拼写错误不会在编译期报错，只在运行时渲染为空白；本计划中已用过的 `sys.symbol.chevron_left` / `chevron_right` 可直接用，其余新图标使用前先执行 `devecocli docs search <图标名>` 核实，查不到就改用已验证图标或色点方案
- 卡片新范式（本计划统一引用，下称**新卡片样式**）：`borderRadius(20)` + `backgroundColor($r('app.color.card_bg'))` + 去掉 `.border(...)` + `.shadow({ radius: 16, color: $r('app.color.shadow_soft'), offsetX: 0, offsetY: 4 })`
- 渐变主卡范式（下称**渐变卡**）：`borderRadius(24)` + `.linearGradient({ angle: 135, colors: [[$r('app.color.sunset_from'), 0], [$r('app.color.sunset_to'), 1]] })`，文字用 '#FFFFFF'（标题）与 '#FFFFFFB8'（辅助），不随深浅色变化

---

### Task 1: 设计系统资源层

**Files:**
- Modify: `entry/src/main/resources/base/element/color.json`
- Modify: `entry/src/main/resources/dark/element/color.json`

**Interfaces:**
- Produces: 资源名 `page_bg_warm` / `sunset_from` / `sunset_to` / `shadow_soft`（后续所有任务引用）；`start_window_background` 改为暖底（启动闪屏与页面底色一致）

- [ ] **Step 1: base/element/color.json 追加 4 个资源并调整启动底色**

在 `"color"` 数组末尾（`partner_busy` 之后）追加：

```json
    {
      "name": "page_bg_warm",
      "value": "#FAF7F5"
    },
    {
      "name": "sunset_from",
      "value": "#D24A7E"
    },
    {
      "name": "sunset_to",
      "value": "#E8833A"
    },
    {
      "name": "shadow_soft",
      "value": "#14000000"
    }
```

同时把 `start_window_background` 的值从 `#FFFFFF` 改为 `#FAF7F5`。

- [ ] **Step 2: dark/element/color.json 追加同名 4 个资源**

在 `"color"` 数组末尾追加：

```json
    {
      "name": "page_bg_warm",
      "value": "#171412"
    },
    {
      "name": "sunset_from",
      "value": "#C4537F"
    },
    {
      "name": "sunset_to",
      "value": "#C96A33"
    },
    {
      "name": "shadow_soft",
      "value": "#00000000"
    }
```

同时把 `start_window_background` 的值从 `#141414` 改为 `#171412`。

- [ ] **Step 3: 构建验证资源合法**

Run: `build_project`（entry, debug）
Expected: SUCCESS（资源 JSON 语法错误会在此暴露）

---

### Task 2: 共同页合并（窗口 | 计划 分段）

**Files:**
- Modify: `entry/src/main/ets/view/PlansView.ets`
- Modify: `entry/src/main/ets/view/CoTimeView.ets`

**Interfaces:**
- Produces: `PlansView` 新增两个属性：`embedded: boolean = false`（嵌入态：隐藏页头、内边距适配）、`onGoWindow: (() => void) | null = null`（空态引导回调；null 时回退 `navToCoTime()`）。CoTimeView 新增常量 `SEG_WINDOW = 'window'` / `SEG_PLANS = 'plans'` 与状态 `@State pageSegment: string`。
- Consumes: Task 1 无依赖（本任务不动颜色，样式升级在 Task 5）。

- [ ] **Step 1: PlansView 增加嵌入支持**

`PlansView.ets` 修改点：

1. struct 内新增属性（放在 `@State plans` 之前）：

```typescript
  // 嵌入态标记：被 CoTimeView 分段嵌入时隐藏页头（分段标签已表达"计划"语义）
  embedded: boolean = false;
  // 空态引导回调：嵌入时由宿主切换到"窗口"分段；独立使用时回退 tab 跳转
  onGoWindow: (() => void) | null = null;
```

2. `build()` 中标题 ListItem 改为条件渲染：

```typescript
      if (!this.embedded) {
        ListItem() {
          Text('共同计划').fontSize(22).fontWeight(FontWeight.Bold)
            .margin({ top: 16, bottom: 4 }).width('100%')
        }
      }
```

3. 空态按钮点击逻辑改为：

```typescript
            Button('去共同时间页选一个窗口').backgroundColor($r('app.color.brand_pink'))
              .onClick(() => {
                if (this.onGoWindow != null) {
                  this.onGoWindow();
                } else {
                  navToCoTime();
                }
              })
```

4. List 根节点 `.padding(16)` 改为 `.padding(this.embedded ? 0 : 16)`（嵌入时由宿主统一控制留白）。

- [ ] **Step 2: CoTimeView 顶部加分段控件并嵌入 PlansView**

`CoTimeView.ets` 修改点：

1. 常量区追加：

```typescript
const SEG_WINDOW = 'window';
const SEG_PLANS = 'plans';
```

2. struct 新增状态：`@State pageSegment: string = SEG_WINDOW;`

3. `build()` 整体重构为"固定头部 + 分段内容"结构（两个 `bindSheet` 移到最外层 Column 上）：

```typescript
  build() {
    Column() {
      // 页头：标题 + 副标题
      Text('共同时间').fontSize(22).fontWeight(FontWeight.Bold)
        .margin({ top: 16 }).width('100%')
      Text(this.hasPartner ? $r('app.string.cotime_subtitle_partner') : $r('app.string.cotime_subtitle_single'))
        .fontSize(12)
        .fontColor(this.hasPartner ? $r('app.color.brand_pink') : $r('app.color.text_tertiary')).width('100%')

      // 分段控件：窗口 | 计划（胶囊双选）
      Row({ space: 0 }) {
        Text('窗口').fontSize(14).textAlign(TextAlign.Center)
          .layoutWeight(1).padding({ top: 8, bottom: 8 })
          .borderRadius(10)
          .backgroundColor(this.pageSegment === SEG_WINDOW ? $r('app.color.brand_pink') : Color.Transparent)
          .fontColor(this.pageSegment === SEG_WINDOW ? '#FFFFFF' : $r('app.color.text_secondary'))
          .onClick(() => {
            this.pageSegment = SEG_WINDOW;
          })
        Text('计划').fontSize(14).textAlign(TextAlign.Center)
          .layoutWeight(1).padding({ top: 8, bottom: 8 })
          .borderRadius(10)
          .backgroundColor(this.pageSegment === SEG_PLANS ? $r('app.color.brand_pink') : Color.Transparent)
          .fontColor(this.pageSegment === SEG_PLANS ? '#FFFFFF' : $r('app.color.text_secondary'))
          .onClick(() => {
            this.pageSegment = SEG_PLANS;
          })
      }
      .width('100%').padding(4).borderRadius(14).backgroundColor($r('app.color.fill_soft'))
      .margin({ top: 4 })

      // 分段内容
      if (this.pageSegment === SEG_WINDOW) {
        this.windowBody()
      } else {
        Column() {
          PlansView({
            embedded: true,
            onGoWindow: () => {
              this.pageSegment = SEG_WINDOW;
            }
          })
        }
        .width('100%').layoutWeight(1)
      }
    }
    .width('100%').height('100%')
    .bindSheet($$this.dayVisible, this.daySheet(), {
      detents: [SheetSize.LARGE],
      dragBar: false,
      showClose: false,
      blurStyle: BlurStyle.Thick
    })
    .bindSheet($$this.sheetVisible, this.detailSheet(), {
      detents: [SheetSize.MEDIUM, SheetSize.LARGE],
      dragBar: false,
      showClose: false,
      blurStyle: BlurStyle.Thick
    })
  }
```

4. 把原 `build()` 里 `Refresh(...) { Scroll() { Column(...) { ...原内容（视图切换 chips + listView/monthView）... } } }` 整体抽成新 `@Builder windowBody()`，Refresh 节点加 `.layoutWeight(1)`，Column 的 `.padding(16)` 保留；删除其中的页头 Text（已移到外层）：

```typescript
  /** 窗口分段主体：Refresh 包裹的 列表/月历 双视图。 */
  @Builder
  windowBody() {
    Refresh({ refreshing: $$this.refreshing, offset: 64, friction: 10 }) {
      Scroll() {
        Column({ space: 12 }) {
          // 视图切换（列表 / 月历）chips —— 原有 Row 原样保留
          ...
          if (this.viewMode === VIEW_LIST) {
            this.listView()
          } else {
            this.monthView()
          }
        }
        .padding(16)
        .width('100%')
      }
      .width('100%').height('100%')
      .align(Alignment.Top)
    }
    .onRefreshing(() => this.refresh())
    .layoutWeight(1)
    .width('100%')
  }
```

（`...` 处为原文照搬的"列表/月历"Chip Row，见 CoTimeView.ets:346-369。）

5. 文件头部追加 import：`import { PlansView } from './PlansView';`

- [ ] **Step 3: 静态检查 + 构建验证**

Run: `arkts_check`（CoTimeView.ets, PlansView.ets）→ `build_project`
Expected: 无 ERROR；此时 App 为"5 Tab + 计划同时可从共同页进入"的中间态，功能完好

- [ ] **Step 4: 手工冒烟（可选，若有设备）**

验证：共同页"窗口|计划"切换、计划空态按钮切回窗口分段、窗口/月历切换、两个半模态正常弹出。

---

### Task 3: Index 4-Tab 重构

**Files:**
- Modify: `entry/src/main/ets/pages/Index.ets`

**Interfaces:**
- Consumes: Task 2（计划已可在共同页访问，删除 Tab 不丢失功能）
- Produces: Tab 序列 同休/共同/班表/我的（索引 0-3）；`navToMe()` 目标索引 3

- [ ] **Step 1: 删除计划 Tab、调整索引**

1. 删除 `import { PlansView } from '../view/PlansView';` 与对应 `TabContent`（原 `.tabBar(this.tabLabel('计划', 3))` 整块）。
2. `onNavToMe()` 中 `this.activeTab = 4;` 改为 `this.activeTab = 3;`。

- [ ] **Step 2: tabLabel 加图标**

`tabLabel` 改为带 SymbolGlyph 的版本（图标先核实：执行 `devecocli docs search house heart calendar person symbol`，确认以下名称存在；查不到的用 `chevron_left` 等已验证图标替换或去掉图标）：

```typescript
  @Builder
  tabLabel(icon: Resource, text: string, idx: number) {
    Column({ space: 2 }) {
      SymbolGlyph(icon)
        .fontSize(22)
        .fontColor(this.activeTab === idx ? [$r('app.color.brand_pink')] : [$r('app.color.text_tertiary')])
      Text(text)
        .fontSize(11)
        .fontColor(this.activeTab === idx ? $r('app.color.brand_pink') : $r('app.color.text_tertiary'))
        .fontWeight(this.activeTab === idx ? FontWeight.Bold : FontWeight.Normal)
    }
    .width('100%')
    .justifyContent(FlexAlign.Center)
  }
```

四个 tabBar 调用改为（图标名以 Step 2 核实结果为准）：

```typescript
        .tabBar(this.tabLabel($r('sys.symbol.house'), '同休', 0))
        .tabBar(this.tabLabel($r('sys.symbol.heart'), '共同', 1))
        .tabBar(this.tabLabel($r('sys.symbol.calendar'), '班表', 2))
        .tabBar(this.tabLabel($r('sys.symbol.person'), '我的', 3))
```

Tabs 的 `.barHeight(56)` 改为 `.barHeight(64)`。

- [ ] **Step 3: 根容器铺暖底**

最外层 `.width('100%').height('100%')` 的 Stack 追加 `.backgroundColor($r('app.color.page_bg_warm'))`。

- [ ] **Step 4: 静态检查 + 构建验证**

Run: `arkts_check`（Index.ets）→ `build_project`
Expected: SUCCESS，无 ERROR

---

### Task 4: 首页 HomeView 重排

**Files:**
- Modify: `entry/src/main/ets/view/HomeView.ets`

**Interfaces:**
- Consumes: Task 1 资源（`page_bg_warm`/`sunset_*`）；`SettingsStore.getPartnerProfile()`（data 模块既有 API，取伴侣昵称）
- Produces: 无对外接口（纯展示层）

- [ ] **Step 1: 状态区新增伴侣昵称与问候语**

struct 新增：

```typescript
  @State partnerNick: string = '';
```

`applyFromCache()` 中 `this.hasPartner = ...` 之后追加：

```typescript
      try {
        const profile = SettingsStore.getPartnerProfile();
        this.partnerNick = profile != null ? profile.nick : '';
      } catch (e) {
        this.partnerNick = '';
      }
```

import 区追加 `SettingsStore`（from 'data'，与 `ScheduleRepo` 合并到既有 import）。

新增问候方法：

```typescript
  /** 按小时段问候语。 */
  greeting(): string {
    const h = new Date().getHours();
    if (h >= 5 && h < 11) {
      return '早上好';
    }
    if (h < 13) {
      return '中午好';
    }
    if (h < 18) {
      return '下午好';
    }
    if (h < 23) {
      return '晚上好';
    }
    return '夜深了';
  }
```

- [ ] **Step 2: build() 重排为问候区 + 渐变主卡 + 次级卡**

`build()` 中 `if (this.loading) ... else ...` 的 else 分支整体替换为：

```typescript
        } else {
          // 渐变主卡：今晚结论（白字，固定渐变不随深浅色变化）
          Column({ space: 8 }) {
            Text('今晚').fontSize(13).fontColor('#FFFFFFB8')
            Text(this.tonight).fontSize(20).fontWeight(FontWeight.Medium).fontColor('#FFFFFF')
          }
          .alignItems(HorizontalAlign.Start)
          .width('100%')
          .padding(20)
          .borderRadius(24)
          .linearGradient({
            angle: 135,
            colors: [[$r('app.color.sunset_from'), 0], [$r('app.color.sunset_to'), 1]]
          })
          .shadow({ radius: 16, color: $r('app.color.shadow_soft'), offsetX: 0, offsetY: 4 })

          // 次级卡：下一个完整同休日 + 出行窗口
          Column({ space: 12 }) {
            Row({ space: 10 }) {
              Column().width(4).height(34).borderRadius(2)
                .linearGradient({
                  angle: 180,
                  colors: [[$r('app.color.accent_purple'), 0], [$r('app.color.brand_pink'), 1]]
                })
              Column({ space: 2 }) {
                Text('下一个完整同休日').fontSize(12).fontColor($r('app.color.text_tertiary'))
                Text(this.nextFullDay === '' ? '未来视界内暂无，去调整班表或参数' : this.nextFullDay)
                  .fontSize(15).fontWeight(FontWeight.Medium).fontColor($r('app.color.text_primary'))
              }.alignItems(HorizontalAlign.Start).layoutWeight(1)
            }.width('100%')

            Row({ space: 10 }) {
              Column().width(4).height(34).borderRadius(2)
                .linearGradient({
                  angle: 180,
                  colors: [[$r('app.color.info_blue'), 0], [$r('app.color.success_green'), 1]]
                })
              Column({ space: 2 }) {
                Text('出行窗口').fontSize(12).fontColor($r('app.color.text_tertiary'))
                Text(this.nextTrip === ''
                  ? (this.hasPartner ? '暂无出行窗口' : '未发现 ≥32 小时的连续空档')
                  : this.nextTrip)
                  .fontSize(15).fontWeight(FontWeight.Medium).fontColor($r('app.color.text_primary'))
              }.alignItems(HorizontalAlign.Start).layoutWeight(1)
            }.width('100%')
          }
          .width('100%')
          .padding(18)
          .borderRadius(20)
          .backgroundColor($r('app.color.card_bg'))
          .shadow({ radius: 16, color: $r('app.color.shadow_soft'), offsetX: 0, offsetY: 4 })
```

标题区（原 '同休日' Text 与副标题 Text）替换为问候区：

```typescript
        Text(this.greeting()).fontSize(28).fontWeight(FontWeight.Bold)
          .fontColor($r('app.color.text_primary'))
          .margin({ top: 20 })
        Text(DateLabel.mdw(todayEpochDay()) + (this.hasPartner && this.partnerNick !== ''
          ? ' · 我 ❤ ' + this.partnerNick
          : ''))
          .fontSize(13).fontColor($r('app.color.text_tertiary'))
          .margin({ top: 2 })
```

- [ ] **Step 3: 引导卡与统计行升级**

无伴侣引导卡：`borderRadius(16)` → `borderRadius(20)`，删除 `.border({ width: 1, color: $r('app.color.brand_pink_border') })` 一行。统计行保持不变。原三色 `card(...)` Builder 及其三处调用全部删除（Step 2 已替换）。

根 Scroll 追加 `.backgroundColor($r('app.color.page_bg_warm'))`。

- [ ] **Step 4: 静态检查 + 构建验证**

Run: `arkts_check`（HomeView.ets）→ `build_project`
Expected: SUCCESS；无未使用的 `card` Builder 残留警告

---

### Task 5: 窗口行与计划卡升级

**Files:**
- Modify: `entry/src/main/ets/view/CoTimeView.ets`（windowCard / 月历卡 / 无伴侣引导卡）
- Modify: `entry/src/main/ets/view/PlansView.ets`（planCard / 空态）

**Interfaces:**
- Consumes: Task 1 资源；既有 `tagColor(t)`（WindowTagUtil）返回 ResourceColor
- Produces: CoTimeView 新增方法 `barGradient(w: WindowItem): [ResourceColor, ResourceColor]`（渐变竖条两端色）

- [ ] **Step 1: CoTimeView 窗口卡升级**

新增渐变竖条取色方法（类型）：

```typescript
  /** 窗口卡左侧渐变竖条两端色：出行蓝 / 周末紫 / 默认品牌粉→珊瑚橙。 */
  barGradient(w: WindowItem): [ResourceColor, ResourceColor] {
    if (w.tags.indexOf(WindowTag.TRIP) >= 0 || w.tags.indexOf(WindowTag.OVERNIGHT_TRIP) >= 0) {
      return [$r('app.color.tag_trip'), $r('app.color.info_blue')];
    }
    if (w.tags.indexOf(WindowTag.WEEKEND) >= 0) {
      return [$r('app.color.accent_purple'), $r('app.color.brand_pink')];
    }
    return [$r('app.color.brand_pink'), $r('app.color.sunset_to')];
  }
```

`windowCard(w)` 重写为"竖条 + 内容"行卡：

```typescript
  @Builder
  windowCard(w: WindowItem) {
    Row({ space: 12 }) {
      Column().width(4).height(52).borderRadius(2)
        .linearGradient({
          angle: 180,
          colors: [[this.barGradient(w)[0], 0], [this.barGradient(w)[1], 1]]
        })
      Column({ space: 6 }) {
        Row() {
          Text(this.dateRangeLabel(w)).fontSize(14).fontWeight(FontWeight.Medium)
            .fontColor($r('app.color.text_primary')).layoutWeight(1)
          Text(DateLabel.duration(w.durationMin))
            .fontSize(12).fontColor($r('app.color.brand_pink')).fontWeight(FontWeight.Medium)
            .padding({ left: 10, right: 10, top: 3, bottom: 3 })
            .borderRadius(10)
            .backgroundColor($r('app.color.brand_pink_bg'))
        }.width('100%')

        Text(DateLabel.hm(w.start) + ' – ' + DateLabel.hm(w.end))
          .fontSize(12).fontColor($r('app.color.text_tertiary'))

        if (w.tags.length > 0) {
          Row({ space: 6 }) {
            ForEach(w.tags, (t: string) => {
              Chip({
                label: { text: tagLabel(t), fontSize: 11, fontColor: '#FFFFFF' },
                backgroundColor: tagColor(t),
                allowClose: false,
                size: ChipSize.SMALL
              })
            }, (t: string) => t)
          }.width('100%')
        }
      }.alignItems(HorizontalAlign.Start).layoutWeight(1)
    }
    .width('100%')
    .padding(16)
    .borderRadius(20)
    .backgroundColor($r('app.color.card_bg'))
    .shadow({ radius: 16, color: $r('app.color.shadow_soft'), offsetX: 0, offsetY: 4 })
    .onClick(() => this.onWindowTap(w))
  }
```

（注意：Chip 是 void Builder，不能链 margin；标签行外层已有 space 6。）

- [ ] **Step 2: CoTimeView 其余卡片统一**

月历视图容器（monthView 内 `Column ... .padding(12).borderRadius(14).backgroundColor(card_bg).border(border_weak)`）：radius 改 20、删除 `.border(...)`、追加 `.shadow({ radius: 16, color: $r('app.color.shadow_soft'), offsetX: 0, offsetY: 4 })`。无伴侣引导卡（listView 内）：`borderRadius(16)`→`borderRadius(20)`、删除 `.border(...)`。

- [ ] **Step 3: PlansView 计划卡与空态升级**

`planCard(p)` 调整：

1. 容器：`borderRadius(14)`→`borderRadius(20)`；删除整个 `.border({...})`；追加 `.shadow({ radius: 16, color: $r('app.color.shadow_soft'), offsetX: 0, offsetY: 4 })`；`padding(14)`→`padding(16)`。
2. 左侧状态竖条：内容外包 `Row({ space: 12 }) { 竖条; 原 Column.layoutWeight(1) }`，竖条：

```typescript
        Column().width(4).height(40).borderRadius(2)
          .backgroundColor(p.status === 'CONFLICT'
            ? $r('app.color.danger_red')
            : (p.status === 'CANCELLED' ? $r('app.color.text_hint') : $r('app.color.brand_pink')))
```

3. 冲突提示块保留 `danger_bg` 底，`borderRadius(8)` 不变。

空态（`plans.length === 0` 分支）改为大图标引导：

```typescript
          Column({ space: 12 }) {
            SymbolGlyph($r('sys.symbol.heart'))
              .fontSize(44)
              .fontColor([$r('app.color.brand_pink_muted')])
            Text('还没有计划').fontSize(16).fontWeight(FontWeight.Medium)
            Text($r('app.string.plans_empty_desc'))
              .fontSize(12).fontColor($r('app.color.text_tertiary')).textAlign(TextAlign.Center)
            Button('去选一个窗口创建计划')
              .backgroundColor($r('app.color.brand_pink'))
              .borderRadius(22).height(44)
              .onClick(() => {
                if (this.onGoWindow != null) {
                  this.onGoWindow();
                } else {
                  navToCoTime();
                }
              })
          }
          .alignItems(HorizontalAlign.Center)
          .width('100%').padding({ top: 36, bottom: 36, left: 24, right: 24 }).borderRadius(20)
          .backgroundColor($r('app.color.brand_pink_bg'))
```

- [ ] **Step 4: 静态检查 + 构建验证**

Run: `arkts_check`（CoTimeView.ets, PlansView.ets）→ `build_project`
Expected: SUCCESS；若 `sys.symbol.heart` 查询无果，换成 `chevron_left` 或去掉图标行（用 44 号品牌粉粗体 "❤" Text 代替：`Text('❤').fontSize(40).fontColor($r('app.color.brand_pink'))`）

---

### Task 6: 班表页 ScheduleHub 重排

**Files:**
- Modify: `entry/src/main/ets/view/ScheduleHub.ets`

**Interfaces:**
- Consumes: Task 1 资源；`chevron_right`（已验证图标）
- Produces: 无

- [ ] **Step 1: 页面底色与分段控件**

根 Scroll 追加 `.backgroundColor($r('app.color.page_bg_warm'))`。「我的/伴侣」分段控件现状已符合胶囊双选样式（fill_soft 容器 + brand_pink 激活），仅把 `borderRadius(14)` 容器与 `borderRadius(10)` 选项保持不变。

- [ ] **Step 2: entry() 卡片升级为图标行卡**

`entry(title, desc, onTap)` 改为（图标名先 `devecocli docs search` 核实，任一查不到则该图标位用 `chevron_right`，或整体退化为无图标）：

```typescript
  @Builder
  entry(icon: Resource, title: string, desc: string, onTap: () => void) {
    Row({ space: 14 }) {
      Column() {
        SymbolGlyph(icon).fontSize(22).fontColor([$r('app.color.brand_pink')])
      }
      .width(44).height(44).justifyContent(FlexAlign.Center)
      .borderRadius(14)
      .backgroundColor($r('app.color.brand_pink_bg'))

      Column({ space: 4 }) {
        Text(title).fontSize(16).fontWeight(FontWeight.Medium).fontColor($r('app.color.text_primary'))
        Text(desc).fontSize(12).fontColor($r('app.color.text_tertiary'))
      }.alignItems(HorizontalAlign.Start).layoutWeight(1)

      SymbolGlyph($r('sys.symbol.chevron_right'))
        .fontSize(16).fontColor([$r('app.color.text_disabled')])
    }
    .width('100%')
    .padding(16)
    .borderRadius(20)
    .backgroundColor($r('app.color.card_bg'))
    .shadow({ radius: 16, color: $r('app.color.shadow_soft'), offsetX: 0, offsetY: 4 })
    .onClick(() => onTap())
  }
```

四个调用改带图标（候选名，核实后使用；查不到的用 `sys.symbol.doc_text` 等已确认存在的替代或 `chevron_right`）：

```typescript
          this.entry($r('sys.symbol.arrow_triangle_2_circlepath'), '循环模板', ...)
          this.entry($r('sys.symbol.paintbrush'), '月历涂抹', ...)
          this.entry($r('sys.symbol.square_and_pencil'), '课程表导入', ...)
          this.entry($r('sys.symbol.gearshape'), '班次类型管理', ...)
```

- [ ] **Step 3: 无伴侣引导卡与说明**

无伴侣引导卡：`borderRadius(16)`→`borderRadius(20)`、删除 `.border(...)`、追加统一 shadow。原 entry 里的 `Text('›')` 全部被 Step 2 替换，无残留。

- [ ] **Step 4: 静态检查 + 构建验证**

Run: `arkts_check`（ScheduleHub.ets）→ `build_project`
Expected: SUCCESS

---

### Task 7: 我的页 MeView 重排

**Files:**
- Modify: `entry/src/main/ets/view/MeView.ets`

**Interfaces:**
- Consumes: Task 1 资源（渐变卡范式）
- Produces: 无（五个卡片 Builder 的逻辑分支全部保留，仅改样式）

- [ ] **Step 1: 顶部个人渐变卡**

`build()` 中删除 `Text('我的')...` 标题，在 `this.partnerCard()` 之前插入渐变卡（复用 `partnerNick` 状态？MeView 已有 `partnerExists`/`pNick`）：

```typescript
        // 个人卡：渐变底 + 头像占位 + 配对状态
        Row({ space: 14 }) {
          Column() {
            Text('我').fontSize(18).fontWeight(FontWeight.Bold).fontColor('#FFFFFF')
          }
          .width(52).height(52).justifyContent(FlexAlign.Center)
          .borderRadius(26)
          .backgroundColor('#33FFFFFF')

          Column({ space: 3 }) {
            Text('我的').fontSize(20).fontWeight(FontWeight.Bold).fontColor('#FFFFFF')
            Text(this.pairStateText() + (this.partnerExists ? ' · 与 ' + this.pNick : ''))
              .fontSize(12).fontColor('#FFFFFFB8')
          }.alignItems(HorizontalAlign.Start).layoutWeight(1)

          SymbolGlyph($r('sys.symbol.heart'))
            .fontSize(24).fontColor(['#FFFFFF'])
        }
        .width('100%')
        .padding(20)
        .borderRadius(24)
        .linearGradient({
          angle: 135,
          colors: [[$r('app.color.sunset_from'), 0], [$r('app.color.sunset_to'), 1]]
        })
        .shadow({ radius: 16, color: $r('app.color.shadow_soft'), offsetX: 0, offsetY: 4 })
        .margin({ top: 16 })
```

根 Scroll 追加 `.backgroundColor($r('app.color.page_bg_warm'))`。

- [ ] **Step 2: 五个卡片 Builder 统一新卡片样式**

对 `partnerCard()` / `pairingCard()` / `myParamsCard()` / `shareLevelCard()` / `settingsCard()` 逐个执行同样的容器替换（内容分支不动）：

- `.borderRadius(16)` → `.borderRadius(20)`
- 删除 `.border({ width: 1, color: $r('app.color.border_weak') })`
- 追加 `.shadow({ radius: 16, color: $r('app.color.shadow_soft'), offsetX: 0, offsetY: 4 })`

`pairingCard()` 内"解除配对"按钮的 `.border({ width: 1, color: border_weak })` 删除，改 `.backgroundColor($r('app.color.fill_weak'))`。

`settingsCard()` 内"查看 ›" / "›" 文本改为 `SymbolGlyph($r('sys.symbol.chevron_right')).fontSize(16).fontColor([$r('app.color.text_hint')])`；行间 `Divider().color(border_weak)` 改为 `Divider().color($r('app.color.fill_weak'))`。

- [ ] **Step 3: 静态检查 + 构建验证**

Run: `arkts_check`（MeView.ets）→ `build_project`
Expected: SUCCESS；`sys.symbol.heart` 查不到时用 `Text('❤')` 替代

---

### Task 8: 半模态与编辑页轻改 + 桌面卡片

**Files:**
- Modify: `entry/src/main/ets/component/WindowDetailSheet.ets`
- Modify: `entry/src/main/ets/component/DayDetailSheet.ets`
- Modify: `entry/src/main/ets/pages/CycleEditor.ets` / `PaintMonth.ets` / `CourseImport.ets` / `OcrCourse.ets` / `ScheduleEditor.ets`
- Modify: `entry/src/main/ets/widget/RestCard2x2.ets`（以 glob 实际路径为准，可能在 widget/ 或 component/ 下）

**Interfaces:**
- Consumes: Task 1 资源；新卡片样式范式
- Produces: 无

- [ ] **Step 1: WindowDetailSheet**

先读文件定位，然后：

1. 窗口信息头（时间主句区域）外包渐变横条：在信息头容器追加 `.linearGradient({ angle: 135, colors: [[$r('app.color.sunset_from'), 0], [$r('app.color.sunset_to'), 1]] })`，其内文字改白（'#FFFFFF' / '#FFFFFFB8'），圆角 20。
2. 「创建计划」按钮改主按钮胶囊：`.width('100%').height(46).borderRadius(23).backgroundColor($r('app.color.brand_pink'))`。
3. 卡片类容器统一新卡片样式（radius 20、去 border、shadow）；计划类型 Chip 行不动。

- [ ] **Step 2: DayDetailSheet**

先读文件定位，然后：分区容器与窗口行卡统一新卡片样式；`SubHeader` 三分区标题保持；`busyBar` 颜色资源（my_busy/partner_busy）不动；sheet 根容器背景改 `.backgroundColor($r('app.color.page_bg_warm'))`（若有设置背景处）。

- [ ] **Step 3: 五个编辑页统一页头与底色**

对 CycleEditor / PaintMonth / CourseImport / OcrCourse / ScheduleEditor 逐页：

1. 页头统一为：`Row({ space: 8 }) { SymbolGlyph($r('sys.symbol.chevron_left')).fontSize(22).fontColor([$r('app.color.text_primary')]).onClick(() => router.back()), Text('<页名>').fontSize(20).fontWeight(FontWeight.Bold) }.width('100%').margin({ top: 12, bottom: 4 })`（替换原返回 Text 按钮；router 调用方式沿用各页现状）。
2. 根容器追加 `.backgroundColor($r('app.color.page_bg_warm'))`。
3. 主操作按钮（保存/添加类）统一 `.borderRadius(22)`；卡片容器 `.borderRadius(16)`→`20` 并删除 1px `border_weak` 描边、追加 shadow。
4. **不动**：列表结构、swipeAction、表单字段、校验逻辑。

- [ ] **Step 4: RestCard2x2 桌面卡片换色**

先 glob 定位文件并读取；然后：主底色改 sunset 渐变（linearGradient 同范式），文字/数字用 '#FFFFFF' 与 '#FFFFFFB8'；若当前为浅色卡则把卡片底改渐变、内容文字全部改白；**尺寸与排版结构不动**。widget 内若用 `$r('app.color.*')` 资源，确认在 widget 上下文可用，否则直接写 hex（widget 侧倾向固定色，深浅色不敏感）。

- [ ] **Step 5: 静态检查 + 构建验证**

Run: `arkts_check`（本任务全部改动 .ets）→ `build_project`
Expected: SUCCESS；widget 模块若有单独编译错误按报错修（widget 不支持部分组件 API 时退化为纯色底）

---

### Task 9: 全量回归

**Files:**
- 无新改动（只验证）

- [ ] **Step 1: 全模块构建**

Run: `build_project`（全 product default, debug）
Expected: SUCCESS

- [ ] **Step 2: domain 单测回归**

Run: `D:\local\DevEcoStudio\tools\hvigor\bin\hvigorw.bat test --mode module -p module=domain@default -p product=default`
Expected: `Tests run: 67, Pass: 67`（结果文件 `domain\.test\default\intermediates\test\coverage_data\test_result.txt`）

- [ ] **Step 3: 残留扫描**

Run（rg/grep）：
- `border_weak` 在 `view/` 目录应无卡片描边残留（编辑页允许少量存量）
- `Index.ets` 中无 `PlansView` 引用
- `page_bg_soft` / `page_bg` 在 view/ 下的使用是否已被 `page_bg_warm` 替代（首页/共同/班表/我的四页）

Expected: 符合上述清单

- [ ] **Step 4: 设备冒烟（如有设备，可选）**

四 tab 切换、共同页分段、窗口卡点击建计划、计划空态引导、首页渐变主卡深浅色各看一遍。

---

## Self-Review 记录

- 规格覆盖：设计文档 §2（Task 1）、§3（Task 2/3）、§4.1（Task 4）、§4.2（Task 2/5）、§4.3（Task 6）、§4.4（Task 7）、§4.5（Task 8 Step 1-2）、§4.6（Task 8 Step 3）、§4.7（Task 8 Step 4）✓
- 占位符检查：Task 2 Step 2-4 的 `...` 均标注了原文行号来源（照搬而非缺失）；Task 8 各步要求"先读文件再改"，因半模态/编辑页改动为模式化替换，锚点在执行时读取确认
- 类型一致性：`barGradient` 返回 `[ResourceColor, ResourceColor]` 与 linearGradient colors 数组结构匹配；PlansView `embedded`/`onGoWindow` 在 Task 2 定义、Task 5 沿用 ✓
