# Brand Start Window Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking. 本环境未提供该技能，由当前会话顺序执行，不委派子代理。

**Goal:** 为两人份配置带中央品牌图标和底部中英字标的原生启动页。

**Architecture:** 使用增强启动页 profile，而非新增 ArkUI 路由。复用用户无水印图标；底部字标提供深浅色 SVG 轮廓，背景复用现有颜色资源。

**Tech Stack:** HarmonyOS API 26、资源限定词 base/dark、SVG、Node 静态回归、hvigor clean 编译。

**Spec:** `docs/plans/2026-10-01-brand-start-window-design.md`

## Global Constraints

- 图标源 `jim1_resized.png` 原样保留，桌面 icon 与 vendor 不改。
- 启动首帧不等待云或人为时长；不修改 EntryAbility.ets / Index.ets。
- 用户负责模拟器或真机验证，本会话不控制设备。
- 保留工作树与已暂存的用户文件，不自动提交。

### Task 1: 配置与资源

**Files:** Create `tools/test/start-window-regression.mjs`, `entry/src/main/resources/base/profile/start_window.json`, `entry/src/main/resources/base/media/start_brand.svg`, `entry/src/main/resources/dark/media/start_brand.svg`; Modify `entry/src/main/module.json5`, `tools/test/run.mjs`。

**Interfaces:** profile 消费 `$media:jim1_resized`、`$media:start_brand`、`$color:start_window_background`；输出 `$profile:start_window` 给 EntryAbility。

- [x] 添加回归脚本并先运行 `node tools/test/start-window-regression.mjs`，实际因缺少 profile 失败（ENOENT）。
- [x] 新增以下 profile，并在 EntryAbility 配置 `"startWindow": "$profile:start_window"`，保留简单启动页字段：

```json
{
  "startWindowType": "REQUIRED_SHOW",
  "startWindowColorModeType": "FOLLOW_SYSTEM",
  "startWindowAppIcon": "$media:jim1_resized",
  "startWindowBrandingImage": "$media:start_brand",
  "startWindowBackgroundColor": "$color:start_window_background"
}
```

- [x] 创建两行字标矢量路径，浅色文字 `#624953` / `#9D7889`，深色文字 `#FFE5EE` / `#CDBACF`；SVG 不引用字体、远程资源或水印图。生成器 `tools/design/start-brand-outline.ps1` 只输出 JSON，写入 SVG 通过文件补丁。
- [x] 向 `tools/test/run.mjs` 添加 `import './start-window-regression.mjs';`。
- [x] 运行 `node tools/test/start-window-regression.mjs` 与 `node tools/verify.mjs --steps=offline`，配置通过，两个档位各 typecheck 0 errors、271 passed / 0 failed。

### Task 2: 编译与交接

**Files:** Create `docs/validation/2026-10-01-brand-start-window-acceptance.md`。

**Interfaces:** clean HAP 构建消费 profile 与 media 资源；验收文档记录实跑结果而非设备推测。

- [x] 设置 `DEVECO_SDK_HOME=D:/local/DevEcoStudio/sdk`，运行 `node D:/local/DevEcoStudio/tools/hvigor/bin/hvigorw.js clean --no-daemon --no-parallel`。
- [x] 运行 `node D:/local/DevEcoStudio/tools/hvigor/bin/hvigorw.js --mode module -p product=default -p module=entry@default -p buildMode=debug assembleHap --no-daemon --no-parallel --max-old-space-size 1024 --Xmx 256`，实际 BUILD SUCCESSFUL，ArkTS:WARN 287、ArkTS:ERROR 0。
- [x] 保存设备冷启动清单：浅色、深色、暖图标底板、底部字标、首帧切换与温启动不额外显示自绘页；均保持待用户验证。
- [x] 检查仅新增启动资源、配置与回归；不提交用户 WIP，不部署云，不操作设备。
