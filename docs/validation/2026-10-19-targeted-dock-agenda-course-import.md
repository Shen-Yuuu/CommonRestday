# Dock、今日时间轴、背景与图片课表导入

用户本轮指定的前三项及相册入口已实现；额外审美升级仅给建议，见 [设计与 AI 方案](../design/2026-10-19-scoped-ui-and-course-ai.md)。没有恢复上一轮已撤回的整套卡片重设计。

## 验证

- ArkTS 技能 assembleApp：BUILD SUCCESSFUL；最终日志位于下述产物目录。
- 完整 offline closed/open 各 371 passed / 0 failed，typecheck 0 errors。
- 新增 `course-image-import-regression.cjs` 执行生产图片导入方法：验证授权 URI 的 fd 读取、有界 RGBA 解码、取消/失败/迟到返回的释放、核对约束、防重复保存、失败保留和成功返回、单双周及 owner 保留。它不测设备 OCR 准确率。
- 原有 ui-refinement、header-fade、feedback-motion、contrast-audit 通过；Impeccable 源码检测为空列表，不作为 ArkUI 实拍验收。
- 修改文件 diff --check 通过。

## 原生验收边界

原 127.0.0.1:5555 已离线，当前无运行中的模拟器。只读核查 HVD 与工具后尝试保留原数据启动 Mate 90 Pro / API 26 的隐藏测试实例，Emulator 在启动阶段退出；日志显示 snapshot boot timeout / trace pipe 未就绪。未清除数据、重置 HVD 或修改其他实例。没有对启动失败作多轮 UI 自动化重试。

因此本轮没有安装成功的新版本、真实 OCR 样本准确率、截图或 Dock 拖动实测证据。此前同样的 Dock 与时间轴方案有历史原生记录，但不能替代本轮验收。模拟器或真机重新连接后，应覆盖安装签名包并检查：

1. Dock 三项点击与横向拖动、线框/实心图标、爱心粒子与减少动效。
2. 首页背景与“今天”起止时间轴；多条、跨天、24:00及展开收起。
3. 我/TA 各自课程导入的相册入口、取消不写库、照片读取、空白图/模糊图/网格图、文字修改后重新解析；未核对不可保存，成功返回课程列表刷新。
4. 深色、系统大字体、宽屏布局与返回路径。

## 产物与恢复

本轮修改前副本、编译/离线日志、图片流程测试与 Emulator 启动审计：

`E:/desktop/Code/harmony/.crdtest/targeted-upgrade-2026-10-19/`

备份按工程相对路径存于该目录 `backup/`；撤回时仅恢复本轮条目并核对后续编辑，不 reset 整个工作区。

签名包：`E:/desktop/Code/harmony/CommonRestday/entry/build/default/outputs/default/entry-default-signed.hap`。
