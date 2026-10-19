# 计划弹窗兔子方形投影修复

用户报告计划弹窗小兔子周围可见方形透明框，并确认采用最小修复：移除图片节点阴影，保留原图、大小、位置和动画。

源码证据：mascot_peek_bunny.svg 只有兔子路径、圆形和椭圆，没有矩形底图；WindowDetailSheet 的 Image 节点带通用 `.shadow({ radius: 8, ... })`，组件外框投影是疑似来源。SDK ShadowOptions.fill 默认 false，不能把原因表述为默认内部填充。未接设备，因此不声称已经复现或验证视觉结果。

只删除该 Image 上的 shadow，其他按钮的投影不动。原 hitTestBehavior、accessibilityLevel、translate 和 onAppear 保持，避免影响探头动画及透明区域点击收起。

回归约束兔子 Image 不再设置 shadow/background/border，原尺寸位置动画接线不变；素材保持透明且内容原样不改。运行表单/动效回归、离线和 ArkTS 编译。当前脏工作区不自动提交。
