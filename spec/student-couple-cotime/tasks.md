# Tasks: 学生情侣双人共同时间闭环

**Input**: Design documents from `spec/student-couple-cotime/`
**Prerequisites**: plan.md, spec.md（均已就绪）
**Tests**: 是——domain 层保持 TDD（既有 49 用例不可回归，新功能先补用例）。

## Format: `[ID] [P?] [Story] Description`

- **[P]**: 可并行（不同文件、无未完成依赖）
- **[Story]**: 对应 spec.md 用户故事

## Path Conventions

- 多模块工程：路径直接写模块相对根的完整路径（如 `domain/src/main/ets/model/Types.ets`、`entry/src/main/ets/view/HomeView.ets`）。
- `PROJECT_ROOT` = `E:\desktop\Code\harmony\CommonRestday`。

## Parallel Example: Phase 2

```text
Task: T003 domain 类型扩展（domain/src/main/ets/model/Types.ets）
Task: T004 data DDL owner 列（data/src/main/ets/db/Db.ets）      # 与 T003 并行
Task: T007 STUDY 标签（domain/src/main/ets/classify/WindowClassifier.ets）  # 与 T004 并行
Task: T008 冲突纯函数（domain/src/main/ets/conflict/PlanConflict.ets）     # 与 T004 并行
```

---

## Phase 1: Setup (Shared Infrastructure)

- [ ] T001 全量阅读 docs/01-04（v1.1 修订版）与 spec/student-couple-cotime/{spec,plan}.md，确认既有代码结构（entry/feature/domain/data/cloud 分层 HAR）
- [ ] T002 运行基线构建 `build_project`（modules: entry）确认起点零 error，运行既有 domain 单测确认 49 用例基线

## Phase 2: Foundational (Blocking Prerequisites)

**⚠️ CRITICAL**: 本阶段完成前不得开始用户故事

- [x] T003 [P] domain/model/Types.ets：WindowTag 增加 STUDY；EngineParams 增加 studyStartMin=480/studyEndMin=1260/studyMinMin=120 默认值；增加 Owner 常量与 ConflictOutcome 类型（domain/src/main/ets/model/Types.ets）
- [x] T004 [P] data/db/Db.ets：班表四表 DDL 增加 owner 列（schedule_override 改复合主键 (owner, epoch_day)）；plan 表增加 conflict_hint 列（data/src/main/ets/db/Db.ets）
- [x] T005 data/repo/ScheduleRepo.ets：全部班表方法 owner 参数化（默认 'ME'）；新增 deletePartnerData() 级联清除；plan 方法支持 conflict_hint 读写（data/src/main/ets/repo/ScheduleRepo.ets）
- [x] T006 data/settings/SettingsStore.ets：新增 getPartnerProfile/savePartnerProfile/clearPartnerProfile、isPrivacyAccepted/acceptPrivacy；确认 getParams/setParams 真实持久化读写（data/src/main/ets/settings/SettingsStore.ets）
- [x] T007 [P] domain/classify/WindowClassifier.ets：STUDY 标签判定（≥studyMinMin 且窗口主体落在周一至周五 studyStartMin–studyEndMin）（domain/src/main/ets/classify/WindowClassifier.ets）
- [x] T008 [P] domain/conflit 或 conflict/PlanConflict.ets：新增 detectConflicts 与 findAlternativeWindow 纯函数（domain/src/main/ets/conflict/PlanConflict.ets）
- [x] T009 domain 单测：ClassifierTest 补 STUDY 用例（工作日白天命中/周末不命中/夜间不命中/时长不足不命中）；新增 ConflictTest（交叠检出/排除自身/无冲突/替代窗口排序/无替代返回空）（domain/src/test/ClassifierTest.ets、domain/src/test/ConflictTest.ets）
- [x] T010 domain/engine/CommonFreeEngine.ets：buildMyAvailability 参数化复用为按 owner 构建任意一方忙区间；EngineTest 补双人装配用例（双课表交叠切除/伴侣全闲/伴侣参数独立生效）（domain/src/main/ets/engine/CommonFreeEngine.ets、domain/src/test/EngineTest.ets）
- [x] T011 feature/usecase/ScheduleUseCase.ets：引擎参数真实读写 SettingsStore（修复硬默认断链）；loadMySchedule(owner) 参数化；recompute 装配伴侣（本机代录路径：伴侣班表+伴侣参数，云端快照路径预留互斥分支）；term_config.section_times 读取接线（修复存而不读）；新增 onScheduleChanged() 事件重算入口 + AppStorage 重算计数广播；重算后调用冲突检测回写 plan 状态与 conflict_hint（feature/src/main/ets/usecase/ScheduleUseCase.ets）
- [x] T012 运行 domain 单测全绿（≥49+新增）+ `build_project` 编译通过（阶段验收门）

## Phase 3: User Story 1 - 本机代录双课表，算出共同窗口 (Priority: P1) 🎯 MVP

**Goal**: 伴侣档案 + 双侧课表录入 + 共同时间页（窗口列表 + 标签筛选含 STUDY）
**Independent Test**: 两份含单双周差异课表录入后共同时间页出现正确窗口；删除伴侣回退单人。

