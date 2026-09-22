# 同休日整体项目改造设计

**日期：** 2026-09-21  
**状态：** 已确认  
**目标原型：** `docs/prototype/index.html` 的精简版、01「温暖编辑感」方向  
**实施计划：** `docs/superpowers/plans/2026-09-21-overall-project-redesign.md`

## 1. 设计依据与优先级

本设计只以以下材料为直接依据，旧文档仅作为历史背景：

1. `docs/plans/2026-09-21-warm-editorial-prototype-design.md`：视觉和交互目标；
2. `docs/prototype/index.html` 精简版：页面结构、信息密度和交互样例；
3. `docs/05-云端配对前置条件调研.md`：Cloud Foundation、CloudProgram、云函数与云数据库的工程约束；
4. `docs/06-API26能力与精简版优化调研.md`：API 26 及以下能力的取舍与渐进增强策略；
5. 当前代码与测试：只用于识别可复用资产和迁移成本，不反向限制目标设计。

发生冲突时遵循：用户已确认的精简原型 > 本设计 > 05/06 调研结论 > 旧产品与开发文档 > 当前代码表现。

## 2. 核心决策

### 2.1 精简版成为唯一正式主框架

不在 ArkUI 中长期维护“完整版/精简版”双模式。正式应用采用三个底部入口：

- 首页；
- 共同时间；
- 我的。

现有“班表”主 Tab 迁入“我的 → 我的日程”。OCR、月历涂抹、课程高级设置和算法参数不立即删除，但降为二级或高级入口。

### 2.2 精简认知负担，不削弱底层能力

首页只给结论、依据摘要和下一步动作。共同时间页负责比较与筛选；日程页负责输入；高级参数只在必要时显现。现有领域引擎、RDB 数据和冲突算法优先复用。

### 2.3 本地优先，云端增强

- 本地 RDB 是日程与计划的事实源；
- 云端只保存可重建的加密忙碌快照；
- 云端不可用时继续使用本机代录或最后一次有效快照；
- 页面不得因配对、同步、扫码、通知或日历权限失败而失去核心功能。

### 2.4 分阶段可发布

每一阶段都必须能构建、测试、安装和回滚。云配对、卡片、扫码、通知和 API 26 增强分别由功能开关控制，不组成一个不可拆分的大版本。

## 3. 目标信息架构

```text
首页
├─ 今晚/明晚能一起吃饭吗
├─ 下个完整同休日
├─ 最近能否出行
├─ 下一段共同时间
├─ 计划冲突与变化
└─ 今日双方概览

共同时间
├─ 窗口 / 计划
├─ 列表 / 周时间带
├─ 场景筛选
├─ 窗口详情 Sheet
└─ 创建计划 → 系统日历确认

我的
├─ 伴侣与配对
├─ 我的日程
│  ├─ 班次类型
│  ├─ 循环模板
│  ├─ 课程
│  ├─ 临时调整
│  └─ 辅助录入
├─ 作息与计算偏好
└─ 数据、隐私与同步
```

计划继续位于“共同时间”的分段内；不新增第四个主 Tab。

## 4. 目标模块边界

```text
domain   纯模型、区间计算、分类、冲突、快照协议
data     RDB、Preferences、Schema 迁移、仓储
cloud    配对协议、HUKS 密钥门面、加密快照、云函数客户端
feature  页面读模型、业务命令、同步编排、系统能力门面
entry    Navigation、页面、组件、响应式、权限触发
commons  设计令牌之外的通用格式化、日志、常量
```

现有 `ScheduleUseCase` 逐步拆分，而不是一次性重写：

- `CommonTimeQueryService`：只读查询与首页答案组装；
- `ScheduleCommandService`：录入变化、事务、重算与刷新广播；
- `PairingSyncService`：配对、推拉、版本和失败恢复；
- `SystemIntegrationService`：日历、通知、分享、扫码能力门面。

UI 不直接查询多个仓储并自行拼装业务结论。`entry` 只消费 `feature` 暴露的页面读模型。

## 5. 页面读模型与状态

### 5.1 首页

`HomeSummary` 至少包含：

```ts
interface HomeSummary {
  mode: 'SOLO' | 'LOCAL_PARTNER' | 'PAIRED';
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
```

`QuickAnswer` 必须同时包含稳定枚举和展示文本，禁止 UI 通过中文文案反推业务状态。三类答案的口径由领域测试固定。

### 5.2 共同时间

`CommonTimePageState` 包含窗口、计划、筛选、视图模式、更新时间和错误。窗口行使用稳定 `start + end + classification` 作为 key；不以数组下标作为 key。

### 5.3 配对与同步

配对状态统一为：

