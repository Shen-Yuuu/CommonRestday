# 同休日整体项目改造 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 以精简版原型为唯一正式信息架构，将现有 HarmonyOS 应用改造成“答案优先、本地可靠、云端可降级、API 26 渐进增强”的可发布产品。

**Architecture:** 保留 `domain` 纯逻辑引擎和 `data` 本地事实源；在 `feature` 增加页面读模型、命令与同步编排；在 `entry` 使用三 Tab + Navigation 构建温暖编辑感界面；`cloud` 只承载 HUKS 密钥门面、配对协议和加密快照客户端。云工程接入必须经过阶段 0兼容性门禁。

**Tech Stack:** HarmonyOS NEXT API 26、ArkTS、ArkUI、Navigation/NavDestination、ArkData RDB/Preferences、Calendar Kit、Form Kit、Scan Kit、Share Kit、Notification Kit、ReminderAgent、TaskPool、HUKS、Cloud Foundation Kit、Node.js 20 云函数、Hypium。

**Spec:** `docs/plans/2026-09-21-overall-project-redesign-design.md`

**Research inputs:** `docs/05-云端配对前置条件调研.md`、`docs/06-API26能力与精简版优化调研.md`

---

## Global Constraints

- Product target: `docs/prototype/index.html` 精简版，01「温暖编辑感」。
- Navigation: exactly three bottom tabs — 首页、共同时间、我的；班表只能作为“我的”二级入口。
- Platform: HarmonyOS NEXT，`targetSdkVersion/compileSdkVersion/compatibleSdkVersion = 26.0.0`。
- Runtime: phone remains the only declared device type until tablet/foldable validation is complete.
- Data ownership: local RDB is the source of truth; cloud snapshots are replaceable derivatives.
- Privacy: no schedule names, course names, locations, notes, plan titles, long-term keys, or invite history in cloud plaintext.
- Reliability: cloud, calendar, notification, scan, share, and card failures must not block local schedules or common-time calculation.
- Security: long-term pair keys live behind HUKS aliases; no raw key in Preferences, source, logs, QR codes, or share links.
- Cloud runtime: Node.js 20; synchronous client timeout must be `<= 55000ms`, this plan standardizes on `30000ms`.
- UI: 360vp, dark mode, 2.0x font, reduced motion, and screen reader are release gates.
- Scope exclusions: no LiveView, real-time collaboration, Push real-time sync, three-person groups, distributed KV cross-account sync, or background keep-alive.

---

## 0. 执行规则与文件职责

### 0.1 基线与提交

- 当前仓库可能包含用户未提交改动。开始每个任务前执行 `git status --short`，只修改任务列出的文件。
- 每个任务一个提交；阶段门禁提交单独完成。
- 禁止使用 `git reset --hard`、`git checkout -- <file>` 或覆盖用户改动。
- 每个阶段结束运行完整构建。已验证可用的命令：

```powershell
& 'D:\local\DevEcoStudio\tools\hvigor\bin\hvigorw.bat' assembleHap `
  --mode module `
  -p product=default `
  -p module=entry@default `
  -p buildMode=debug `
  --no-daemon
