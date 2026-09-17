# Implementation Plan: 学生情侣双人共同时间闭环

**Input**: Feature specification from `spec/student-couple-cotime/spec.md`

## Summary

打通"双份课表/班表 → 共同空闲窗口 → 共同计划 → 冲突重算"的完整产品闭环。核心手段：① 数据层为班表四表引入 `owner` 维度（ME/PARTNER）实现本机代录双人档案；② 引擎装配层把"伴侣班表+伴侣参数"接入现有纯函数管线（expand→buffer→merge→classify）；③ 补齐 STUDY 标签、冲突检测纯函数、参数真实读写；④ entry 层新增/改造页面完成 UI 闭环；⑤ 卡片/通知/云端封装按降级安全原则接入。技术路径完全复用 M0–M2 资产（领域引擎 49 单测、RDB 8 表、四条录入链路），不引入新框架与三方依赖。

## Technical Context

**Language/Version**: ArkTS（HarmonyOS NEXT，API 21 / 6.0.1，Stage 模型，strictMode）  
**Primary Dependencies**: ArkUI（@ComponentV2/@Local 等 V2 装饰器）、ArkData（relationalStore/preferences）、@kit.CoreVisionKit（既有 OCR）、@kit.CalendarKit（日历写入，新增）、Notification Kit（本地通知，新增）、Form Kit（2×2 卡片，新增）、Cloud Foundation Kit（云端封装，新增，AGC 未配置时降级）  
**State Management**: 沿用项目现有 V2（@ObservedV2/@Trace/@Local），不做迁移  
**Storage**: relationalStore RDB（8 表 + owner 列扩展）+ Preferences（参数/等级/伴侣档案/首启标记）  
**Testing**: hypium LocalUnit（domain 层既有 49 用例 + 新增用例；domain 保持零 Kit 依赖）  
**Target Platform**: HarmonyOS NEXT 手机（deviceTypes: phone）  
**Project Type**: 单 HAP + 分层 HAR（既有工程结构）  
**Performance Goals**: 120 天 × 2 人共同计算 <200ms（本地运行器口径）；月历/列表滑动流畅  
**Constraints**: domain HAR 禁止 import @kit.* 与 data 层；单人功能 100% 离线；云端仅存密文快照（本特性只交付端侧封装）  
**Scale/Scope**: entry 新增/改造页面约 10 个 ArkTS 文件；domain 新增 2 个纯函数模块 + 用例；data/feature 各扩展既有文件

## Project Structure

### Documentation (this feature)

```text
spec/student-couple-cotime/
├── spec.md              # 特性规格
├── plan.md              # 本文件
└── tasks.md             # 任务清单
```

### Source Code (repository root)

```text
CommonRestday/
├─ domain/src/main/ets/
│  ├─ classify/WindowClassifier.ets        # 改：STUDY 标签
│  ├─ engine/CommonFreeEngine.ets          # 改：buildPartnerAvailability 辅助
│  ├─ conflict/PlanConflict.ets            # 新：冲突检测 + 替代窗口纯函数
│  └─ model/Types.ets                      # 改：WindowTag.STUDY、Owner 常量
├─ domain/src/test/
│  ├─ ClassifierTest.ets                   # 改：STUDY 用例
│  ├─ ConflictTest.ets                     # 新：冲突检测用例
│  └─ EngineTest.ets                       # 改：双人装配用例
├─ data/src/main/ets/
│  ├─ db/Db.ets                            # 改：owner 列 DDL
│  ├─ repo/ScheduleRepo.ets                # 改：owner 参数化
│  └─ settings/SettingsStore.ets           # 改：伴侣参数/伴侣昵称/隐私已读标记
├─ feature/src/main/ets/usecase/
│  ├─ ScheduleUseCase.ets                  # 改：参数真实读写、伴侣装配、冲突回写、事件重算入口
│  └─ PlanUseCase.ets                      # 新：计划创建/取消/日历/提醒编排
├─ entry/src/main/ets/
│  ├─ entryability/EntryAbility.ets        # 改：隐私弹窗标记初始化
│  ├─ entryformability/FormAbility.ets     # 新：卡片扩展
│  ├─ widget/RestCard2x2.ets               # 新：2×2 卡片
│  ├─ view/HomeView.ets                    # 改：我们/单人双语义三卡
│  ├─ view/CoTimeView.ets                  # 新：共同时间页（窗口列表+筛选）
│  ├─ view/PlansView.ets                   # 改：计划列表+取消+冲突标红
│  ├─ view/MeView.ets                      # 改：参数编辑/等级切换/伴侣管理
│  ├─ view/ScheduleHub.ets                 # 改：我/伴侣双侧入口
│  ├─ component/PrivacyDialog.ets          # 新：首启隐私弹窗
│  ├─ component/WindowDetailSheet.ets      # 新：窗口详情+创建计划
│  ├─ pages/PartnerCourseImport.ets        # 新：伴侣课表导入（复用 CourseImport 逻辑）
│  ├─ pages/PaintMonth.ets                 # 改：支持 owner 参数
│  ├─ pages/CourseImport.ets               # 改：支持 owner 参数
│  ├─ pages/CycleEditor.ets                # 改：保存后触发重算
│  └─ pages/ScheduleEditor.ets             # 改：nightMode 开关暴露
├─ cloud/src/main/ets/api/CloudApi.ets     # 改：云端配对调用封装 + 降级逻辑
└─ entry/src/main/resources/               # 卡片/页面资源（不新增 ets 外资源目录）
```

