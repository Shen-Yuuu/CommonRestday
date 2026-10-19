# Shared plan experience Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 修正共同计划空态、刷新入口、取消与排序、周历语义，并减少一次操作里的重复云请求。

**Architecture:** 展示层隐藏取消记录，协议层仍保留版本墓碑；只有确认后的本地投影进入周历。每次操作仍校验云端能力，操作内的防串会话检查改为本地身份/配对检查，不以缓存取代云端授权。

**Tech Stack:** HarmonyOS NEXT API 26、ArkTS/ArkUI、AGC Auth/云对象、Node 离线回归。

**Spec:** 本会话 2026-10-08 用户关于计划空态、下拉刷新、通知入口、取消隐藏、共同周历、时间排序和同步延迟的七项要求。

## Global Constraints

- 不操作模拟器；不卸载、清数据、重新生成密钥，不部署云端。
- 未确认计划不占用时间；改期未确认时仍保留原确认时间。
- 取消只从用户列表隐藏，不删除用于防旧响应复活的内部墓碑。
- 普通下拉刷新只读云计划，不自动重放结果未知的写请求；核实/重试仍须用户点击。
- 保留全仓已有未提交修改，本次不暂存、不提交。
- 指定执行子技能当前不可用，按本计划在主会话逐项执行并验证。

### Task 1: 列表展示与刷新

**Files:** `feature/src/main/ets/model/SharedPlanPresentation.ets`、`feature/src/main/ets/usecase/SharedPlanViewService.ets`、`feature/Index.ets`、`entry/src/main/ets/view/PlansView.ets`、`entry/src/main/ets/component/SharedPlansPanel.ets`、`tools/test/shared-plan-experience-regression.cjs`。

**Interfaces:** `visibleSharedPlans(rows: SharedPlanRecord[]): SharedPlanRecord[]` 隐藏 CANCELLED；`planListEntries(local: PlanSummary[], shared: SharedPlanRecord[]): PlanListEntry[]` 合成一条按卡片展示时间升序的列表；面板向父页回报读取结果，使空态检查本地与云计划总数。

- [x] 写失败测试并运行：`node tools/test/shared-plan-experience-regression.cjs`（首次缺少 `visibleSharedPlans` 失败）。
  ```js
  assert.deepEqual(visibleSharedPlans([late, cancelled, early]).map(p => p.planId), ['early', 'late']);
  assert.equal(source.includes("this.run('REFRESH')"), false);
  ```
- [x] 实现过滤排序；空态仅在两侧成功读到且都没有计划时出现；通知按钮移到右上角；下拉显式读取共享计划后重算班表，不重放写请求。
  ```ts
  const rows = source.filter((p: SharedPlanRecord) => p.state !== SharedPlanState.CANCELLED);
  rows.sort((a: SharedPlanRecord, b: SharedPlanRecord): number => {
    const left = a.pendingContent ?? a.acceptedContent;
    const right = b.pendingContent ?? b.acceptedContent;
    const delta = (left?.start ?? Number.MAX_SAFE_INTEGER) - (right?.start ?? Number.MAX_SAFE_INTEGER);
    return delta !== 0 ? delta : a.planId.localeCompare(b.planId);
  });
  ```
- [x] 重跑专项过滤与持久化测试，内部记录保留；设备上取消后重新打开和刷新是否仍不显示取消卡，交由用户验收。

### Task 2: 已确认计划的周历表示

**Files:** `feature/src/main/ets/usecase/ScheduleOverviewQueryService.ets`、`entry/src/main/ets/component/WeekScheduleView.ets`、专项测试。

**Interfaces:** `WeekLanes.plans: WeekBlock[]` 来自 `ScheduleRepo.listActivePlans()`，仅携带本地已确认投影；跨天继续走既有 `clipInto`。

- [x] 写失败测试：读模型必须提供活动计划；共同周历必须单独绘制计划，不能将待确认草案读取为日程。
  ```js
  assert.ok(query.includes('plans: plans'));
  assert.ok(view.includes('this.dayPlanBlocks(ed)'));
  ```
- [x] 增加计划块与图例，覆盖原忙碌底色，颜色/描边与空闲区别开；不改空闲计算，不从合并区间减去计划以免抹掉重叠班次。
  ```ts
  const plans: WeekBlock[] = (await ScheduleRepo.listActivePlans())
    .filter((p: PlanRow) => intersects(p.start, p.end, start, end))
    .map((p: PlanRow) => ({ id: p.id, kind: 'PLAN', start: p.start, end: p.end, name: p.title, color: PLAN_COLOR }));
  ```
- [x] 重跑实际周查询专项与原生命周期、存储、流程回归；跨日/取消/改期的设备显示仍待用户确认。

### Task 3: 减少重复网络校验

**Files:** `cloud/src/main/ets/api/AnonymousIdentity.ets`、`cloud/src/main/ets/api/DatePlanCloudApi.ets`、`feature/src/main/ets/usecase/SecurePlanAdapters.ets`、`feature/src/main/ets/usecase/SecureSharedPlanGateway.ets`、`feature/src/main/ets/usecase/SharedPlanUseCase.ets`、`tools/test/shared-plan-secure-regression.cjs`。

**Interfaces:** `PlanIdentityPort.currentUid?(): Promise<string>` 无初始化/登录/取 token；`SharedPlanGatewayPort.current?(ctx): Promise<boolean>` 只用于已经验证过的操作内本地会话围栏。旧适配器回退到原检查。

- [x] 增加失败测试，完整刷新必须只有两次 capabilities 与一次 read，操作内 UID/generation/gate 改变必须失败；反复本地检查不获取 token（首次缺少 `currentUid` 失败）。
  ```js
  assert.equal(await use.refresh(), 'OK');
  assert.deepEqual(rpc.map(r => r.method), ['capabilities', 'capabilities', 'read']);
  uid = 'another-device'; assert.equal(await gateway.current(ctx), false);
  ```
- [x] 保留操作入口和读写前的服务端能力校验，替换其余重复 context RPC；本地身份只查 SDK 当前用户，实际网络请求仍用有效 token。
  ```ts
  if (this.gateway.current !== undefined)
    return await this.gateway.current(ctx) && await this.storage.current(ctx);
  return sameContext(ctx, await this.gateway.context()) && await this.storage.current(ctx);
  ```
- [x] 专项确认密文持久化先于发送、原 requestId 重试、账号切换、回复验证和鉴权关闭仍有效；追加仅四个安全字段的耗时日志及隐私测试。

### Task 4: 完整验证与交接

- [x] `node tools/verify.mjs --steps=offline,debug,release,ohostest` 最终 ALL PASS（ohosTest 仅编译）。
- [x] `git -c core.safecrlf=false diff --check`；新增文件定向空白检查；逐项核对七条要求。
- [x] 保存 `docs/validation/2026-10-08-shared-plan-experience.md`，给用户双端覆盖运行、下拉、取消、排序、跨日周历和延迟对照步骤；明确尚无设备耗时证据，不保证换真机必然变快。