```

预期：`BUILD SUCCESSFUL`。未配置签名时允许出现“skip sign”警告，但真机阶段必须配置自动签名。

### 0.2 测试纪律

每个业务任务按以下顺序：

1. 在对应 `src/test` 中新增失败测试；
2. 运行相关 Hypium 测试，确认失败原因正确；
3. 实现最小代码；
4. 运行相关测试并通过；
5. 运行 `assembleHap`；
6. 更新阶段验收记录。

Hypium 用例分别从 DevEco Studio 运行：

- `domain/src/test/List.test.ets`：领域纯逻辑；
- `entry/src/test/List.test.ets`：跨模块本地单测；
- `entry/src/ohosTest/ets/test/List.test.ets`：设备能力与 UIAbility 集成。

### 0.3 不可擅自更改的决策

- 仅三个底部入口；班表进入“我的”。
- RDB 是事实源，云端不是主库。
- 云端失败不得阻断本地使用。
- 邀请码不得直接作为长期快照密钥。
- 长期密钥不得写入 Preferences、源码、二维码或日志。
- 默认使用系统日历确认流程，不静默批量写入。
- 不实现 LiveView、实时协作、Push 实时同步或三人群组。

### 0.4 文件职责映射

| File or directory | Single responsibility after redesign |
|---|---|
| `domain/src/main/ets/model/Types.ets` | 计算所需领域类型，不放页面文案或 Kit 类型 |
| `domain/src/main/ets/engine/` | 共同时间计算，不访问存储、云或 UI |
| `domain/src/main/ets/snapshot/` | 最小忙碌快照 schema 与编解码 |
| `data/src/main/ets/db/MigrationRunner.ets` | 唯一数据库版本迁移入口 |
| `data/src/main/ets/repo/ScheduleRepo.ets` | RDB 行与领域对象映射 |
| `data/src/main/ets/settings/SettingsStore.ets` | 轻量偏好和非敏感同步元数据 |
| `cloud/src/main/ets/crypto/` | HUKS 密钥生命周期和快照密码操作 |
| `cloud/src/main/ets/api/CloudApi.ets` | 云协议 DTO、调用和错误映射，不编排页面状态 |
| `feature/src/main/ets/model/PresentationModels.ets` | 页面可直接消费的稳定读模型 |
| `feature/src/main/ets/usecase/CommonTimeQueryService.ets` | 首页、窗口、详情只读查询 |
| `feature/src/main/ets/usecase/ScheduleCommandService.ets` | 日程变更、事务、重算和刷新事件 |
| `feature/src/main/ets/usecase/PairingSyncService.ets` | 配对和同步状态机 |
| `feature/src/main/ets/integration/` | 日历、通知、扫码与分享门面 |
| `entry/src/main/ets/navigation/` | Route 常量、NavPathStack 和深链白名单 |
| `entry/src/main/ets/theme/DesignTokens.ets` | 温暖编辑风设计令牌与动效参数 |
| `entry/src/main/ets/view/` | 三个主 Tab 和计划视图，只调用 feature API |
| `entry/src/main/ets/component/` | 可复用展示组件与 Sheet，不直接写仓储 |

---

# 阶段 0：基线、契约与高风险验证

## Task 0.1：冻结当前领域行为

**Files:**

- Modify: `domain/src/test/EngineTest.ets`
- Modify: `domain/src/test/ClassifierTest.ets`
- Modify: `domain/src/test/ConflictTest.ets`
- Modify: `domain/src/test/SnapshotTest.ets`
- Create: `domain/src/test/HomeAnswerFixtureTest.ets`
- Modify: `domain/src/test/List.test.ets`

**Steps:**

- [ ] 增加固定 epochDay 数据集，覆盖：今晚餐叙、无今晚窗口、下个完整同休日、跨夜旅行、跨两日旅行、单人、本机代录、快照伴侣。
- [ ] 固定常规窗口与旅行窗口不能互相冒充的回归用例。
- [ ] 固定计划冲突、无替代窗口和采用替代窗口的行为。
- [ ] 固定快照 L1/L2 两档输出不包含课程名、班次名、地点和计划标题。
- [ ] 将新测试注册到 `List.test.ets`。
- [ ] 先运行并记录当前失败；只在测试揭示真实缺陷时修复领域代码，不在本任务改 UI。

**Acceptance:** 所有现有领域测试和新增基线测试通过，测试数据不依赖系统当前日期。

**Commit:** `test(domain): freeze common-time redesign baseline`

## Task 0.2：建立共享契约与功能开关

**Files:**

- Modify: `domain/src/main/ets/model/Types.ets`
- Modify: `domain/src/main/ets/engine/CommonFreeEngine.ets`
- Create: `feature/src/main/ets/model/PresentationModels.ets`
- Create: `feature/src/main/ets/config/FeatureFlags.ets`
- Modify: `feature/Index.ets`
- Create: `entry/src/test/PresentationModelsTest.ets`
- Modify: `entry/src/test/List.test.ets`

**Interfaces:**

```ts
export enum WindowChannel { REGULAR = 'REGULAR', TRIP = 'TRIP' }
export enum ExperienceMode { SOLO = 'SOLO', LOCAL_PARTNER = 'LOCAL_PARTNER', PAIRED = 'PAIRED' }
export enum AnswerState { AVAILABLE = 'AVAILABLE', UNAVAILABLE = 'UNAVAILABLE', UNKNOWN = 'UNKNOWN', STALE = 'STALE' }
export enum AnswerKind { TONIGHT = 'TONIGHT', FULL_REST_DAY = 'FULL_REST_DAY', TRIP = 'TRIP' }
export enum AnswerAction { OPEN_WINDOW = 'OPEN_WINDOW', OPEN_SCHEDULE = 'OPEN_SCHEDULE', OPEN_PARTNER = 'OPEN_PARTNER' }
export enum WindowFilterKey { ALL = 'ALL', GTE_2H = 'GTE_2H', FULL_DAY = 'FULL_DAY', WEEKEND = 'WEEKEND', TRIP = 'TRIP' }

export interface WindowSummary {
  start: number;
  end: number;
  durationMin: number;
  tags: string[];
  channel: WindowChannel;
  title: string;
  subtitle: string;
}

export interface QuickAnswer {
  kind: AnswerKind;
  state: AnswerState;
  headline: string;
  supportingText: string;
  windowStart: number;
  windowEnd: number;
  action: AnswerAction;
}

export interface TodaySummary {
  myText: string;
  partnerText: string;
  commonText: string;
}

export interface HomeSummary {
  mode: ExperienceMode;
  partnerName: string;
  tonight: QuickAnswer;
  fullRestDay: QuickAnswer;
  trip: QuickAnswer;
  nextWindow: WindowSummary | null;
  conflictCount: number;
  today: TodaySummary;
  computedAt: number;
  stale: boolean;
}

export interface WindowFilter {
  key: WindowFilterKey;
  fromEpochMin: number;
}

export interface PlanSummary {
  id: string;
  title: string;
  start: number;
  end: number;
  status: string;
  conflictText: string;
}

export interface CommonTimePageData {
  windows: WindowSummary[];
  plans: PlanSummary[];
  computedAt: number;
  stale: boolean;
}