**Structure Decision**: 本计划**遵循既有项目架构**（单 HAP + 分层 HAR：entry → feature → domain/data/cloud → commons，domain 零 Kit 依赖），不引入 MVVM 迁移。新增文件仅在职责明确不可并入既有文件时创建（ConflictTest/PlanConflict/PlanUseCase/卡片/新页面）；其余全部为对既有文件的增量修改，符合"最小可行文件拆分"原则。

## Complexity Tracking

| Violation | Why Needed | Simpler Alternative Rejected Because |
|-----------|------------|-------------------------------------|
| 新增 conflict/ 独立目录 | 冲突检测是 PRD F7 的独立可测纯函数域 | 并入 engine 会污染"展开→缓冲→合并→分类"单一职责管线，且 engine 门面已 108 行 |
| entry 页面数较多（10 个文件） | 9 个用户故事覆盖配对/共同时间/计划/设置/卡片五大页面域 | 合并页面会形成 1000+ 行巨石组件，违背 V2 状态分治与可维护性 |

## Research & Decisions

- **Decision**: 本机代录用 `owner` 列（ME/PARTNER）扩展既有四表，而非建平行的 partner_* 四表。  
  **Rationale**: Repo/展开器/页面逻辑全部参数化复用，改动面最小；表数量不翻倍；删除伴侣 = 按 owner 删除。  
  **Alternatives considered**: 平行表（代码复制量大）；单表加 is_partner 布尔（语义弱，扩展第三角色困难）。

- **Decision**: 伴侣忙区间构建走与"我"完全相同的 expand→buffer 管线，用伴侣自己的 EngineParams；云端快照路径保留为第二来源（互斥，快照优先）。  
  **Rationale**: 快照生成时已并入对方缓冲，接收侧不二次加缓冲；本机代录无快照，必须本地展开。两条路径在 EngineInput 汇合，领域层不感知来源差异。  
  **Alternatives considered**: 强制所有伴侣数据先序列化为快照再解码（多余往返，损失 L3 精度）。

- **Decision**: STUDY 标签判定 = 窗口 ≥2h 且窗口起点与主体落在周一至周五 08:00–21:00（与 PRD v1.1 F4 表格一致），实现为 classifier 中与 MEAL 同级的独立判定函数，参数（studyStart/studyEnd/studyMin）进 EngineParams 默认值。  
  **Rationale**: 保持"参数可注入"的既有分类器风格；口径已在 PRD 固化可回归。  
  **Alternatives considered**: 硬编码常量（违背分类器可配置惯例）。

- **Decision**: 冲突检测为 domain 纯函数：输入（活跃计划列表、排除计划自身后的双方忙区间并集、当前窗口列表），输出每个计划的冲突布尔 + 替代窗口（时长 ≥ 计划时长且最接近的后续窗口）。  
  **Rationale**: PRD v1.1 L11 冲突判定口径；纯函数可单测；重算编排层（feature）负责回写 plan.status。  
  **Alternatives considered**: 在引擎主管线内检测（污染"计算窗口"单一职责；计划本就作为忙碌输入参与计算，需二次求补）。

- **Decision**: 事件驱动重算采用"保存动作后同步调用 usecase 重算 + AppStorage 广播计数"轻量方案，不引入 emitter 三方库。  
  **Rationale**: 计算毫秒级，同步可接受；V2 状态用 @Monitor/@Prop 感知计数变化刷新。  
  **Alternatives considered**: 复杂发布订阅（过度工程）。

