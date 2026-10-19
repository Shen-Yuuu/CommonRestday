# Glass Cards Implementation Plan

**Goal:** 将主要内容卡升级为鸿蒙原生玻璃，并恢复 HDS 页签交互。

**Architecture:** MaterialPolicy 新增 CARD/HERO 材质，EditorialCard 统一处理玻璃与实底分支。导航以 BottomTabBarStyle 提供页签语义和交互。

**Tech Stack:** ArkTS / ArkUI / UI Design Kit，本地 API 26 SDK。

**Spec:** docs/plans/2026-10-19-glass-cards-design.md

## Global Constraints

保留用户脏工作区，不提交整个目录；不改业务、云端、权限和角色动作。表单与色块保持实底。低算力回退。设备视觉独立于编译验收。

### Task 1: 内容材质

- [x] MaterialPolicy.ets 添加 CARD/HERO 缓存；CARD=THIN/玻璃浅色，HERO=THIN/莓色，interactive=false；现有 STRONG/SOFT 保留供浮层使用。
- [x] 两套 color.json 与 DesignTokens.ets 添加主卡材质及回退色；CARD 低透明度赋色。
- [x] EditorialCard.ets 在 glass=true 时不画不透明渐变，按 hero 选择 HERO/CARD 和正确回退底。系统路径移除额外边缘与阴影，保留焦点环。
- [x] HomeView、CoTimeView、TodayOverview、NextWindowHero、WindowCard 主要卡显式 glass=true；MeView 只改身份/摘要；ScheduleHub 只改展示卡；SharedPlansPanel 卡片根节点接 CARD 材质，不动 swipeAction 与量高。

### Task 2: 原生 Dock

- [x] AppNavigator.ets 导入 SymbolGlyphModifier，tabBarStyle(tab:number):BottomTabBarStyle 返回标准页签。
- [x] TabBarSymbol.normal/selected 分别装载 NAV_ITEMS 的 icon/selectedIcon，使用主题前景和品牌色；labelStyle 保留品牌色。
- [x] 删除 navItem/tabBarItem Builder、pressedTab/pressTab/selectTab 和 stopPropagation；TabContent 直接使用 tabBarStyle，onChange 继续更新 activeTab/时钟。保留 goTab 深链入口。
- [x] barFloatingStyle 添加 lightColor 和 thermoCtrl，保留数值岛宽与透明 gradientMask；移除固定粒子叠层，打开左右跟手适配。

### Task 3: 验证与说明

- [x] 调整 ui-refinement-regression 中旧自绘页签约束，验证原生样式、同族图标、事件路径与既有导航；检查玻璃主卡没有不透明遮挡。
- [x] 运行 ArkTS 技能 run.ps1（配置本机 ohpm/hvigor PATH），检查 assembleApp 退出码与 BUILD SUCCESSFUL。
- [x] node tools/verify.mjs --steps=offline,debug，处理新增失败并记录证据。
- [x] 在 docs/validation/2026-10-19-glass-cards-native-dock.md 记录变更、官方来源、回退备份、设备验收边界。

实施完成。真实设备视觉仍按验证记录保留为后续验收项；模拟器因低内存/启动超时退出，未声称通过渲染验收。未调用不存在的额外技能或自动提交用户工作区。