export interface WindowDetailData {
  window: WindowSummary;
  myBusyText: string;
  partnerBusyText: string;
  partnerShareLevel: number;
}
```

同时给领域 `Window` 增加 `channel: WindowChannel`，由 `CommonFreeEngine` 生成，不允许数据层或 UI 从 tags 反推；`ScheduleRepo.replaceWindows/listWindows` 在 Task 0.3 改为读写完整 `Window`。

`FeatureFlags` 至少提供：`newShell`、`cloudPairing`、`scanPairing`、`newCard`、`responsiveV2`，默认只开启 `newShell` 的开发开关；发布配置由 `BuildProfile.ets` 映射，不从远端动态下发。

**Acceptance:** UI 层无需导入 `ScheduleRepo` 即可表达所有首页状态；枚举与文案分离。

**Commit:** `feat(feature): define presentation contracts and rollout flags`

## Task 0.3：引入显式数据库迁移

**Files:**

- Create: `data/src/main/ets/db/MigrationRunner.ets`
- Modify: `data/src/main/ets/db/Db.ets`
- Modify: `data/src/main/ets/repo/ScheduleRepo.ets`
- Modify: `data/Index.ets`
- Create: `entry/src/test/DbMigrationTest.ets`
- Modify: `entry/src/test/List.test.ets`

**Target schema version:** `2`

**Migration v1 → v2:**

- `plan.updated_at INTEGER NOT NULL DEFAULT 0`
- `plan.calendar_state TEXT NOT NULL DEFAULT 'NOT_REQUESTED'`
- `plan.sync_state TEXT NOT NULL DEFAULT 'LOCAL_ONLY'`
- `computed_window.computed_at INTEGER NOT NULL DEFAULT 0`
- `computed_window.channel TEXT NOT NULL DEFAULT 'REGULAR'`
- `sync_meta('schema_version') = '2'`

**Steps:**

- [ ] 先写从 v1 建库夹具升级到 v2 的失败测试。
- [ ] 迁移在单一事务执行；任一 SQL 失败整体回滚。
- [ ] 移除 `Db.init()` 中“ALTER 报错静默忽略”的模式。
- [ ] 新装数据库直接创建 v2；存量数据库依次执行迁移。
- [ ] 再次运行迁移应无副作用。
- [ ] 将窗口仓储签名收敛为 `replaceWindows(windows: Window[], computedAt: number): Promise<void>` 与 `listWindows(): Promise<Window[]>`，完整保存 `tags/channel/computedAt`。
- [ ] 为 `PlanRow` 增加 `updatedAt/calendarState/syncState` 并更新所有映射，旧行读取时使用迁移后的默认值。

**Acceptance:** 新装、v1 升级、重复启动和中断回滚四类测试通过。

**Commit:** `feat(data): add versioned schema migrations`

## Task 0.4：CloudDev 与 HUKS 技术门禁

**Files:**

- Create: `docs/validation/clouddev-api26-spike.md`
- Create only in throwaway experiment: `experiments/clouddev-spike/README.md`
- Do not modify yet: root `build-profile.json5`
- Do not add yet: production `CloudProgram/`

**Experiments:**

- [ ] 用 `[CloudDev] Empty Ability` 创建一次性工程，记录其 `Application + CloudProgram` 结构。
- [ ] 验证同 bundle name 关联、自动签名、模拟器 debugToken 和真机调用。
- [ ] 验证现有多 HAR 是否可在不重排根目录的情况下加入 CloudProgram。
- [ ] 部署一个 Node.js 20 echo 函数，端侧 `timeout` 设置为 30 秒。
- [ ] 验证 HUKS 非导出 ECDH/HKDF/AES-GCM 组合；记录算法参数、别名生命周期和错误码。
- [ ] 验证云数据库能否由云函数访问并禁止端侧直接访问。

**Decision record must state exactly one outcome:**

- `IN_REPO_CLOUDPROGRAM`：允许在当前仓库新增 `CloudProgram/`；或
- `SEPARATE_CLOUD_REPO`：当前应用仓库保持不动，云工程放入经用户确认的独立仓库；或
- `CLOUD_BLOCKED`：阶段 3暂停，发布本地版。

**Stop condition:** HUKS 安全链路未验证时，不得开始阶段 3；不允许退回短码派生长期密钥。

**Commit:** `docs: record CloudDev and HUKS compatibility gate`

## Task 0.5：设计令牌与基础组件

**Files:**

- Create: `entry/src/main/ets/theme/DesignTokens.ets`
- Modify: `entry/src/main/resources/base/element/color.json`
- Modify: `entry/src/main/resources/base/element/float.json`
- Create: `entry/src/main/ets/component/EditorialSection.ets`
- Create: `entry/src/main/ets/component/EditorialCard.ets`
- Create: `entry/src/main/ets/component/StatePanel.ets`

**Required light tokens:** page `#F7EDDF`、card `#FFF9F0`、primary berry `#97314F`、hero berry `#8F2F4C`、primary text `#382B28`、secondary text `#6F5F59`、divider `#E4D3C5`。  
**Required dark tokens:** page `#191411`、card `#201B19`、primary berry `#D58AA1`、primary text `#F0E6DB`、secondary text `#C8B9AF`、divider `#45362F`。

间距使用 4/8/12/16/24/32；正文/说明/小标题/展示标题分别建立 token；卡片默认错角 `8/21/21/21vp`，Sheet 顶部 `28vp`，主按钮胶囊。动效 easing 固定 `cubic-bezier(.22, 1, .36, 1)`，并提供标准与减少动效时长。

**Acceptance:** 新组件支持深浅色、大字体、键盘焦点和无动效；品牌色不在新页面以十六进制散落。

**Commit:** `feat(ui): establish warm editorial design system`

### 阶段 0出口

- [ ] 领域基线绿灯；
- [ ] v2 数据迁移绿灯；
- [ ] CloudDev/HUKS 有明确结论；
- [ ] 构建成功；
- [ ] 未触碰用户现有未提交业务改动之外的文件。

---

# 阶段 1：精简主框架与本地答案闭环

## Task 1.1：实现共同时间查询服务

**Files:**

- Create: `feature/src/main/ets/usecase/CommonTimeQueryService.ets`
- Modify: `feature/Index.ets`
- Create: `entry/src/test/CommonTimeQueryServiceTest.ets`
- Modify: `entry/src/test/List.test.ets`

**Public methods:**

```ts
static async getHomeSummary(nowEpochMin: number): Promise<HomeSummary>;
static async getCommonTimePage(filter: WindowFilter, nowEpochMin: number): Promise<CommonTimePageData>;
static async getWindowDetail(start: number, end: number): Promise<WindowDetailData>;
```

**Rules:**

- 今晚只从当天剩余常规窗口选取，不能被旅行通道劫持。
- 完整同休日只读取 `FULL_DAY`。
- 出行优先 `TRIP`，其次 `OVERNIGHT_TRIP`，并明确跨日天数。
- 无伴侣时返回 `SOLO`，但仍显示“我的空闲”答案。
- 缓存过期时保留结果并设置 `stale=true`。

**Acceptance:** 覆盖三个答案、无数据、单人、本机代录、已配对旧快照和缓存过期。

**Commit:** `feat(feature): add answer-first common-time queries`

## Task 1.2：建立 Navigation 与三 Tab 壳层

**Files:**

- Create: `entry/src/main/ets/navigation/NavRoutes.ets`
- Create: `entry/src/main/ets/navigation/AppNavigator.ets`
- Modify: `entry/src/main/ets/pages/Index.ets`
- Modify: `entry/src/main/ets/util/NavUtil.ets`
- Modify: `entry/src/main/resources/base/profile/main_pages.json`