- [X] T013 [US1] entry/view/MeView.ets 或新伴侣管理区块：添加/编辑/删除伴侣档案（昵称+伴侣参数），删除级联 deletePartnerData 并重算（entry/src/main/ets/view/MeView.ets）
- [X] T014 [US1] entry/view/ScheduleHub.ets：改造为"我/伴侣"双侧入口（伴侣侧复用循环/涂抹/课表/班次编辑四链路，携带 owner 路由参数）（entry/src/main/ets/view/ScheduleHub.ets）
- [X] T015 [US1] entry/pages/CourseImport.ets、PaintMonth.ets、CycleEditor.ets、ScheduleEditor.ets：接收 owner 路由参数（默认 ME），按 owner 读写；ScheduleEditor 暴露 nightMode 强制夜班开关（entry/src/main/ets/pages/ 下四文件）
- [X] T016 [US1] entry/view/CoTimeView.ets（新）：共同时间页——窗口列表（日期/起止/时长/标签 chips）+ 筛选器（全部/≥2h/半天/完整同休日/共同周末/共同自习/旅行）+ 空态（无伴侣引导/无窗口建议）；监听重算计数刷新（entry/src/main/ets/view/CoTimeView.ets）
- [X] T017 [US1] entry/pages/Index.ets：Tabs 接入 CoTimeView（"共同"Tab），路由表登记新页面（entry/src/main/ets/pages/Index.ets、entry/src/main/resources/base/profile/main_pages.json）
- [X] T018 [US1] US1 验收：双份单双周差异课表 → 共同窗口正确；删除伴侣回退；`build_project` 编译通过

## Phase 4: User Story 2+3 - 参数生效与首页"我们"三卡 (Priority: P1)

**Goal**: 参数可改且生效；首页三卡共同/单人双语义
**Independent Test**: 改就寝时间后今晚卡变化；双课表下三卡来自共同窗口。

- [X] T019 [US2] entry/view/MeView.ets：我的引擎参数编辑 UI（起床/就寝/收整/视界，含合法范围校验），保存持久化并触发重算（entry/src/main/ets/view/MeView.ets）
- [X] T020 [US2] 伴侣参数编辑 UI（伴侣档案区块内，独立于我的参数），保存后重算生效（entry/src/main/ets/view/MeView.ets）
- [X] T021 [US3] entry/view/HomeView.ets：三卡双语义——有伴侣数据读共同窗口缓存（今晚/下个完整同休日倒计时/最长出行窗口），无伴侣显示"我的空闲"+添加伴侣引导卡；视界取参数值（修复硬编码 120）；监听重算计数刷新（entry/src/main/ets/view/HomeView.ets）
- [X] T022 [US2][US3] 验收：参数修改→首页变化；单/双人语义切换正确；`build_project` 编译通过

## Phase 5: User Story 4 - 首启隐私弹窗与隐私等级 (Priority: P1)

**Goal**: 合规首启拦截 + 等级切换
**Independent Test**: 未同意标记时启动必弹；等级切换持久化。

- [X] T023 [P] [US4] entry/component/PrivacyDialog.ets（新）：隐私政策弹窗（同意/拒绝），拒绝退出应用，同意写 acceptPrivacy（entry/src/main/ets/component/PrivacyDialog.ets）
- [X] T024 [US4] entry/pages/Index.ets：启动时依据 isPrivacyAccepted 决定是否挂载弹窗拦截（entry/src/main/ets/pages/Index.ets）
- [X] T025 [US4] entry/view/MeView.ets：隐私等级 L1/L2/L3 切换 UI（含"改后对方可见内容"对照说明文案）+ setShareLevel 持久化（entry/src/main/ets/view/MeView.ets）
- [X] T026 [US4] 验收：首启弹窗流程 + 等级持久化；`build_project` 编译通过

## Phase 6: User Story 5+6 - 共同计划与冲突重算 (Priority: P2)

**Goal**: 窗口→计划闭环 + 改课表自动重算/冲突提示
**Independent Test**: 创建计划占用时段；改课表后计划标红且附替代窗口。

- [X] T027 [US5] feature/usecase/PlanUseCase.ets（新）：createPlan（窗口内硬限制校验 + RDB 写入 + Calendar Kit 尽力写入"同休日"日历 try-catch 降级 + 本地提醒注册 + 触发重算）；cancelPlan（确认后级联删日历事件 + 取消提醒 + 状态 CANCELLED + 触发重算）（feature/src/main/ets/usecase/PlanUseCase.ets）
- [X] T028 [US5] entry/src/main/module.json5：声明 READ_CALENDAR/WRITE_CALENDAR 权限（user_grant）（entry/src/main/module.json5）
- [X] T029 [US5] entry/component/WindowDetailSheet.ets（新）：窗口详情半模态——时间轴可视化 + 计划类型选择 + 起止调节（硬限制窗口内）+ 保存（entry/src/main/ets/component/WindowDetailSheet.ets）
- [X] T030 [US5] entry/view/CoTimeView.ets：窗口条目点击弹出 WindowDetailSheet；entry/view/PlansView.ets：计划列表改造（状态色：正常/冲突红点+替代窗口提示/已取消置灰）+ 取消确认弹窗（entry/src/main/ets/view/CoTimeView.ets、entry/src/main/ets/view/PlansView.ets）
- [X] T031 [US6] entry/pages/PaintMonth.ets、CourseImport.ets、CycleEditor.ets、ScheduleEditor.ets：全部保存动作后调用 onScheduleChanged() 自动重算（含 ME/PARTNER 两侧）（entry/src/main/ets/pages/ 下四文件）
- [X] T032 [US6] 冲突链路验收：制造与计划交叠的课表改动→自动重算→计划标红+替代窗口；无冲突时静默；`build_project` 编译通过