```text
UNPAIRED → CREATING / JOINING → WAITING_CONFIRMATION
          → PAIRED
          → SYNC_PENDING / SYNCING / SYNC_ERROR
          → UNPAIRING → UNPAIRED
```

`pairState` 与 `syncState` 分离。已配对但离线属于 `PAIRED + SYNC_PENDING`，不能错误显示为未配对。

所有主页面至少覆盖：首次加载、有效内容、无数据、部分数据、可恢复错误和不可恢复错误。旧缓存存在时，刷新错误不清空已有内容。

## 6. 数据与迁移设计

### 6.1 本地数据

继续使用现有表：`shift_type`、`cycle_template`、`schedule_override`、`course`、`term_config`、`plan`、`computed_window`、`sync_meta`。

新增或迁移：

- `plan.updated_at`：计划最后修改时间；
- `plan.calendar_state`：`NOT_REQUESTED/PENDING/WRITTEN/DECLINED/FAILED/REMOVED`；
- `plan.sync_state`：`LOCAL_ONLY/PENDING/SYNCED/ERROR`；
- `computed_window.computed_at`：缓存新鲜度；
- `computed_window.channel`：`REGULAR/TRIP`，避免 UI 从标签猜测计算通道；
- `sync_meta` 保存 schema 版本、最后成功同步时间、待上传版本和最后错误码。

数据库升级必须通过显式 `MigrationRunner` 顺序执行，不再依赖“ALTER 失败就忽略”。迁移必须幂等，并在事务内完成。

### 6.2 Preferences

只存轻量偏好：作息参数、共享等级、提醒开关、配对展示状态、最近同步时间、功能开关和隐私同意。不得存放：

- 班表数组；
- 云快照明文；
- 长期 AES 密钥；
- HUKS 私钥；
- 邀请码历史。

### 6.3 云端快照

云端对象最小字段：

```text
pairId       明文，规则与查询所需
ownerUid     明文，规则与查询所需
version      单调递增
shareLevel   共享语义版本
ciphertext   AES-GCM 密文与认证信息
iv           每次随机
schemaVersion
updatedAt
```

单对象必须远低于 2MB。快照只包含忙碌区间和计算所需的最小作息语义，不包含班次名、课程名、地点、备注或计划标题。

## 7. 配对与密钥安全裁决

当前 `SnapshotCrypto.deriveKeyHex(code)` 和 Preferences 中的 `pair_key` 仅可用于原型验证，禁止直接作为生产实现。六位码熵不足，Preferences 也不是长期密钥容器。

正式设计采用 HUKS 托管的设备密钥协商：

1. 创建方生成 HUKS 非导出密钥对，上传公钥和一次性会话；
2. 二维码、分享链接或短码只携带短时一次性 token，不携带长期密钥；
3. 加入方生成自己的 HUKS 密钥对并提交公钥；
4. 双方确认后，以 ECDH 共享秘密和 `pairId` 作为上下文，经 HKDF 生成快照密钥；
5. 快照密钥保留在 HUKS 别名下，应用不把裸密钥写入 Preferences 或日志；
6. 解除配对时删除 HUKS 别名、会话 token、快照游标和云端记录。

阶段 0 必须先在 API 26 真机验证 HUKS ECDH/HKDF/AES-GCM 可用组合。若 SDK 限制不允许完整链路，阶段 3暂停发布，不得退回“短码直接当长期密钥”。

没有可靠最终用户身份时，客户端不得直接读写云数据库。所有访问经云函数完成，云数据库端侧规则默认拒绝；云函数以 HUKS 持有的设备凭据或会话凭据验证 pair 成员。若阶段 0证明 Cloud Foundation 能稳定提供可用于规则的 `request.auth.uid`，才可评估开放端侧只读路径。

## 8. 云工程策略

现有根目录是多 HAR 纯端侧工程，而 CloudDev 模板要求 `Application + CloudProgram`。因此：

- 阶段 0在一次性实验工程验证共存方式；
- 验证通过才在当前仓库加入 `CloudProgram`；
- 若必须重排根目录，优先保留当前应用工程不动，把云端作为独立部署工程，并以接口契约连接；
- 任何方案都不得为了接云端破坏现有多模块依赖和本地构建。

云函数采用 Node.js 20，每个函数独立部署，调用超时显式设为不超过 55 秒。所有创建、加入、上传与解除操作带幂等键。

## 9. 系统能力策略