**Routes:** `home`、`common-time`、`me`、`schedule-hub`、`shift-editor`、`cycle-editor`、`course-import`、`paint-month`、`ocr-course`、`data-privacy`、`pairing`。

**Steps:**

- [ ] 用 `Navigation + NavPathStack` 包裹主 Tabs。
- [ ] Tabs 只保留首页、共同时间、我的，索引固定为 0/1/2。
- [ ] `navToMe()` 和 `navToCoTime()` 迁移后仍工作。
- [ ] 班表入口从主 Tab 移除，但页面不删除。
- [ ] 卡片/Want 深链无参数时到首页；带 route 时校验白名单后导航。
- [ ] 首启隐私遮罩继续覆盖整个导航容器。

**Acceptance:** 返回栈、Tab 切换、隐私拦截、冷启动和卡片回流均正确；不存在旧索引 `activeTab=3`。

**Commit:** `feat(navigation): adopt three-tab destination shell`

## Task 1.3：首页正式落地

**Files:**

- Rewrite: `entry/src/main/ets/view/HomeView.ets`
- Create: `entry/src/main/ets/component/QuickAnswerRow.ets`
- Create: `entry/src/main/ets/component/NextWindowHero.ets`
- Create: `entry/src/main/ets/component/TodayOverview.ets`
- Create: `entry/src/main/ets/component/ConflictNotice.ets`

**States:** loading skeleton、fresh content、stale content、no schedule、solo、local partner、paired、recoverable error。

**Interactions:**

- 有窗口的答案 → 打开 `WindowDetailSheet`；
- 缺我的日程 → `schedule-hub`；
- 缺伴侣 → `pairing` 或本机代录；
- 冲突 → 共同时间的计划分段；
- 手动刷新只刷新读模型，不重复触发权限。

**Acceptance:** 与精简原型的一屏层级一致；360vp 无横向滚动；三答案来自真实服务而非 UI 临时筛选。

**Commit:** `feat(home): deliver answer-first editorial home`

## Task 1.4：共同时间页精简

**Files:**

- Refactor: `entry/src/main/ets/view/CoTimeView.ets`
- Modify: `entry/src/main/ets/component/WeekScheduleView.ets`
- Modify: `entry/src/main/ets/component/DayDetailSheet.ets`
- Reuse: `entry/src/main/ets/view/PlansView.ets`

**Rules:**

- 一级分段只有“时间窗口/共同计划”。
- 视图只有“列表/周历”；月历降为日程高级入口。
- 精简筛选固定为：全部、≥2小时、完整同休、周末、可出行。
- 标签展示压缩为：完整同休日、周末、可出行；餐叙/自习用于答案或筛选，不堆满卡片。
- 列表按日归并，优先显示当天最长且未结束的窗口。

**Acceptance:** 过滤结果与领域标签一致；列表和周历选中同一窗口；一个节点只绑定一个 Sheet。

**Commit:** `feat(common-time): simplify windows and plans workspace`

## Task 1.5：“我的”与日程入口收纳

**Files:**

- Refactor: `entry/src/main/ets/view/MeView.ets`
- Refactor: `entry/src/main/ets/view/ScheduleHub.ets`
- Modify: `entry/src/main/ets/model/RouteParams.ets`

**Me sections:** 伴侣与同步、我的日程、作息、数据与隐私。只显示起床、就寝、收整三个主参数；视界和算法细项进入高级设置。

**ScheduleHub:** 默认展示“我”的日程摘要；本机代录模式才显示“TA”；班次/循环/课程/临时调整为四个主入口，OCR 和月历涂抹列入辅助录入。

**Acceptance:** 所有旧录入页仍可达；首页和共同时间的缺数据动作能直达正确入口。

**Commit:** `feat(me): consolidate schedule and partner settings`

### 阶段 1出口

- [ ] 三 Tab 与精简原型一致；
- [ ] 首页三个答案真实可用；
- [ ] 单人、本机代录和已配对展示语义清晰；
- [ ] 旧录入功能仍可达；
- [ ] 本阶段可在完全关闭云功能时发布。

## 阶段 1R：验收整改（进入阶段 2 前执行）

> 2026-09-22 独立验收结论为 `CONDITIONAL PASS`。完整证据和逐项口径见 `docs/validation/2026-09-22-stage1-acceptance.md`。

- [ ] 修正今晚答案把等待时间计入窗口时长的问题，并补边界测试；
- [ ] 允许就寝时间跨午夜，仅拒绝相同时间或领域层明确无效的组合；
- [ ] ScheduleHub 的视界文案与统计区间读取实际参数；
- [ ] 前置 `ScheduleCommandService`，收回 `DayShiftSheet` 对仓储的直接写入；
- [ ] 为 ScheduleHub/WeekSchedule 增加 feature 读模型，阶段 1 新 UI 不再自行拼仓储数据；
- [ ] 将本地测试 runner 或标准 Hypium 命令纳入仓库，其他机器可一条命令复现；
- [ ] clean build 与单测通过；设备不可用时保留视觉/返回栈验收待办。

## 阶段 1V：温暖影像玻璃试点（阶段 1R 后、阶段 2 前）

**Design:** `docs/plans/2026-09-22-warm-image-glass-visual-spec.md`

- [ ] 增加材质能力策略、玻璃/实色双路径容器和静态气氛背景组件；
- [ ] 只在首页 Hero 与悬浮底栏试点，密集日程、课程和设置页面保持纸面；
- [ ] 系统材质不支持、降低透明度、低性能或对比不足时回退近实色；
- [ ] 只动画 opacity/transform，不在滚动容器和重复列表项上实时模糊；
- [ ] 设备可用后提交 360vp 浅色、深色、1.3× 字体、降低透明度四组截图。

`WindowDetailSheet` 不在本阶段抢先重做；它在 Task 2.2 完成功能重构时一次性接入统一 Sheet 材质，避免重复返工。

