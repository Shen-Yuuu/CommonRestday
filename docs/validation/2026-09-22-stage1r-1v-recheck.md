# 阶段 1R 整改与阶段 1V 视觉试点复验

> 复验日期：2026-09-22
> 复验范围：`docs/validation/2026-09-22-stage1-acceptance.md` 的 R1–R5 与出口清单，加上 `docs/plans/2026-09-22-warm-image-glass-visual-spec.md` 的 V0/V1 试点
> 结论：**阶段 1R 通过（代码与本地证据层级）；阶段 1V 试点完成，视觉验收仍为「待设备」**。可以进入阶段 2，但第 4 节的 5 项欠账不能被当作已完成。

## 1. 本轮提交的边界

阶段 1R 已在上一个提交落地：`5883162 fix(time): correct tonight duration and cross-midnight bedtime`。
本轮新增提交只包含视觉试点的 11 个文件（3 个新文件 + 8 个改动）。

工作树里另有 **10 个与本轮无关的用户 WIP 文件**（`SettingsStore.ets`、`ScheduleUseCase.ets`、`WindowDetailSheet.ets`、`EntryAbility.ets`、4 个 `pages/*` 录入页、`docs/README.md`、`docs/04-开发计划.md`）和 3 份未跟踪文档（`docs/05`、`docs/06`、`docs/testing-checklist.md`）**保持未暂存**，未随本轮提交。

## 2. 阶段 1R 出口复验（对照验收记录 §8）

| 出口条件 | 判定 | 证据 |
|---|---|---|
| R1–R3 边界测试通过 | 通过 | 今晚「未开始/已开始/恰好结束」三组、跨午夜就寝 22:30 / 00:30 / 01:00 / 与起床相同、视界文案消费读模型；`node tools/test/run.mjs` 全绿 |
| 阶段 1 新增页面/组件不再直接写 `ScheduleRepo` | 通过（留有已登记缺口） | `MeView`、`ScheduleHub`、`HomeView`、`DayShiftSheet` 已无 `data` 引用；`WeekScheduleView` 消费的是 `feature` 转发的 `SettingsStoreParams()`，不直连仓储。缺口见 §2.1 |
| 仓库内一条命令可复现单测 | 通过 | `node tools/test/run.mjs` → `127 passed, 0 failed, 127 total`，退出码 0，日志 `tools/test/out/last-run.log`；runner 与 `tools/test/README.md` 已入库 |
| clean assembleHap 成功 | 通过 | `hvigorw clean` → `assembleHap --mode module -p module=entry@default -p product=default -p buildMode=debug` = `BUILD SUCCESSFUL in 19 s 830 ms`，73 task 中 62 实际执行；**ArkTS ERROR 0 条** |
| 设备可用后完成 360vp / 返回栈 / 热区 / 深色 / 大字体 / 读屏 | **待设备** | `hdc list targets` 返回 `[Empty]`，本轮没有新增设备证据 |
| 云功能关闭时全程不阻断本地计算 | 通过（静态） | 门禁未动：`CLOUD_BLOCKED` 仍然关闭配对，短码派生长期密钥入 Preferences 的原型实现未启用 |

### 2.1 已登记但未在本轮收口的调用点

- `entry/src/main/ets/view/PlansView.ets:2,34` 仍 `import { ScheduleRepo } from 'data'` 并直接 `listActivePlans()`；
- `entry/src/main/ets/component/PrivacyDialog.ets:3,32` 仍直接 `SettingsStore.acceptPrivacy()`；
- 旧录入页（`Index`、`FormAbility`、`CourseImport`、`CycleEditor`、`OcrCourse`、`PaintMonth`、`ScheduleEditor`、`EntryAbility`）保持阶段 0 的直连方式。

判断：R4 的口径是「只清理阶段 1 新增与本阶段即将修改的调用点」。`PlansView` 属于阶段 1 页面但不在验收记录点名的四处之内，因此**记为缺口而非偏离**；它落在阶段 2 Task 2.2 的改动面上，届时随计划读模型一并收口，不单独再开一次刀。

### 2.2 构建警告现状（用于后续替换清单）

351 条 ArkTS 警告、0 错误，全部来自既有文件，Top：`ScheduleRepo` 162、`SettingsStore` 46、`SnapshotCrypto` 23、`CourseImport` 19、`OcrCourse` 13、`CycleEditor` 13、`Db` 13。
本轮新建/改动的 8 个视觉文件**没有产生任何新警告**；`AppNavigator.ets` 的 3 条是既有的 `getParams` / `pushUrl` deprecation。

## 3. 阶段 1V 试点落地范围

按规范限定在「材质基础设施 + 首页 + 底栏」，未触碰任何 Sheet 与录入页。

