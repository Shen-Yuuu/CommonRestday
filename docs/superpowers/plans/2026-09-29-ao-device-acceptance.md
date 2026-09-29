# AO Disposable-Device Acceptance Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking. If those skills are unavailable in the execution environment, run the same checkpoints inline. Record actual device and AGC evidence; never mark a case passed from a code assertion alone.

**Goal:** 在不破坏现有两台配对环境的前提下，给 AO1–AO5 和云端删除生命周期补齐设备证据。

**Architecture:** 使用独立的 API 26 可丢弃实例和专门测试配对。每一场景先记 pairId、设备身份、云端行数和本机可见状态，再执行一项动作，最后以设备画面与 AGC 行变化双向核对。会造成服务不可用的测试只在隔离 AGC 环境做。

**Tech Stack:** DevEco Studio HVD、HDC/uitest、AGC 控制台、API 26 HAP。

**Spec:** `docs/cloud/pairing-protocol-v1.md` §11、`docs/design/date-plan-coedit-2026-09-28.md` §8.28–8.29、任务 #210。

## Global Constraints

- 两台现有配对模拟器上的数据不清、不卸载；不对共用云对象做停部署或超时变更。
- 新实例必须可丢弃，并用与旧配对不同的测试 `pairId`；每次破坏性操作前记录精确目标。
- 截图、布局、日志、AGC 结果须脱敏归档；“发出调用”和“云端确实删掉”分开判。
- 不因某一设备连不上就把离线用例改判为设备通过。

---

### Task 1: 准备环境与恢复原测试现场

- [ ] 在 DevEco 设备管理器启动可丢弃 API 26 实例；用 `hdc list targets -v` 只确认 `Connected` 目标和其 HAP 包名，不猜测端口。若设备仍不可见，记录阻塞并停止设备验收。
- [ ] 另行恢复原 5555 的视界 30→120，采“共同时间”与循环编辑器的同机画面，补 AN·D-63 改后那一帧；这一步不清配对、不参与下列破坏性测试。
- [ ] 在可丢弃实例上建立专用测试配对，记下测试 `pairId`、两名成员 UID 的脱敏指纹及 AGC 会话行/两行快照基线；所有后续场景只用这组或新建的测试数据。

### Task 2: 删除失败与成功的闭环

- [ ] 制造一次可恢复的网络失败，点“解除配对”：页面显示云端未删，本机 `pairId`、密钥别名、快照游标与配对状态不变；AGC 会话和快照仍在。恢复网络后再次点击，应显示成功；AGC 会话行及两行快照都消失，另一台自己的本机日程仍在。
- [ ] 新建第二组测试配对，在云端不可达时“清空全部数据”：本机数据立即清掉，原 `pairId+uid` 留在待补删账，确认文案不说云端已删。恢复网络、回前台后核对补删调用、AGC 行消失及待补删条目退出。
- [ ] 用测试专用错误注入或隔离环境制造终局 `FORBIDDEN`：它不再重复发请求，但“数据与隐私”显示不可删除计数；再次清空和重启后计数仍在。不可修改现有已配对实例的真实 UID 来造这条证据。

### Task 3: 凭据、第三设备及共享等级

- [ ] 只在可丢弃实例上卸载/清数据以验 HUKS 别名生命周期；记录清除前后云端残留及用户可见告知，不把“本机清了”写成“云端也清了”。
- [ ] 第三台测试实例拿非成员身份访问测试 `pairId`，应得到 `FORBIDDEN`，原两台的本机数据不变；无需造出可访问真实用户配对的第三方凭据。
- [ ] 在测试构建中注入“共享等级读取失败/脏值”，核对 UI 念“暂不可确认”、三档均不勾、快照版本号未消费且云端无新写；恢复为 L1/L3 后各自显示实际档位。旧心跳返回跨解绑/重新配对时，新会话游标仍为 0 并可发首跳。

### Task 4: 与发布门禁分开收口

- [ ] AGC 未初始化、云对象未部署、真实 30 秒截断，仅在隔离环境做；当前共用云环境不为取证停服。控制台 heartbeat 调用统计由有权限者核对，端侧日志不能替代。
- [ ] 单模拟器、同 HAP、同数据、固定采样条件复测性能“双带子”；仍有两带才做 Profiler 归因，不凭混合宿主读数改算法。
- [ ] 更新协议 §11 和设计文档 §8.29：每格填设备、包版本、时间、脱敏证据路径、AGC 行变化及判定。未完成的格仍保持“待设备”。
- [ ] 只有以上完成后再排 API 26 真机、签名包、备案及提审材料；W1a 须用户另行点名，W1b/W2 继续暂缓。

## 完成定义

AO 的代码/离线通过与设备通过分别记录；现有两台实例零清理，云端共用环境零停服；五条破坏性生命周期场景有真实画面和云端行证据。任何一项缺证，AO 的设备结论仍为“待验”，不等于产品可发布。