---

# 阶段 2：窗口—计划—日历—冲突闭环

## Task 2.1：拆分日程命令与重算编排

**Files:**

- Create: `feature/src/main/ets/usecase/ScheduleCommandService.ets`
- Refactor: `feature/src/main/ets/usecase/ScheduleUseCase.ets`
- Modify: `feature/Index.ets`
- Modify call sites: `entry/src/main/ets/pages/ScheduleEditor.ets`
- Modify call sites: `entry/src/main/ets/pages/CycleEditor.ets`
- Modify call sites: `entry/src/main/ets/pages/PaintMonth.ets`
- Modify call sites: `entry/src/main/ets/pages/CourseImport.ets`

**Command result:**

```ts
export interface ScheduleCommandResult {
  ok: boolean;
  changed: boolean;
  recomputed: boolean;
  syncQueued: boolean;
  errorCode: string;
}
```

所有写方法统一返回 `Promise<ScheduleCommandResult>`。禁止页面保存后自行拼接 `recomputeCount`。

**Acceptance:** 所有日程写入经统一命令；批量课程和月历涂抹使用事务；保存一次只触发一次重算。

**Commit:** `refactor(feature): centralize schedule mutations and recompute`

## Task 2.2：窗口详情与系统日历确认

**Files:**

- Refactor: `entry/src/main/ets/component/WindowDetailSheet.ets`
- Refactor: `feature/src/main/ets/usecase/PlanUseCase.ets`
- Create: `feature/src/main/ets/integration/CalendarGateway.ets`
- Modify: `entry/src/main/ets/entryability/EntryAbility.ets`
- Modify: `entry/src/main/module.json5`
- Create: `entry/src/test/PlanUseCaseTest.ets`

**Default flow:**

1. 在 Sheet 中选择精简类型“约会/其他”、标题和窗口内时间；
2. 先写本地 `PENDING` 计划；
3. 调用 `CalendarManager.editEvent()` 由系统让用户确认；
4. 返回后更新 `calendar_state`；
5. 日历能力不可用或用户取消时保留本地计划，并明确显示“仅保存在应用内”。

保留现有直接 `addEvent` 代码作为显式高级选项，不作为默认。

**Acceptance:** 时间越界、系统取消、权限拒绝、写入成功、重复点击、恢复页面均有测试。

**Commit:** `feat(plan): use user-confirmed calendar planning flow`

## Task 2.3：冲突解释与替代操作

**Files:**

- Modify: `domain/src/main/ets/conflict/PlanConflict.ets`
- Modify: `domain/src/main/ets/model/Types.ets`
- Modify: `feature/src/main/ets/usecase/PlanUseCase.ets`
- Refactor: `entry/src/main/ets/view/PlansView.ets`
- Modify: `entry/src/main/ets/component/ConflictNotice.ets`

**Conflict model:** 增加稳定 `reasonCode`、受影响区间、来源级别和替代窗口；隐私级别不足时只返回“对方时间发生变化”，不得泄露具体班次。

**Actions:** 采用替代时间、重新选择窗口、保留原计划、取消计划。

**Acceptance:** 改期同步迁移日历事件；失败时本地计划不丢失，并进入可重试状态。

**Commit:** `feat(plan): explain conflicts and recover safely`

## Task 2.4：阶段 2端到端验收

**Files:**

- Modify: `entry/src/ohosTest/ets/test/Ability.test.ets`
- Modify: `docs/testing-checklist.md`

**Scenarios:** 从首页答案进入窗口 → 创建计划 → 系统日历确认 → 共同计划出现 → 修改课程制造冲突 → 采用替代时间 → 取消并恢复窗口。

**Commit:** `test(e2e): cover common-time planning lifecycle`

---

# 阶段 3：云端配对与加密快照

> 只有 Task 0.4 结论不是 `CLOUD_BLOCKED` 时执行。

## Task 3.1：确定云工程位置并冻结协议

**Files:**

- Create: `docs/cloud/pairing-protocol-v1.md`
- Create: `docs/cloud/operations-runbook.md`
- Conditional create: `CloudProgram/cloud-config.json`
- Conditional create: `CloudProgram/cloudfunctions/*`

若 Task 0.4 为 `SEPARATE_CLOUD_REPO`，本任务只在当前仓库提交协议和运维文档；在用户授权的独立云仓库实现函数，不得擅自重排本仓库根目录。

**Protocol endpoints:** `pairing-create`、`pairing-join`、`pairing-confirm`、`pairing-status`、`pairing-unpair`、`snapshot-put`、`snapshot-get`、`pair-heartbeat`。

每个请求含 `requestId`；超时 30 秒；错误统一为 `code/message/retryable/serverTime`。

**Commit:** `docs(cloud): freeze pairing and snapshot protocol v1`

## Task 3.2：HUKS 密钥与快照加密门面

**Files:**

- Create: `cloud/src/main/ets/crypto/PairKeyStore.ets`
- Create: `cloud/src/main/ets/crypto/HuksPairKeyStore.ets`
- Refactor: `cloud/src/main/ets/api/SnapshotCrypto.ets`
- Modify: `data/src/main/ets/settings/SettingsStore.ets`
- Modify: `cloud/Index.ets`
- Create: `entry/src/ohosTest/ets/test/HuksPairKeyTest.ets`

**Required API:** create device key, export public key only, derive pair key by alias, encrypt, decrypt, delete alias. `SettingsStore` 只保存 alias 和非敏感元数据；删除 `KEY_PAIR_KEY` 的生产读写。

```ts
export interface PairKeyStore {
  createDeviceKey(alias: string): Promise<void>;
  exportPublicKey(alias: string): Promise<Uint8Array>;
  derivePairKey(deviceAlias: string, peerPublicKey: Uint8Array,
    pairId: string, pairAlias: string): Promise<void>;
  encrypt(pairAlias: string, plain: Uint8Array, aad: Uint8Array): Promise<EncryptedPayload>;
  decrypt(pairAlias: string, payload: EncryptedPayload, aad: Uint8Array): Promise<Uint8Array | null>;
  deleteKey(alias: string): Promise<void>;
}
```