| 能力 | 用法 | 默认策略 | 降级 |
|---|---|---|---|
| Navigation/NavDestination | 主导航与二级页 | P0 | 不回退旧 router 混用 |
| bindSheet | 窗口详情、筛选、轻编辑 | P0 | 大屏可转侧栏 |
| CalendarManager.editEvent | 用户确认计划 | 默认 | 保留本地计划 |
| RDB Transaction | 批量录入与迁移 | 强制 | 失败整体回滚 |
| TaskPool | 重算、编解码评估 | 达到阈值后启用 | 小数据同步执行 |
| Form Kit | 最近共同时间 | P1 | App 内首页 |
| Scan Kit | 面对面配对 | 能力检测后显示 | 短码/分享 |
| Share Kit | 邀请与窗口摘要 | 用户主动触发 | 复制短码 |
| Notification Kit | 需行动的变化 | 用户开启 | 应用内提示 |
| ReminderAgent | 明确选择的精确提醒 | 非默认 | 系统日历提醒 |
| WorkScheduler | 待同步机会补偿 | 非准点任务 | 前台同步 |
| ChipV2/SegmentButtonV2 | 筛选与分段 | 验证后增强 | 普通 Chip/Segment |
| ContainerReader | 容器级响应式 | API 26 | GridRow/mediaquery |
| Senior Mode | 降密度、大热区 | API 26增强 | 大字体规则 |

明确排除：LiveView、全页面玻璃材质、后台常驻、WorkScheduler 准点提醒、分布式 KV 跨账号同步、静默批量写日历和每次同步通知。

## 10. 视觉、响应式与动效

### 10.1 视觉

- 暖象牙纸面背景、深莓红主色、低透明颗粒；
- 标题使用编辑感衬线字体回退链，正文使用 HarmonyOS Sans；
- 减少白卡叠加和重阴影，使用留白、细分隔和错角形状建立层级；
- 深莓色 Hero 只用于最重要结果，不铺满所有模块；
- 采用“温暖影像 + 选择性玻璃”：低对比影像只作气氛层，纸面承载密集内容，系统材质仅用于 Sheet、浮动底栏和首页唯一主结果；
- 禁止全页面玻璃、滚动列表实时模糊和复杂照片上直接压正文；材质不可用或降低透明度时必须回退近实色纸面。

颜色、字号、间距、圆角、阴影和动效时长集中在资源和 `DesignTokens.ets`，页面不得新增散落的品牌色字面量。

完整的分层、组件范围、API 26 双路径、性能与验收规则见 `docs/plans/2026-09-22-warm-image-glass-visual-spec.md`，该文件是视觉增强实施的直接依据。

### 10.2 响应式

- `< 600vp`：单列、底部导航、Sheet；
- `600–839vp`：内容最大宽度 + 局部双列；
- `>= 840vp`：列表—详情双栏，主导航可转侧栏；
- 大字体下以内容重排优先，不压缩字号，不依赖固定高度。

首版 manifest 仍可只声明 phone；平板/折叠屏声明扩展必须在真实设备验收后单独提交。

### 10.3 动效

统一使用 `cubic-bezier(.22, 1, .36, 1)`；页面进入 500–800ms，列表轻微错峰，按压 0.98，主要只动画 opacity 与 transform。开启减少动态效果时禁用错峰与位移。

## 11. 无障碍与权限

- 触控热区至少 44vp，Senior Mode 下至少 48vp；
- 状态不能只靠颜色表达；
- 图标按钮必须有可读标签；
- 焦点顺序与视觉顺序一致；
- 关键变更通过可访问提示宣布，但不重复朗读装饰文本；
- 日历、通知、相机只在用户触发对应动作时解释并请求；
- 拒绝后保留完整降级路径，不在每次进入页面时重新请求。

## 12. 阶段与依赖

```text
阶段 0 基线与风险验证
  ↓
阶段 1 三入口与本地答案闭环
  ↓
阶段 2 共同时间—计划—日历闭环
  ├─→ 阶段 3 云端配对与加密同步
  └─→ 阶段 4 卡片、扫码、分享与通知
          ↓
阶段 5 API 26、响应式、无障碍与性能
          ↓
阶段 6 迁移、灰度、旧功能退场与发布
```

阶段 3和阶段 4可在阶段 2稳定后并行开发，但必须独立发布和关闭。

## 13. 全局验收原则

每个阶段同时满足以下条件才算完成：

- 单元测试、组件测试和适用的真机检查通过；
- 新增失败路径有用户可理解的状态；
- 云端或系统权限失败不破坏本地核心流程；
- 数据迁移可重复执行且不丢数据；
- 页面符合 360vp、大字体、深色模式和基础读屏要求；
- 文档、接口和测试数据同步更新；
- 功能开关关闭时能回到上一稳定版本行为。

## 14. 非目标

本轮不包含三人群组、企业排班、薪资、健康建议、社交社区、酒店天气推荐、AI 陪伴、手表应用、实时多人编辑、Push 实时同步、Live Form、Intents Kit 和跨设备接续。这些能力不得借“顺手优化”进入任一阶段。
