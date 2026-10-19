# 共同计划第三批验收：本地持久化与计算接入基础

日期：2026-10-04。结论：本批代码、离线和编译门禁通过；正式共同计划与系统通知尚未接通，不具备该新功能发布条件。

## 1. 已实现的行为

- 待确认记录只进独立缓存，不生成日程、不占共同空闲；取得服务端权威确认记录后才生成稳定的一份活动计划。
- 改期待确认时仍保留原已确认时段；拒绝改期不抹掉旧约；终态不能被旧回包复活。
- 先持久保存发送请求，再调用云端口；断网或结果不确定时保留请求，手动重试使用同一编号和内容。连续点击有提交闩；没有次日自动重试。
- 缓存与活动投影同事务更新；回写复核配对、认证主体与会话代次。取消或改期保留系统日历清理句柄，不谎报已经删除系统事件。
- 本地计算读取全部活动；班表上传的输入在区间合并前按来源映射排除共同计划，避免未来双端重复算入。不是按标题或 id 前缀删除，也不从合并区间减时间。
- 数据库 v4→v5 增加四张独立表；旧循环星期列、个人计划和日历句柄保留。迁移失败回滚表创建与版本号；备份恢复后清掉新安全会话和发送账，共同活动失效，保留来源关联。

上述行为由端口和存储实现并验证；没有装配真实云端口，现有页面不会凭空出现共同邀请或红点。

## 2. 主要文件

| 范围 | 实现 |
| --- | --- |
| 独立表／增量迁移 | data/src/main/ets/db/SharedPlanSchema.ets、MigrationRunner.ets |
| 原子投影／会话栅栏／发送账 | data/src/main/ets/repo/SharedPlanRepo.ets |
| 规则／编排／RDB 适配 | feature/src/main/ets/model/SharedPlanFlow.ets、usecase/SharedPlanUseCase.ets、SharedPlanPersistence.ets |
| 快照输入排除 | ScheduleRepo.listSnapshotPlans、ScheduleUseCase.loadMySchedule 的快照输入分支 |
| 测试 | entry/src/test/SharedPlanUseCaseTest.ets、DbMigrationTest.ets；tools/test/shared-plan-storage-regression.cjs、rdb-adapter-regression.cjs |

没有提交或清理工作树，保留其他已有 WIP；没有读取私钥、运行模拟器或部署云资源。

## 3. 实测结果与证据边界

执行 `node tools/verify.mjs --steps=offline,debug,release,ohostest,perf`，exit 0，verify: ALL PASS。

| 检查 | 结果 |
| --- | --- |
| offline 云关／云开 | 两档各 typecheck 0 errors、330 passed / 0 failed（新增编排用例 13 条） |
| debug／release | BUILD SUCCESSFUL；WARN 各 287，原基线各 289 |
| ohosTest | BUILD SUCCESSFUL；WARN 267，原基线 269；仅编译，未执行设备测试 |
| 生产仓储 SQL | 独立内存 SQLite 通过：升级回滚、恢复、待确认零活动、重复、等版本篡改、旧版本、改期旧约、终态、句柄、身份栅栏、发送账 |
| 独立云对象回归 | ES2020、ES5 两档各 36 passed / 0 failed，真实 SDK strict/noEmit 通过；不是部署回执 |
| 开发机 perf | exit 0，120 天 paired P50 15.1ms；列表投影 P95 0.111ms／1.039ms，在当前预算内；不等于设备性能 |

第一轮出包失败：构造器参数属性写法不符合 ArkTS；改为显式字段后三档复跑通过。新增 API 的显式异常边界补齐后告警未上升，未修改门禁基线。

日志目录：`E:/desktop/Code/harmony/.crdtest/`，文件为 `verify-offline-closed.log`、`verify-offline-open.log`、`verify-debug.log`、`verify-release.log`、`verify-ohostest.log`；perf 输出在本次命令回执，没有独立日志文件。SQL 测试运行生产语句，但用 Node SQLite 与测试适配器，不证明 HarmonyOS RDB 实机连接／事务表现。实际 v5 设备升级、真实个人班次与共同活动重叠的端到端冲突检查、正式页面渲染仍待设备验收。

## 4. 下一批实施顺序

1. 正式客户端安装可信身份与安全会话端口：匿名 Auth 的真实刷新／失效、服务端成员验证、HUKS 设备独立密钥和计划密文、双方能力协商。旧配对不能按本地 uid 自动认领；升级需双方明确参与，保留当前班表功能，失败不擅自解绑。
2. 接真实云传输与日程冲突适配器：解密并校验版本、成员、AAD 后才落缓存；接受／改期重读本机日程，只排除该条旧共同活动，不能忽略重叠的个人班次。确认协议语义兼容后才允许共同计划入口。
3. 接正式 UI：发送邀请、待确认／已确认／历史卡、持久玫红圆点、手动重试；待确认不进入首页今日安排、周历或共同空闲，已确认才进入。单人／本机代录仍保留本地创建。
4. 接独立 Push 发送器、目标登记与白名单点击路由；通知事件 PENDING 不代表已送达。再做后台、锁屏、拒绝权限、冷启动定位的真机矩阵。
5. 收口安全解绑／补删、服务端期限与频控、隐私托管披露、正式签名和发布验证。

## 5. 用户本批需要做什么

本批无需再次部署 clouddb/dateplan、修改签名、卸载或重建配对。隔离测试回报已登记，保留测试证据即可；请勿把完整令牌或确认凭据贴进文档。

正式客户端入口接通后再给双端操作步骤。在那之前，独立测试页通过不等于“两人份”已具有共同计划确认或锁屏通知。下次安装主应用时应覆盖安装并核对旧班表／循环模板／个人计划仍在；遇到升级失败保留日志，不用清数据绕过。