`EncryptedPayload` 固定包含 `ciphertext: string`、`iv: string`、`authTag: string`、`algorithm: 'AES_256_GCM'`；AAD 固定编码 `pairId|ownerUid|version|schemaVersion`，防止密文被换绑到另一配对或版本。

**Acceptance:** 不同 pairId 密文不可互解；篡改 tag 解密失败；解除配对后密钥不可恢复；日志无密钥和密文全文。

**Commit:** `feat(security): move pair keys into HUKS lifecycle`

## Task 3.3：实现配对状态机与客户端

**Files:**

- Refactor: `cloud/src/main/ets/api/CloudApi.ets`
- Create: `feature/src/main/ets/usecase/PairingSyncService.ets`
- Modify: `feature/Index.ets`
- Create: `entry/src/main/ets/pages/PairingPage.ets`
- Modify: `entry/src/main/resources/base/profile/main_pages.json`
- Modify: `entry/src/main/ets/view/MeView.ets`

**Required behavior:** 创建、加入、双方确认、过期、重复请求、取消等待、解除配对。邀请码成功后立即失效；页面只展示最近同步时间和可见范围，不保留历史码。

**Acceptance:** 网络中断可重试；进程重启后恢复状态；`pairState` 与 `syncState` 不混用。

**Commit:** `feat(pairing): implement resilient pairing state machine`

## Task 3.4：实现版本化快照同步

**Files:**

- Modify: `domain/src/main/ets/snapshot/SnapshotBuilder.ets`
- Modify: `domain/src/main/ets/snapshot/SnapshotCodec.ets`
- Refactor: `cloud/src/main/ets/api/CloudApi.ets`
- Modify: `feature/src/main/ets/usecase/PairingSyncService.ets`
- Modify: `entry/src/main/ets/entryability/EntryAbility.ets`
- Modify: `entry/src/main/ets/view/MeView.ets`

**Triggers:** 配对完成、日程保存后、应用回前台、进入共同时间、用户手动同步。失败使用指数退避；不实现后台常驻。

**Ordering:** 以 `pairId + ownerUid + version` 幂等；旧包和同版本包丢弃；解密失败保留最后有效快照并提示重新配对。

**Acceptance:** 离线、乱序、重复、密钥失配、云端 401/403/404/超时和配额失败全部降级，不清空本地窗口。

**Commit:** `feat(sync): add encrypted versioned snapshot exchange`

## Task 3.5：云端安全与双机验收

**Files:**

- Create: `docs/validation/cloud-pairing-e2e.md`
- Modify: `docs/testing-checklist.md`

**Required tests:** 两真机创建/加入、短码过期、二维码 token 复用、成员越权、第三设备访问、离线编辑后恢复、解除配对级联删除、云项目停服时本地可用。

**Commit:** `test(cloud): document two-device security acceptance`

---

# 阶段 4：卡片、扫码、分享与提醒

## Task 4.1：扫码、二维码与系统分享

**Files:**

- Create: `feature/src/main/ets/integration/PairingShareGateway.ets`
- Modify: `entry/src/main/ets/pages/PairingPage.ets`
- Modify: `entry/src/main/module.json5`
- Modify: `entry/src/main/ets/entryability/EntryAbility.ets`

**Rules:** 先用 API 26能力检测；支持时展示默认扫码，不支持时突出短码。二维码和分享链接只含一次性 token。扫码后先显示确认页，不自动绑定。Scan Kit 必须真机验收，不以模拟器结果判定失败。

**Commit:** `feat(pairing): add scan and system share entry points`

## Task 4.2：重构 2×2 服务卡片

**Files:**

- Refactor: `entry/src/main/ets/entryformability/FormAbility.ets`
- Refactor: `entry/src/main/ets/widget/RestCard2x2.ets`
- Modify: `entry/src/main/resources/base/profile/form_config.json`
- Create: `feature/src/main/ets/usecase/CardSummaryService.ets`

**Card states:** 今晚可见、下个完整同休日、暂无结果、未录日程、数据过期、配对待同步。卡片点击带路由参数返回对应窗口或日程入口。

**Constraints:** 卡片进程独立初始化；不在卡片做云同步；不展示完整班表；遵守受限 ArkTS 组件子集。

**Commit:** `feat(card): surface concise common-time answers`

## Task 4.3：分层通知与提醒

**Files:**

- Create: `feature/src/main/ets/integration/NotificationGateway.ets`
- Refactor: `feature/src/main/ets/usecase/PlanUseCase.ets`
- Modify: `data/src/main/ets/settings/SettingsStore.ets`
- Modify: `entry/src/main/ets/view/MeView.ets`
- Modify: `entry/src/main/module.json5`

**Policy:** 系统日历提醒优先；ReminderAgent 只在用户主动开启精确提醒时使用；周摘要默认关闭；只通知需行动的冲突或配对变化；同步成功不通知。

**Commit:** `feat(notification): apply opt-in low-noise reminders`

---

# 阶段 5：API 26、响应式、无障碍与性能

## Task 5.1：容器级响应式

**Files:**

- Create: `entry/src/main/ets/responsive/Breakpoints.ets`
- Create: `entry/src/main/ets/responsive/ResponsiveContainer.ets`
- Modify: `entry/src/main/ets/pages/Index.ets`
- Modify: `entry/src/main/ets/view/HomeView.ets`
- Modify: `entry/src/main/ets/view/CoTimeView.ets`
- Modify: `entry/src/main/ets/view/MeView.ets`
- Modify: `entry/src/main/ets/view/ScheduleHub.ets`

**Breakpoints:** compact `<600vp`、medium `600–839vp`、expanded `>=840vp`。API 26用 ContainerReader；回退使用 GridRow/mediaquery。大屏共同时间采用列表—详情双栏。

