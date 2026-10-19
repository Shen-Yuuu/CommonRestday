# 稳定渐隐与紧凑页头

## 2026-10-01 第二轮修订：取消布局回写，隔离滚动视觉状态

用户反馈上一轮仍然闪烁，且同休/我的标题大小反复变化。下文原方案保留为历史，不代表设备验收通过；本轮以本节为准。

- 同休/我的改为普通 Column：自然高度的固定标题 + layoutWeight(1) 正文视口。删除页头 onAreaChange、headerHeight 和正文高度占位回写，首卡仅保留 8vp。标题缩放仍只改变绘制，副标题不删行；大字体由正常布局量高。
- 每个实际 Scroller 配一个独立 ScrollHeaderState。页面用 @State 持有稳定对象实例（ArkUI 的 @ObjectLink 初始化要求），offset 使用 @Track 属性级精准观察；滚动回调只调用 update(offset)，不再写页面级数值状态。只有 StickyPageHeader 与 HeaderFadeEdge 读取 offset；FadingScrollViewport 通过 @ObjectLink 传引用但不读取 offset，正文 Builder 也不读取它。
- offset 使用绝对偏移（Scroller.currentOffset().yOffset），截在 0–96vp；相同读数不再写入。渐隐透明度与副标题透明度沿用原函数，不引入计时器、防抖、隐式动画或滚动方向猜测。
- FadingHeaderSurface 改自然高度实色 Column，只承担固定工具栏。渐隐只在正文视口顶部绘制；无动态量高渐变、原生 overlay、矩形模糊或绘制越界。
- 不改云配对、数据、权限、周历业务和导航。不开模拟器；设备闪烁根因与修复有效性不能由代码审计/构建代替。当前仅确定源码存在上述反馈/刷新路径，不能宣称已证实唯一根因。

API 依据：[华为 @Track 官方说明](https://developer.huawei.com/consumer/cn/doc/doccenter-capabilities/api/ts-state-management-track) 的属性级依赖更新；本机 SDK 编译要求 @ObjectLink 的来源为状态字段，因此使用 @State 对象引用 + @Track 属性，不使用普通字段直接初始化 @ObjectLink。

用户已确认：同休/我的首卡间距约 8vp；副标题随上滑渐隐，返回顶部恢复；四个滚动渐隐入口取消动态 overlay Builder，改普通 Stack 固定节点并限制绘制边界。

## 范围与边界

- 不操作模拟器，不安装/卸载、不清空数据、不改变班表/云配对/权限。保留已有 WIP，不提交任何工作树修改。
- 同休/我的只回传标题实际内容高度，不把渐隐尾部加入正文占位。StickyPageHeader 顶部留白 16vp、底部 0vp，正文在内容高度之后加 8vp；尾部渐隐 16vp 叠在滚动内容之上，不另外推开首卡。
- 副标题使用 `1 - progress(offset, reduceMotion)`，0→96vp 内从 1→0；节点及布局高度始终保留，避免删除/折叠节点引发滚动重排。减少动效开启时保持副标题可见及标题原大小。
- 共享 `FadingScrollViewport`：Stack 的首个子节点承接原 Refresh/List/Scroll；末节点为 HeaderFadeEdge，内外都禁命中。Stack 定高并 clip，渐隐只在滚动视口边缘显示；不碰页面的固定工具栏或半模态宿主。
- 共同列表/周历、计划、班表四处均不再调用 `.overlay(...)`，保留原控制器、下拉刷新、滚动位置与点击回调。滚动只更新透明度，不通过条件分支挂载/卸载渐隐节点。
- 周历日期抬头仍属于滚动内容，不额外置顶。日期切周逻辑、计算范围外不可点、异步令牌闸门保留。

## 证据边界

源码可确认：旧正文占位含 36vp 渐隐尾部；滚动时持续更新 CustomBuilder overlay。SDK `common.d.ts` 与官方 overlay 文档说明 CustomBuilder 会在页面刷新时重建。它是闪烁的重点嫌疑，不是已经实测的唯一根因；跨页扩散是否消失仍需用户验收。

本机验证：透明度/间距纯逻辑用例、固定节点/绘制边界结构回归、offline closed/open、debug/release/ohosTest 编译。设备验证：连续拖动后抬头不闪，切回同休/我的不扩散，点击和刷新保持可用，2× 字体不重叠。