- **Decision**: 2×2 卡片只做"读 computed_window 缓存 → formProvider.updateForm"，不做卡片内计算；module.json5 增加 form 扩展声明。  
  **Rationale**: 架构文档 L12 链路设计；杀进程后卡片仍显示最后缓存。  
  **Alternatives considered**: 卡片拉起 Ability 计算（违背无后台常驻约束）。

- **Decision**: Calendar Kit 写入以"同休日"专属日历为目标，权限拒绝/调用失败一律 try-catch 降级为"仅本地计划"，不阻塞计划创建。  
  **Rationale**: PRD F6 验收与架构文档错误处理总表；模拟器无日历账号场景多，降级路径是主路径。  
  **Alternatives considered**: 权限拒绝时禁用计划创建（违背"计划仍创建"验收）。

- **Decision**: 云端配对交付"邀请码生成（本地随机 6 位）+ Cloud Foundation Kit 调用封装 + AGC 未初始化降级"，云函数侧代码与部署不在本特性。  
  **Rationale**: AGC 开通为账号侧前置（风险 R9）；端侧封装就绪后开通即可联调。  
  **Alternatives considered**: 完整云函数实现（无 AGC 凭据无法验证，违背"符合客观实际"）。

## Data Model

### RDB 变更（dev 阶段直接改建表 DDL，无存量用户迁移负担）

- `shift_type` / `cycle_template` / `course`：新增 `owner TEXT NOT NULL DEFAULT 'ME'`。
- `schedule_override`：新增 `owner TEXT NOT NULL DEFAULT 'ME'`，主键改为 `(owner, epoch_day)` 复合主键。
- `plan`：新增列 `conflict_hint TEXT`（冲突提示/替代窗口 JSON，可空）。
- 其余表不变；所有查询按 owner 过滤。

### Preferences 新增键

- `partner_profile`：JSON `{ nick: string, params: EngineParams }`（伴侣昵称 + 独立引擎参数）。
- `privacy_accepted`：boolean（首启隐私弹窗已同意标记）。
- 既有键沿用：`engine_params`（我的参数）、`share_level`、`pair_state`、`snap_ver`。

### domain 类型变更

- `WindowTag` 增加 `STUDY`。
- `EngineParams` 增加 `studyStartMin`(480)、`studyEndMin`(1260)、`studyMinMin`(120) 默认值。
- 新增 `ConflictOutcome { planId, conflict: boolean, alternative?: Window }`（或等价结构）。

## Contracts & Interfaces

### domain（纯函数，零 Kit）

- `WindowClassifier.classifyWindows(...)`：行为扩展——STUDY 判定；签名不变或仅增可选参数。
- `CommonFreeEngine.buildPartnerAvailability(partner: MySchedule 形态, params, start, days)`：与 buildMyAvailability 同构的伴侣忙区间构建（或参数化复用同一函数）。
- `PlanConflict.detectConflicts(plans: Plan[], busyUnionExcludingPlans: Interval[], windows: Window[]): ConflictOutcome[]`——排除计划自身占用后的交叠判定 + 替代窗口推荐。
- `findAlternativeWindow(plan, windows)`：时长 ≥ 计划时长、起点晚于计划起点、时长最接近者优先。

### data

- `ScheduleRepo` 全部班表方法增加 owner 参数（默认 'ME' 保持兼容）；新增 `deletePartnerData()`（级联清除 owner=PARTNER 数据）。
- `SettingsStore`：`getPartnerProfile()/savePartnerProfile()/clearPartnerProfile()`、`isPrivacyAccepted()/acceptPrivacy()`；`getParams/setParams` 接线真实读写。

### feature

- `ScheduleUseCase`：`recompute()` 装配伴侣输入（本机代录路径）；`onScheduleChanged()` 事件重算统一入口（更新 AppStorage 计数）；`loadMySchedule(owner)` 参数化。
- `PlanUseCase`（新）：`createPlan(window, title, kind, startMin, endMin)`（窗口硬限制校验 + Calendar Kit 尽力写入 + 通知提醒注册 + 触发重算）；`cancelPlan(id)`（确认后级联删日历事件 + 取消提醒 + 触发重算）。

### entry

- `Index.ets`：挂 PrivacyDialog（未同意时拦截）；Tabs 增加"共同"页（CoTimeView）或改造现有结构。
- `FormAbility` + `RestCard2x2`：卡片 formData = `{ days: number, summary: string }`，postCardAction 路由首页。
- `module.json5`：新增 `READ_CALENDAR/WRITE_CALENDAR` 权限声明（user_grant，用到才弹）+ FormExtensionAbility 声明。
