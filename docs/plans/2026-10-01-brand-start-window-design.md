# 两人份品牌启动页设计

用户已选择品牌版：系统原生启动页中央显示双环心形标识，底部显示「两人份 / ForTwo」。

## 资源与范围

- 复用用户更新的 `AppScope/resources/base/media/jim1_resized.png`，保持原图字节不变。图中无水印，但自带奶油色背景；不是透明前景。
- 不修改桌面图标、vendor、包名、首页导航、数据库初始化或云端调用。
- 新增 `entry/src/main/resources/base/profile/start_window.json`，通过 EntryAbility 的 `startWindow` 引用。
- 中央图标为 `$media:jim1_resized`；底部品牌字标为 `$media:start_brand`，分别提供 base/dark 矢量资源。
- 字标将「两人份」与「ForTwo」排为两行，转换为轮廓路径，避免系统 SVG 字体支持差异；源字形取本机 Microsoft YaHei / Segoe UI，不分发字体文件。
- 背景沿用既有 `start_window_background`：浅色 `#FFF6F3`、深色 `#241C3B`。

## 行为

使用 API 26 本机 SDK 已支持的增强启动页配置。`startWindowType=REQUIRED_SHOW`、`startWindowColorModeType=FOLLOW_SYSTEM`。系统完成首帧切换，不增加定时器、广告、加载页或最低停留时长，也不等待联网。保留简单启动页必填字段作为兼容配置，图标也改为当前品牌资源；增强启动页生效时它们不参与绘制。

## 验收

离线检查配置、资源索引、深浅色字标和没有增加业务等待；clean 编译检查 SDK 接受配置并将资源收入 HAP。设备冷启动确认中央标识、底部两行字标、深浅色、底部安全区及进入首页。资源构图由系统控制，设备观感不能由编译证明；原图自带背景在深色下保留为暖色图标底板。

官方入口：https://developer.huawei.com/consumer/cn/doc/harmonyos-guides/launch-page-config
本机依据：`D:/local/DevEcoStudio/sdk/default/openharmony/toolchains/modulecheck/startWindow.json`。
