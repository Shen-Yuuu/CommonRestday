# Dock 实心图标与计划兔子投影

日期：2026-10-16。用户分别确认系统同族实心选中图标，以及移除兔子图片节点阴影的最小修复。

## 改动

- AppNavigator.NavItem 增加 selectedIcon；house/heart/person 对应 house_fill/heart_fill/person_fill，SymbolGlyph 只依据 activeTab 选择资源。未选中仍为线框，选中仍用原 brand_pink，图标 22fp、文字、底色、阴影、按压反馈、导航与粒子均不改。
- WindowDetailSheet 只删除兔子 Image 的通用 shadow，SVG 素材、尺寸、位置、translate/onAppear 探头动画、点击穿透保持原样。素材没有矩形底图，组件投影是方框疑似来源；未取得设备截图，不声称已经复现视觉问题。
- 诊断更正：本机 SDK common.d.ts 的 ShadowOptions.fill 默认 false，不能将原因表述为默认内部填充。

## 验证

- ui-refinement-regression 新增三个图标映射、选中接线与颜色断言；先在旧实现确认失败，再修改后通过。
- 兔子新增无 shadow/background/border、原尺寸/margin/translate/hitTest 断言；先确认旧 shadow 使测试失败，再删除后通过。
- ui-refinement、plan-time-list、feedback-motion 回归通过。
- 按 ArkTS 技能脚本分别对 Dock 改动和合并后改动执行依赖安装及 assembleApp，均首次编译成功。
- Dock 单独 `node tools/verify.mjs --steps=offline,debug,release` ALL PASS：两档各 368/0，Debug 281 / Release 279 WARN，原基线 289 / 289。

合并后 `node tools/verify.mjs --steps=offline,debug,release` **ALL PASS / exit 0**：两档各 0 类型错误、368 passed / 0 failed；全部审计与附加回归通过，Debug 281 / Release 279 WARN。`git diff --check` 通过。没有修改基线、签名、版本号、云对象、数据模型或权限，没有设备安装、云端部署或发布。现有脏工作区保留，不自动提交。

## 设备待验

覆盖安装后依次切三个 Tab：仅当前项为玫红实心图标，其他为线框；底栏无额外切页闪动。打开计划弹窗观察兔子周围方框是否消失，确认原探头动画及透明区域点击收起不变；浅色/深色均检查。若方框仍在，需截图进一步定位父级图层，不能用本次静态检查代替视觉验收。
