# 共同计划本地缓存与活动投影 Implementation Plan

> **For agentic workers:** 按主计划 Task 2 单代理实施；不部署、不运行设备、不自动提交。

**Goal:** 给已通过隔离双端验证的独立共同计划协议增加正式应用的本地持久化与编排基础。

**Architecture:** 本地 v5 独立会话、缓存、发送账、来源映射；原子缓存/活动投影。UseCase 使用明确的云端、存储、冲突、重算端口；没有可信身份/解密端口时不得默认接入旧配对。

**Tech Stack:** ArkTS API 26、RDB、Node SQLite 回归、Hypium 离线。

**Spec:** `docs/plans/2026-10-03-shared-plan-confirmation-design.md` §2/4/6/8，主实施计划 Task 2。

## Global Constraints

- 用户回报隔离双端测试全部通过，记为用户执行证据；不冒充 AI 代跑或原始截图归档。
- 不修改 CRD1 schemaVersion=2，不认领旧配对，不启用尚缺认证/真实密文/双方能力协商的正式 UI。
- 云端 OK 的权威且已解密记录才能落活动表；请求队列不是 PENDING 邀请，离线不假确认。
- 保留旧计划和日历清理句柄；迁移失败事务回滚；不从已经合并的忙碌区减区间。
- 不读取密钥、部署生产云对象或操作模拟器，不提交现有 WIP。

## 本批步骤

- [x] 写 SQLite 回归（v4→v5、旧列保留、PENDING 零活动、重复/旧版本、改期旧约、取消句柄、身份代次栅栏、回滚）。
- [x] 增加 `SharedPlanSchema.ets`、`SharedPlanRepo.ets`，目标版本 v5；新增来源映射不改变旧计划主键。
- [x] 规则校验增加公开验证边界；`SharedPlanUseCase.ets` 用端口先落发送账、手动重试同一 requestId、云 OK 后才原子投影，不乐观写入。
- [x] 快照构建前只读取个人计划，计算仍读取所有活动计划；来源表而非 id 前缀决定排除。
- [x] 用真实 SQLite 执行生产仓储语句，跑离线与三档出包，记录证据边界；不标 Task 2 整体关闭。

## 接口与后续边界

数据层 `SharedPlanRepo.apply(session, rows)` 接收已经验证/解密的序列化缓存和投影；SQL 内复核 pairId/actorId/generation。`enqueue`/`finishRequest` 持久发送账，不能把旧会话结果写到新会话。

特性层 `SharedPlanUseCase` 注入会话、云端（返回权威解密记录）、存储、冲突、重算能力。下批接真实 AGC 身份、HUKS 密文和安全配对流程后再安装这些端口；本批没有可点击的新云计划入口、Push 发送器或锁屏通知。

## 执行回执

2026-10-04：本批基础完成。全量 verify 五步 ALL PASS；offline 两档各 330 passed / 0 failed、typecheck 0；debug/release/ohosTest 编译 WARN 287/287/267，原基线 289/289/269 未修改；开发机 perf 在预算内。首次三档出包因 ArkTS 不接受构造器参数属性声明失败，改为显式字段后复跑通过。生产 SQL 以独立内存 SQLite 验证，不是设备 RDB 实测。

完整证据与下一批顺序见 [本批验收](../../validation/2026-10-04-shared-plan-local-projection.md)。主计划 Task 2 保持部分完成；不以端口桩替代认证、真实密文、设备升级或正式页面联调。