**Commit:** `feat(responsive): adapt core flows across window sizes`

## Task 5.2：组件渐进增强与动效

**Files:**

- Modify: `entry/src/main/ets/theme/DesignTokens.ets`
- Modify: `entry/src/main/ets/view/CoTimeView.ets`
- Modify: `entry/src/main/ets/pages/CourseImport.ets`
- Modify: `entry/src/main/ets/pages/CycleEditor.ets`

**Rules:** ChipV2/SegmentButtonV2 只在已验证位置替换；DatePickerComponent Beta 保留稳定 Picker 兜底；系统材质只用于 Sheet/浮层；减少动态效果时禁用错峰与位移。

**Commit:** `feat(ui): add restrained API26 progressive enhancements`

## Task 5.3：无障碍与 Senior Mode

**Files:**

- Create: `entry/src/main/ets/accessibility/AccessibilityPolicy.ets`
- Modify all core components under: `entry/src/main/ets/component/`
- Modify core views under: `entry/src/main/ets/view/`
- Modify: `docs/testing-checklist.md`

**Checks:** 44vp/48vp 热区、读屏标签、状态非纯颜色、焦点顺序、2.0x 字体、360vp、深色、减少动效、Senior Mode 低密度布局。

**Commit:** `feat(accessibility): make core flows readable and operable`

## Task 5.4：性能测量与 TaskPool 门槛

**Files:**

- Create: `feature/src/main/ets/performance/RecomputeExecutor.ets`
- Modify: `feature/src/main/ets/usecase/ScheduleCommandService.ets`
- Modify: `commons/src/main/ets/log/Logger.ets`
- Create: `docs/validation/performance-budget.md`

**Budget:** 冷启动首屏可交互、120 天重算、快照编解码、1000 窗口列表滚动分别记录 P50/P95。只有重算或编解码超过 16ms 主线程预算时迁移到 TaskPool；不得为小数据强行引入跨线程序列化。

**Commit:** `perf: enforce measured recompute and rendering budgets`

---

# 阶段 6：迁移、灰度与发布收口

## Task 6.1：升级与恢复策略

**Files:**

- Modify: `data/src/main/ets/db/MigrationRunner.ets`
- Modify: `entry/src/main/ets/entrybackupability/EntryBackupAbility.ets`
- Modify: `entry/src/main/resources/base/profile/backup_config.json`
- Create: `entry/src/ohosTest/ets/test/UpgradeMigrationTest.ets`

**Scenarios:** v1 数据升级、全新安装、迁移中断、恢复后 HUKS key 缺失、旧日历事件 ID、旧提醒 ID。恢复后无法解密时必须进入“重新配对”，不能伪装同步成功。

**Commit:** `feat(migration): protect upgrades and key-loss recovery`

## Task 6.2：功能开关与灰度回退

**Files:**

- Modify: `feature/src/main/ets/config/FeatureFlags.ets`
- Modify: `entry/src/main/ets/pages/Index.ets`
- Create: `docs/release/rollout-and-rollback.md`

**Rollout order:** newShell → calendarFlow → cloudPairing → scanPairing → newCard → responsiveV2。每个开关文档化启用条件、监控指标、关闭影响和数据兼容性。

**Commit:** `chore(release): define staged rollout and rollback controls`

## Task 6.3：旧入口与重复实现退场

**Files:**

- Modify: `entry/src/main/resources/base/profile/main_pages.json`
- Modify/remove only after usage search: obsolete routing helpers and duplicate builders under `entry/src/main/ets/`
- Modify: `docs/README.md`
- Modify: `docs/01-产品设计文档.md`
- Modify: `docs/02-技术架构设计.md`
- Modify: `docs/03-功能链路设计.md`
- Modify: `docs/04-开发计划.md`

**Steps:**

- [ ] 使用 `rg` 证明旧入口无引用后再删除。
- [ ] 不删除 ScheduleEditor/CycleEditor/CourseImport/PaintMonth/OcrCourse；只删除重复壳层和旧四 Tab 逻辑。
- [ ] 修正文档中的 Account Kit、`agconnect-services.json`、LiveView、四 Tab 和旧 API 版本陈述。
- [ ] 将 05/06 调研链接加入 README。

**Commit:** `refactor: retire obsolete shell and align project docs`

## Task 6.4：最终发布验收

**Files:**

- Modify: `docs/testing-checklist.md`
- Create: `docs/release/2026-api26-release-checklist.md`

**Matrix:** 全新安装/升级；单人/本机代录/云配对；在线/离线/云停服；通知允许/拒绝；日历允许/取消；扫码支持/不支持；360vp/横屏/大字体/Senior Mode/深色；卡片添加/更新/移除；配对解除/清本机数据/备份恢复。

**Final commands:**

```powershell
git status --short
& 'D:\local\DevEcoStudio\tools\hvigor\bin\hvigorw.bat' clean --no-daemon
& 'D:\local\DevEcoStudio\tools\hvigor\bin\hvigorw.bat' assembleHap `
  --mode module `
  -p product=default `
  -p module=entry@default `
  -p buildMode=release `
  --no-daemon