| 文件 | 职责 |
|---|---|
| `theme/DesignTokens.ets` | 新增气氛（`sceneWarm/Rose/Blue/VeilStrong/VeilSoft`）、玻璃（`glassStrong/Soft/Border/Highlight/Fallback/Shadow`）、几何与动效令牌；新增 `TRANSPARENCY_REDUCE_KEY` |
| `resources/{base,dark}/element/color.json` | +11 项/套，深浅色成对；两份仍是合法 JSON，共 61 项 |
| `theme/MaterialPolicy.ets`（新） | 唯一能力探测口：`isImmersiveMaterialSupported()` + `getMaterialInfo().state` + `getGlobalMaterialLevel()`，`SMOOTH`/`DISABLE`/抛异常一律退 `SOLID`；按档位缓存 `ImmersiveMaterial`（STRONG=THICK+`glass_strong`，SOFT=REGULAR+`glass_soft`，`applyShadow:true`、`interactive:false`） |
| `component/GlassSurface.ets`（新） | 双路径容器：材质路径只给 `systemMaterial(...)`，实色路径给近实色底 + 1vp 边框 + 顶部高光线 + 投影。`GlassStyle` 把「填充/边框/阴影/是否实色」的分支规则收在一处 |
| `component/AmbientScene.ets`（新） | 首页气氛层：62% 高三段暖色斜向渐变 + 全屏暖白雾罩，`hitTestBehavior(HitTestMode.None)`；**纯渐变、无位图、无运行时高斯模糊** |
| `component/EditorialCard.ets` | 新增 `glass` 开关，表面填充/边框/阴影改为计算属性；材质路径下背景透明交给 `systemMaterial`。按压、焦点环、键盘回车、入场动效仍只有一份实现（焦点环优先于玻璃边框） |
| `component/NextWindowHero.ets` | 仅 WINDOW / NEED_PARTNER 两种 Hero 走玻璃；NO_WINDOW 维持纸面。深浅两条路径都保证文字底下有稳定深莓底 |
| `view/HomeView.ets` | `Scroll` 外包一层 `Stack`，气氛层在内容之下、页面底色在最外；`bindSheet` 位置不变 |
| `navigation/AppNavigator.ets` | 系统 TabBar 收成 78 高透明占位带（`barBackgroundColor(Color.Transparent)` + 空 `@Builder` tabBar），真正的控件是底部 `GlassSurface` 悬浮岛（高 58、单项热区 50×74、选中态浅莓实心底），切 Tab 走 `animateTo`，减少动效时时长归零 |
| `docs/prototype/index.html` | 镜像：气氛层/Hero/悬浮岛 CSS、`玻璃：系统材质 / 实色回退`开关与状态保留、token 面板扩到 55 项、浅色雾罩色值对齐 `color.json` |

设计取舍（判断）：业务能力页**不探测材质**，只在 `MaterialPolicy` / `GlassStyle` 分支；因此阶段 2 重构 `WindowDetailSheet` 时接 `GlassSurface` 不需要再讨论能力判定。

## 4. 明确欠账（不得当作已验收）

1. **底图缺失**：规范 §2 的「温暖影像」需要 `resources/base/media/scene_*` 本地位图，本轮**未生成也未下载**（无设计确认的图，且禁运行时联网取图）。当前首页只有渐变气氛层，视觉完成度低于规范目标。需要选图后才能补齐。
2. **背景漂移未实现**：`DesignTokens.motionSceneShift` 与 `sceneDriftVp` 两个令牌已定义但**未被引用**，因为真机功耗/帧率证据为零。等首轮真机截图后再决定是否开启。
3. **「降低透明度」没有写入方**：API 26 的 `@ohos.settings` 里**不存在**系统级减少透明度开关（已核对可读键位清单，只有字体缩放、动画时长缩放等），所以 `crd_reduce_transparency` 与既有的 `crd_reduce_motion` 一样是**App 侧 AppStorage 键，目前无任何代码写入**，两条键都恒为 `false`。要真正验证回退路径，需要在「我的 · 高级设置」加一个开关（或改接无障碍读屏状态）。
4. **四组 360vp 截图未产出**：浅色 / 深色 / 1.3× 字体 / 降低透明度全部**待设备**（无真机、无模拟器，浏览器镜像也无法替代材质渲染）。本轮不自称视觉通过。
5. **`WindowDetailSheet` 未接玻璃**：按验收记录 §7 第三步的决定留给阶段 2 Task 2.2 一次性改完，避免同一个组件改两次。

## 5. 进入阶段 2 的判断

允许。理由：1R 的四项时间/分层/工程门禁都有可复现证据，1V 的基础设施已经能承载阶段 2 的 Sheet 改造，剩余欠账全部是「素材与设备」问题而非「结构」问题，不阻塞窗口—计划—系统日历闭环。

三条不要越界的提醒：

- 云端配对继续 `CLOUD_BLOCKED`，视觉迭代不构成提前启用理由；
- `docs/testing-checklist.md`（未跟踪）与 `NAV` 说明仍描述旧的 4 Tab / 8 筛选，Task 2.4 之前不要拿它做端到端判定；
- 阶段 2 触碰 `WindowDetailSheet` 时一并改掉 `@Component` 方法名 `create` 的编译告警。

## 6. 复现命令

```powershell
# 离线单测（纯逻辑：domain + feature 读模型 + 两套 Hypium 用例）
node tools/test/run.mjs

# 无 IDE 编译校验（本轮结果：BUILD SUCCESSFUL，ArkTS ERROR 0）
$env:DEVECO_SDK_HOME = "D:/local/DevEcoStudio/sdk"
node "D:/local/DevEcoStudio/tools/hvigor/bin/hvigorw.js" clean --no-daemon
node "D:/local/DevEcoStudio/tools/hvigor/bin/hvigorw.js" --mode module -p module=entry@default -p product=default -p buildMode=debug assembleHap --no-daemon
```

视觉镜像（不含系统材质，仅用于评审层级与配色）：直接用浏览器打开 `docs/prototype/index.html`，在「阶段 1V 玻璃试点」切换两种材质路径；底栏悬浮岛需在「完整版」下查看。
