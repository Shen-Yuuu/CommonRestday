# Real Device Feedback Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 完成三项可确定的视觉/布局修复，并使真机邀请失败可定位、可安全重试。

**Architecture:** 原图参考衍生新资源；页头以标题行底边组织；排班 sheet 的滚动内容与安全底栏分离；纯诊断模型由 Gateway 填充并经 UseCase 传给 UI。已有安全会话、事务与幂等结构保持不变。

**Tech Stack:** ArkTS / ArkUI / 本地 HarmonyOS SDK / imagegen / Node 回归 / 浏览器视觉验证。

**Spec:** docs/plans/2026-10-17-real-device-feedback-design.md。

## Global Constraints

保留脏工作区；不提交、不发布、不部署、不清数据。日志仅白名单阶段/结果/数字 SDK 码。缺少真机链路证据时明确未确认项。

### Task 1：角色与标题基线

Files: 三个新增 media PNG；ConfirmDialog、StatePanel、WindowDetailSheet、CompanionsDuo、CoTimeView；原型 HTML。

- [x] 以当前角色图为参考生成并检查素材；用户否定改变造型的稿，均未接入应用。补充“表情/动作可变”的三组校对图。
- [x] 页头上排底对齐并将备注移到下一行，保留角色动画生命周期与固定热区。
- [x] 用户确认三组校对稿造型一致后，生成三张同造型透明 PNG；确认框/计划弹窗/空状态不再引用旧 mascot SVG。旧文件保留可回退，表情独立分层仍未完成。
- [x] 浏览器检查 360/390、深浅背景，标题行布局底边与角色绘制底边一致（228px / 228px；非设备字形墨迹测量）。

### Task 2：排班安全底栏

Files: DayShiftSheet.ets；底部避让状态小工具；根页生命周期接线；布局回归。

- [x] 查本地 SDK 的 Window 避让区域读取/监听及 px→vp 接口。
- [x] 写回归：正文滚动、保存不在滚动列表内，底栏 padding 含导航避让与至少 12vp 间隔。
- [x] 实现具名监听、生命周期清理，保存/自定义确认按钮移至安全底栏；正文滚动与固定底栏分离。
- [x] 编译并记录隔离窗口端口的避让测试；真机高度与键盘显示仍待验。

### Task 3：共同计划故障可定位与恢复

Files: SharedPlanDiagnostic.ets、SecureSharedPlanGateway.ets、SharedPlanUseCase.ets、SharedPlansPanel.ets、WindowDetailSheet.ets；shared-plan 回归。

- [x] 使用假云/密钥/存储端口复现 seal、落 wire、RPC、decode、resolve 的失败，确保旧请求仍保留。
- [x] 以命名阶段诊断取代无信息 catch；将安全错误明细呈现在失败页，不只依赖短 toast。
- [x] 核查重试使用原请求与原密文；仅有效 OK 回执应用成功或重新发送得到确定业务拒绝时结案。状态查询的 FORBIDDEN 不是原事务失败证明，仍保留请求。
- [x] 扩充白名单业务文案；不根据“无卡片”推断远端未提交。
- [x] 运行相关回归、ArkTS 技能编译脚本和 offline/debug/release 门禁，写明已修复行为与仍需真机页面诊断验证的原因。最终两档各 368/0；Debug 280 WARN、Release 278 WARN，均低于 289 基线。

执行：用户已明确要求修改，当前会话内逐项完成；execution 子技能不可用，不派生 agent、不自动提交。