```

**Release gate:** P0 流程无阻断缺陷；功能开关关闭时纯本地版可发布；云数据库无敏感明文；隐私文案与实际权限一致；所有数据删除动作可验证。

**Commit:** `chore(release): complete API26 redesign acceptance`

---

# 阶段 6R：发布阻断整改

> 2026-09-23 全阶段独立验收判定为 `NOT RELEASE READY`。详细证据和实现约束见
> `docs/validation/2026-09-23-full-redesign-acceptance.md`。本阶段优先级高于任何新增功能。

## Task 6R.1：重构受管日历生命周期

- [x] 默认路径不再把 `editEvent` 返回值当作普通权限下可管理的事件；
- [x] 应用专属 Calendar 负责受管 `add/update/delete`；`editEvent` 若保留则标记为不可自动同步的导出；
- [x] 取消/改期/清空时保留失败状态和可重试清理信息；
- [x] 同时清理计划级 ReminderAgent 与周摘要；
- [ ] 更新状态模型、UI 徽标、隐私文案、离线测试与 API 26 真机测试。

> 2026-09-23 完成前四项与第五项的代码部分：`CalendarGateway` 按权限边界重写（`writeEvent`＝专属「同休日」日历
> `addEvent`，`exportEvent`＝`editEvent` 一次性导出）、`CalendarState` 八格 + `normalizeCalendarState` 读边界归一、
> `PlanProjectionCleanupService`/`PlanCapabilities`/`CleanupReport` 三件套、`CLEANUP_PENDING` + 「重新清理」 +
> `onForeground` 补扫、`clearAllData` 先清投影再删表并按 `clearAllMessageOf` 如实播报。
> 离线 **182 passed / 0 type error**（`PlanUseCaseTest` 重写为 19 条）、插桩 3+7 条换到新端口面（只编译）。
> **本任务最后一项故意不勾**：隐私文案改写在 Task 6R.4，真机执行属 B6 待设备——见
> `docs/validation/2026-09-23-full-redesign-acceptance.md` §9.2 与 `docs/testing-checklist.md` §6、§20.1。

## Task 6R.2：纯本地安全与权限封口

- [ ] `createInvite/joinByCode` 在任何副作用前检查 `cloudPairing`；
- [ ] 关闭态隐藏云配对/扫码/分享等级入口；
- [ ] 首发移除 `INTERNET`，保持 `cloudPairing=false / scanPairing=false`；
- [ ] 测试断言关闭态云调用、pairId、pairKey、pairState 均不变化。

## Task 6R.3：严格测试门禁

- [x] 修复离线 runner 当前 5 个 TypeScript 错误；
- [x] typecheck 失败立即非零退出，不执行部分产物；
- [x] 只有 `0 type error + 0 failed + exit 0` 才可称为全绿；
- [ ] 补取消、改期、清空、解除配对和删除伴侣的失败路径。

> 2026-09-23 前三项完成（提交 `2656341`，`tools/test/tsconfig.json` + `run.mjs` + 统一入口 `tools/verify.mjs`）。
> 第四项的前三条（取消 / 改期 / 清空的失败与残留口径）随 Task 6R.1 落地；**解除配对与删除伴侣仍无断言**——
> 前者在 `CLOUD_BLOCKED` 下无法到达（只能经 G2 那条违规路径配对），后者属阶段 3 门禁解除后的补测，见
> `docs/release/2026-api26-release-checklist.md` §2 G5 表最后两行。

## Task 6R.4：首发产品与合规收口

- [ ] 创建计划类型只展示“一起吃饭/其他”，保留旧 8 类标签映射用于兼容；
- [ ] 首发锁竖屏，横屏设备矩阵通过后再解除；
- [ ] 隐私政策全文托管并统一首启/我的/商店文案；
- [ ] 确认 bundleName、vendor、签名、备案和提审材料。

## Task 6R.5：真机验收与签名出包

- [ ] API 26 真机执行 P0 主链、权限拒绝/撤回、日历、提醒、卡片、备份恢复；
- [ ] 验证 360vp、深色、2× 字体、读屏、Senior Mode、降低透明度；
- [ ] 生成签名 release 包并记录设备、系统版本、截图、日志与执行日期；
- [ ] 独立验收 B0–B6 全关闭后才进入提审。

---

## 跨阶段验收追踪表

| 能力 | 首次交付 | 强制测试 | 降级 |
|---|---:|---|---|
| 三个首页答案 | 1 | 领域夹具 + 页面状态 | 我的空闲/录入引导 |
| 三 Tab 导航 | 1 | 返回栈/冷启动/深链 | 无四 Tab 回退 |
| 共同时间列表与周历 | 1 | 同结果、稳定 key | 列表 |
| 系统日历确认 | 2 | 成功/取消/不可用 | 本地计划 |
| 冲突与改期 | 2 | 日历迁移失败 | 待重试 |
| 云配对 | 3 | 双真机/越权/过期 | 本机代录 |
| 加密快照 | 3 | 篡改/乱序/密钥丢失 | 最后有效快照 |
| 扫码与分享 | 4 | 真机/无能力 | 短码 |
| 服务卡片 | 4 | 跨进程/过期 | App 首页 |
| 通知与提醒 | 4 | 允许/拒绝/撤销 | 应用内状态 |
| 响应式与 Senior Mode | 5 | 尺寸/字体/读屏 | compact 布局 |
| 升级与备份恢复 | 6 | v1→v2/密钥缺失 | 重新配对 |

## 设计覆盖索引

| Design spec requirement | Implementing tasks |
|---|---|
| 三入口与功能收纳 | 1.2、1.5、6.3 |
| 页面读模型与状态 | 0.2、1.1、1.3、1.4 |
| 本地事实源与版本迁移 | 0.3、2.1、6.1 |
| 配对状态与加密快照 | 0.4、3.1–3.5 |
| 日历、提醒、扫码、分享、卡片 | 2.2、4.1–4.3 |
| 温暖编辑感与动效 | 0.5、1.3–1.5、5.2 |
| 响应式、Senior Mode、无障碍 | 5.1、5.3 |
| 性能与 TaskPool 门槛 | 5.4 |
| 灰度、回滚与文档收口 | 6.2–6.4 |
| 非目标和能力排除 | Global Constraints、0.3、4.3 |

## 完成定义

整体改造只有在以下条件全部满足后才完成：

- 三个主入口与精简原型一致，旧四 Tab 不再存在；
- 首页、窗口详情、计划、日历和卡片形成一条真实数据链路；
- 本地数据在无网、无云、无权限时仍可使用；
- 配对数据端侧加密，长期密钥由 HUKS 托管；
- 云工程位置和运维方式有实测结论；
- 360vp、深色、大字体、读屏和 Senior Mode 达标；
- 所有阶段构建、自动化测试与手工验收记录齐全；
- 文档不再保留与实现相冲突的旧技术结论。