## Phase 7: User Story 7+8+9 - 卡片/通知/云端封装 (Priority: P3)

**Goal**: 2×2 卡片、计划提醒、云端配对降级封装
**Independent Test**: 卡片添加成功且读缓存；通知降级不崩溃；云端入口降级提示。

- [X] T033 [P] [US8] PlanUseCase 内本地通知注册/取消（requestEnableNotification 引导 + reminder/notification API try-catch 降级）（feature/src/main/ets/usecase/PlanUseCase.ets）
- [X] T034 [P] [US7] entry/src/main/module.json5：FormExtensionAbility 声明 + 2x2 卡片 metadata；entry/src/main/ets/entryformability/FormAbility.ets（新）+ entry/src/main/ets/widget/RestCard2x2.ets（新）：读 computed_window 缓存组装 formData（倒计时天数+次窗口摘要），postCardAction 路由首页；未配对显示"我的下次休息"（entry/src/main/module.json5、entry/src/main/ets/entryformability/FormAbility.ets、entry/src/main/ets/widget/RestCard2x2.ets、entry/src/main/resources/base/profile/form_config.json 或等价配置）
- [X] T035 [P] [US9] cloud/src/main/ets/api/CloudApi.ets：邀请码生成（本地随机 6 位）+ Cloud Foundation Kit cloudFunction 调用封装（try-catch，AGC 未初始化返回降级错误码）；entry 添加伴侣页云端入口按钮：调用失败/未就绪→提示并引导本机代录（cloud/src/main/ets/api/CloudApi.ets、entry/src/main/ets/view/MeView.ets）
- [X] T036 [US7][US8][US9] 验收：卡片/通知/云端降级三链路编译与逻辑走查；`build_project` 编译通过

## Phase 8: Polish & Cross-Cutting Concerns

- [X] T037 修复 oh-package.json5 各 HAR description 乱码（UTF-8 重写中文描述）（各模块 oh-package.json5）
- [X] T038 entry 各新页面文案与颜色尽量走资源引用（新增/改动部分，存量不强制重构）；深色模式适配新增页面（entry/src/main/resources/）
- [X] T039 domain/data/feature 全量 grep 校验：domain 无 @kit import、无 data 层 import；孤儿 API（upsertPlan/updatePlanStatus）确认已有调用方或删除（各 HAR 源码）
- [X] T040 docs/04-开发计划.md 进度表追加本里程碑完成记录（docs/04-开发计划.md）

## Phase 9: Verification

<!-- verification_scope: build-only -->

**Purpose**: 最终构建验证（用户要求：每环节编译测试；无真机 UI 验证条件，取 build-only）

- [X] T041 运行 domain 全量单测（既有 49 + 新增全部通过），执行 `build_project` 全模块构建并修复所有编译错误（迭代 fix → build 直至零 error）
- [X] T042 以 spec.md 9 个用户故事为清单逐条静态走查实现完整性（代码级验证每条验收场景的对应实现存在），输出走查报告

---

## Dependencies & Execution Order

### Phase Dependencies

- Phase 1（基线）→ Phase 2（地基：模型/存储/引擎/用例，串行核心链 T004→T005→T006→T011）→ Phase 3（US1 MVP）→ Phase 4–5（可并行）→ Phase 6 → Phase 7（三项可并行）→ Phase 8 → Phase 9

### User Story Dependencies

- US1 依赖 Foundational（T003–T012）；US2/US3/US4 依赖 US1 的伴侣档案与页面骨架；US5/US6 依赖 US1–3 的窗口页与重算链路；US7 依赖 US3（卡片读缓存）；US8 依赖 US5（计划存在才有提醒）；US9 仅依赖 Foundational。

### Parallel Opportunities

- T003/T004（不同文件）可并行；T007/T008 与 T004/T005 可并行；T023 弹窗组件与 T019–T021 可并行；T033/T034/T035 三个 P3 任务互相独立。

---

## Implementation Strategy

MVP = Phase 1–3（US1）。随后按 Phase 4–9 顺序增量交付，每个 Phase 末尾执行 `build_project` 编译验证（用户要求"每环节编译测试"）。全部由 spec-implementation 子代理执行，主会话按片验收。

## Notes

- 所有"验收/编译"类任务（T012/T018/T022/T026/T032/T036/T041）为阶段验收门，失败必须在本阶段内修复后重跑。
- tasks.md 勾选状态由主会话在阶段验收后更新。
