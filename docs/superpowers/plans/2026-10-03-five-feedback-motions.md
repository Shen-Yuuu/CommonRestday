# Five Local Feedback Motions Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task by task. 本环境未提供该执行技能，主代理在当前任务内逐项执行；不派子代理，不提交用户混合工作树。

**Goal:** 实现用户指定的五项局部动效，并保持标题与云请求行为稳定。

**Architecture:** 可取消的局部帧动画控制器；共享项仅背景属性动画；计划成功事件在内存中传递，真实 id 定位；同步按钮独立承载忙碌与结果。

**Tech Stack:** ArkTS / ArkUI V1 / 本机 API 26 SDK / Node 离线 Hypium / Hvigor。

**Spec:** `docs/plans/2026-10-03-five-feedback-motions-design.md`。

## Global Constraints

不增加设置项/导入功能；不改云配额、载荷、查询语义或数据库；不触碰账号/模拟器，不提交、撤回或覆盖无关 WIP；不改门禁基线。不得将整个页面放进 animateTo，标题高度不得参加翻周动画。

## Task 1：先建立回归证据

- [x] 新增源码接线回归：箭头与列表共用进度、仅新选中背景过渡、成功后才发布计划提示、翻周位移而非高度、同步原生按钮与真实结果。
- [x] 为一次性计划提示添加纯逻辑用例：空 id、过期、未来时钟、重复消费、新保存覆盖旧提示。
- [x] 接入 `tools/test/run.mjs` / `entry/src/test/List.test.ets`，先确认缺少实现时失败（源码接线检查旧版本失败；纯逻辑新增四例）。

## Task 2：今日安排与分享等级

- [x] 增加 `LocalTween`，换向/离开取消旧帧；零时长直接落终态。
- [x] 今日安排仅额外条目测量自然高度，用禁止交互的裁剪滚动容器平滑显露；同一进度驱动箭头。
- [x] 分享项仅在 backgroundColor 后加条件时长，取消选择时长为 0。

## Task 3：新计划定位与一次性高亮

- [x] 成功返回真实 planId 后发布短效内存提示；失败/关闭不发布。
- [x] 首页与共同页的所有起草器宿主都接入“打开计划”回调。
- [x] PlansView 读到目标后按真实排序定位；条目实际出现才消费提示，短暂高亮；卸载取消定时器与旧查询落地。

## Task 4：周历水平进入

- [x] prev/next/本周走一个方向入口，连续点击取消旧帧。
- [x] 两条数据读路径的最新请求完成后才入场；错误也能恢复可见。
- [x] 导航按钮与更新状态不被隐藏；仅日期及网格横移，加载时禁止对旧数据执行操作；不修改 FadingHeader。

## Task 5：同步局部按钮

- [x] 新增 SyncFeedbackButton：固定热区内显示忙碌/成功/失败结果，真实 promise 决定结果。
- [x] 我的摘要/云配对弹层只让实际点击的位置动起来，成功后仍保留结果位置，另一个按钮禁止重复请求。
- [x] 不改 ScheduleUseCase 或云请求次数；失败说明只在我的页。

## Task 6：门禁与交接

- [x] 离线两档、debug / release / ohosTest 编译、开发机 perf 逐项执行；基线不放宽。最终 `verify: ALL PASS`，两档各 284 passed / 0 failed，WARN 287 / 287 / 267。
- [x] 记录结果与五项设备测试步骤；明确没有模拟器/真机渲染证据。见 `docs/validation/2026-10-03-five-feedback-motions-acceptance.md`。
