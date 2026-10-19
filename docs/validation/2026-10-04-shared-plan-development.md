# 共同计划第一批实施回执

日期：2026-10-04。用户要求直接作为实施 AI 开发；随后进一步询问通知类别并要求答复后继续。

> 后续：用户已回报原三个前置测试完全通过；第二批独立安全云计划服务与隔离客户端已开发，见 [第二批验收及操作](./2026-10-04-secure-dateplan-acceptance.md)。本文件以下为第一批交付时点，不把后续回执改写成当时已经验收。

## 本批实现

1. 主项目 `feature/src/main/ets/model/SharedPlanFlow.ets`：候选状态转换、角色及版本守卫、跨会话拒收、终态不可复活、活动投影／稳定 ID、待确认计数、改期保留旧时段、内容 AAD。候选不是云端提交；模块没有网络、DB 或日历副作用，**未接入现有创建计划 UI**。
2. 隔离身份探针：Server SDK 验证令牌后检查项目、主体、有效期，返回脱敏指纹；不返回用户原始 uid 和访问令牌。
3. 隔离事务探针：只使用 FortwoPlanProbe 的 PlanCasProbe，新主键插入，不重置旧行；并行两次 SDK 事务、观测重叠读 version=1、检查单个胜者和最终 version=2。共享内存屏障只用于测量重叠，不负责提交互斥。
4. CloudDevSpikeOfficial 增加独立测试路由及三个按钮：身份、错误令牌拒绝、事务竞争；保留旧页面／配置，不改主应用认证方案、不读既有配对。
5. 新云对象和新对象定义已放入既有隔离 CloudProgram，安装新函数依赖；未部署，未修改默认存储区，未开通任何账号服务。

## 实测

| 证据 | 结果 | 边界 |
| --- | --- | --- |
| `node experiments/shared-plan-preflight/test/auth-probe.mjs` | SDK noEmit 通过；20 passed / 0 failed | Auth 与数据库端口是离线桩，真实 SDK 声明参与类型检查 |
| `node tools/verify.mjs --steps=offline,debug,release,ohostest,perf` | ALL PASS | 无设备执行 |
| offline closed / open | 各 0 type errors，317 passed / 0 failed | 新增 17 项纯共同计划规则用例；实际页面／存储仍未接线 |
| debug / release | BUILD SUCCESSFUL；WARN 287 / 287 | 告警基线 289 未上调 |
| ohosTest | BUILD SUCCESSFUL；WARN 267 | 基线 269；**仅编译，不是执行** |
| perf | exit 0，在开发机预算内 | 不是真机帧率、功耗或后台投递证据 |
| CloudDevSpikeOfficial Application | debug assembleHap BUILD SUCCESSFUL | 测试页含实际 Auth SDK 1.1.0，未安装或运行设备；第三方 SDK 有既有类型声明告警 |

模型测试先红（新增接口尚不存在），实现后转绿。事务探针接线的首轮 SDK 类型检查指出 `.database()` 参数和 `.zone()` 形态不符；修为实际 Server SDK 的 `.database({ zoneName: 'FortwoPlanProbe' }).collection(PlanCasProbe)` 后通过，没有靠类型转换绕过。

测试用模拟后端故意允许两个事务提交时，探针返回 RACE_FAILED；一腿 SDK 异常仅返回 RACE_INCONCLUSIVE。因此“最后只剩一条行”或“另一个网络报错”均不能充作原子竞争通过。

## 账号操作与结论

推送申请推荐只选 **工作事项提醒 / WORK**。官方定义包括日程安排与待办，不因双方互发通知就变成 IM 聊天。申请文案及下一步实操见 [操作清单](./2026-10-03-shared-plan-operator-actions.md)。此为根据业务与官方定义的推荐，最终审核由华为决定。

需要用户部署隔离新对象、配置真实项目 ID／服务器认证环境、创建 FortwoPlanProbe 区，在两台设备执行三个按钮并回传脱敏回包。没有解除、卸载、清空或操纵模拟器。

**判定：第一批代码／离线／客户端编译通过；共同计划双向确认与锁屏推送整体未完成、未接通。**

后续依赖真实身份和真实事务门槛，再实现安全成员绑定、正式云计划 API、本地 RDB／计算接线、计划卡／圆点、系统推送及生命周期清理。错误项目、实际过期／撤销令牌、真实并发、推送权益、正式签名及真机通知均未用本批结果替代。

未提交任何 Git 变更；既有 WIP 保留。托管隐私政策尚未改，需在新链路启用前同步新增披露。
