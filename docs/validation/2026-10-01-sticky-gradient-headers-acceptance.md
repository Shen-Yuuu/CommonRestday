# 固定标题与渐隐页头：实施与验收

日期：2026-10-01。范围：同休、我的、共同时间、日程录入。只改展示；编辑器、详情和隐私面板未增加渐变页头。

## 已实施

| 页面 | 变化 |
| --- | --- |
| 同休 | 新增固定「同休」大标题，原问候语与伴侣状态移至副标题；日期印章保留。上滑时标题缓慢缩小、内容在页头下渐隐。 |
| 我的 | 新增固定「我的」标题；保留身份、伴侣与同步、日程、作息；反馈后把「数据与隐私」直接放回主页，取消「更多设置」收纳。 |
| 共同时间 | 保留现有固定标题、三段切换和筛选；列表及计划内容使用 24vp 渐隐边缘，周历使用 12vp。滚动后才出现，停在顶部时隐藏。 |
| 日程录入 | 返回、我/TA、周历/日程管理固定；班表和管理卡片在下方滚动，顶部为 24vp 渐隐边缘，滚动后才出现。 |

共享组件：`entry/src/main/ets/component/FadingHeader.ets`。页头在阅读顺序中先于正文；装饰边缘禁用命中和读屏。主题颜色沿用现有资源，减少动效时保持大标题不缩放。

标题缩放不改变布局高度；正文顶部占位按页头实际量高更新（变化超过 0.5vp 才写状态），支持副标题换行和系统大字体。达到最小标题尺寸后继续上滑不再写入新的标题偏移状态。

当前效果边界：第二次截图反馈后撤掉标题底的矩形系统背景模糊。标题与下沿共用一层页面底色遮罩，下沿在 36vp 内逐渐透明；不模糊标题，不会再从下方粉色 Hero 采样成整块粉色背景。本版是连续底色渐隐，不是像素级连续渐进背景模糊。

## 本机验证

命令：`node tools/verify.mjs --steps=offline,debug,release,ohostest`。

- 新增一条离线用例（8 个边界断言）：负偏移、零偏移、中点、终点、超界、减少动效、NaN、Infinity。
- 第一次红灯：未导出 `ScrollHeaderMotion`，类型编译失败，测试未启动。
- 首次 UI 构建红灯：`onMeasure` 与系统组件方法重名、Area 高度含 Resource 类型；已改为 `onHeaderHeight` 并补类型分支。
- 最终门禁：`ALL PASS` / exit 0，已对最终应用源码重跑。
- 离线 closed / open 两档：各 `typecheck 0 errors`、`267 passed / 0 failed`，静态审计通过。
- debug / release：均 `BUILD SUCCESSFUL`，`ArkTS:WARN 287`（基线 289）。
- ohosTest：`BUILD SUCCESSFUL`，`ArkTS:WARN 267`（基线 269）；只是编译成功。
- 日志：`E:/desktop/Code/harmony/.crdtest/verify-offline-{closed,open}.log`、`verify-{debug,release,ohostest}.log`；`git diff --check` 退出码 0。

只构建 ohosTest HAP，没有运行设备测试。未修改告警基线，不连接模拟器，不安装/卸载应用，不清空任何数据；已有工作树修改未提交。

## 你需要操作的验收（全部待设备）

用 DevEco Studio 正常运行更新后的应用即可，不需要重新配对、卸载或清数据。

- [ ] 同休：慢慢上滑至少两张卡，标题始终在顶端并逐渐缩小；滑回顶部恢复大标题。日期印章保留，副标题不截断，不出现双标题或反复跳动。
- [ ] 我的：滚到底部再回顶部；确认身份摘要和所有「管理/修改/打开」入口仍可点。分别打开伴侣、作息与隐私面板，关闭后页头和滚动位置正常。数据与隐私直接可见，没有「更多设置」入口。
- [ ] 共同：依次切列表/周历/计划，滚动列表和计划，观察最上沿的淡出；筛选芯片、日期、切周与计划卡仍可点击。周历上沿不被大面积遮罩遮住。
- [ ] 日程录入：在周历和日程管理中分别滚动；返回和切换按钮始终可见。已有本机代录时来回切我/TA，检查数据随侧别变化、无重复工具栏或闪烁。
- [ ] 四个页面分别下拉刷新；只观察转圈与内容，不要为了测试改变已有班表。页头不跟随刷新整体下移，刷新可正常结束。
- [ ] 应用在前台切深色/浅色，再做深色冷启动；页头及渐变跟随主题，标题下没有错误的浅色或深色横条，正文穿过页头时文字仍清楚。
- [ ] 系统字体设为 2.0×，确认页头量高、标题与副标题不重叠，第一张卡不被遮住，最后一张卡能滚到；验完恢复原字体。
- [ ] 开启系统减少动效，确认标题不随滚动缩放；关闭后再测试正常缩放。读屏先读页头再读正文，不朗读空渐变层。

请反馈「哪一页、深色/浅色、顶部/滚动中、具体不舒服之处」；截图最好同一页顶部和上滑后各一张。视觉观感、点击穿透、滚动性能及大字体实际渲染均未由本机编译代替验收。

## 截图反馈修订：灰黑接缝与主页隐私入口

用户提供同休、共同时间、我的三张浅色截图：渐隐带均出现灰黑色。这不是预期的分隔阴影；共同页只用渐变、没有标题背景模糊，也有同样接缝，所以修正共享的 `HeaderFadeEdge`，不是移除卡片阴影。

旧终点为通用 `Color.Transparent`；结合屏幕表现，判断颜色插值混入透明黑的 RGB。现在使用 `page_grad_clear`：浅色 `#00FFF0E7`、深色 `#002E2445`，与各自 `page_grad_top` 保持相同 RGB，只让 alpha 从不透明降至 0。使用原生深浅资源，避免提前解析颜色后在前台换档时冻结。

我的页窄屏和宽屏均直接调用 `dataCard()`，隐私政策直接开独立面板；删除入口仍走原确认框、原清库流程。移除「更多设置」卡及对应详情分支，云端未删除告知继续直接展示。没有执行任何清空操作。

新增 `tools/test/header-fade-regression.mjs` 并接入离线 runner：验证两档端点匹配、拒绝透明黑/跨档颜色/非透明终点、组件实际使用新令牌，以及两种布局直接展示数据与隐私。先红（缺少新资源）后绿；此检查验证配置和结构，不验证渲染像素。

本轮最终门禁 `ALL PASS` / exit 0：离线两档各 `typecheck 0 errors`、`267 passed / 0 failed`，新增结构与颜色回归检查通过；debug/release 均成功、WARN 287，ohosTest 编译成功、WARN 267。告警基线未修改，`git diff --check` 通过。未操作模拟器，黑边消失的像素证据仍待复验。用户更新运行后请检查：

- [ ] 三页浅色接缝不再灰黑；同休和我的上滑后、共同列表首卡处均检查。
- [ ] 前台切深浅色与深色冷启动，渐隐仍与各自页面底色一致，不残留浅色带。
- [ ] 我的页直接看到隐私政策与清空数据；隐私打开/关闭正常，清空框可取消。不要为了验证布局真的删除数据。

## 第二次截图反馈：横向模糊条带与周历无法滚动

用户截图说明上一轮只调整透明终点不充分：均匀模糊矩形与短渐变条仍是两块独立表面，模糊在边界被硬截断；下方 Hero 也会把标题底染成粉色。原“模糊底 + 另接渐隐边缘”结构已撤下，不把此前的编译成功当作视觉通过。

本轮改动：

- `FadingHeaderSurface` 改为一个连续背景渐变：按真实标题内容量高，在文字区域保持页面底色，接着在 36vp 尾部透明渐隐。文字层单独绘制，背景层禁止命中与读屏；不再调用 `backgroundBlurStyle`。
- 列表、计划、班表的边缘遮罩读实际滚动偏移，0vp 时透明、24vp 时完整显示。周历用更轻的 12vp 遮罩。计划遮罩从共同页宿主移到实际计划 List，不盖住它的固定操作行。
- 周历原 Scroll 没有明确高度，dock 留白又写在 Scroll 自身。现在指定 `height('100%')` 占满 Refresh 的确定剩余空间，留白放到内层 Column；启用竖向滚动与短内容回弹，保留切周、日期点击及下拉刷新。

周历布局缺口已从源码核实，但尚未在设备证明它是用户现场手势失败的唯一原因；如果更新后仍异常，请保留周历整页截图和从拖动到松手的短录屏，不用卸载或清数据。

新增两条纯逻辑用例验证遮罩显隐边界和按量高确定渐变起点；结构回归检查先红后绿，并明确不验证渲染像素。最终 `verify: ALL PASS` / exit 0：离线 closed/open 各 typecheck 0 errors、269 passed / 0 failed；debug/release 均成功、WARN 287；ohosTest 编译成功、WARN 267，未执行设备测试。基线未上调，`git diff --check` 通过。

更新运行后的重点步骤：

- [ ] 同休、我的先回到顶部再慢慢上滑：标题底为页面底色，下沿逐渐露出内容，没有独立横向模糊条；日期、标题和副标题清楚。
- [ ] 共同列表及计划顶部静止时没有常驻横带，滚动后边缘才出现；回顶部后隐藏，操作行与筛选保持清晰。
- [ ] 共同周历从网格中间向上拖，确认能看到底部图例与说明；再向下拖回顶部，然后继续下拉测试刷新。若内容本就全部可见，不要求产生不存在的滚动距离。
- [ ] 周历切下一周、点日期和色块仍有效；切列表再回周历，当前周不丢。深浅色切换时遮罩颜色随主题更新。

## 第三次反馈：周历点击、滚动、切周全部无响应；抬头间距过大

用户补充了比上次更完整的现象。上一轮「明确 Scroll 高度」不是完整修复，不将其构建成功当作设备通过。

源码/SDK 证据：

- 本机 `D:/local/DevEcoStudio/sdk/default/openharmony/ets/component/common.d.ts` 的 overlay 注释明确指出，覆盖层默认阻挡下层交互，需在 Builder 最外层设置 `HitTestMode.Transparent`。原 Builder 直接返回自定义组件，只在组件内部渐变 Row 上设置 None，遗漏最外层处理；与全域触摸失效相符，最终事件表现仍待设备确认。
- `WeekScheduleView` 根 Column 曾使用 `.enabled(!this.loading)`，把切周、重试等一起锁住。该缺陷从源码可确认，但没有设备证据表明现场 loading 一直为 true，不以它独自解释所有现象。
- 两排 44/48vp 导航热区加一行常驻 20vp 加载占位（加载结束变成空文字但不消失），造成标题和网格之间的冗余高度。

本次修正：四个 overlay Builder（共同列表/周历、计划、班表）统一使用限定高度的原生 Row + Transparent，内部渐变继续 None；不修改正文命中。周历取消整块禁用，读数用当前令牌的 finally 收尾，昵称获取也纳入 try；日期、切周可继续操作，加载/失败时旧空闲块不允许拿去建计划。日期范围、左右箭头、本周合为一排；纵轴/更新状态另用紧凑一行，删除 20vp 空占位，间距改为 4vp。共同/日程两种日期表头新增点击，共同计算范围外仍不开放。

新增结构回归先红（overlay 无原生穿透外层）后绿；它检验源码接线，不执行 ArkUI 渲染或手势。本轮 `node tools/verify.mjs --steps=offline,debug,release,ohostest` 最终 ALL PASS / exit 0：离线 closed/open 各 typecheck 0 errors、269 passed / 0 failed；debug/release 构建成功，WARN 287（基线 289）；ohosTest 编译成功，WARN 267（基线 269）。未修改基线，修改文件 `git diff --check` 通过。本机未连接或操作模拟器，设备点击/滚动/间距仍待复验。

无需卸载、清库或重新配对；用 DevEco 正常运行新版本后按以下步骤检查：

- [ ] 共同 → 周历：点右箭头、左箭头，日期范围应各变化 7 天；连点两次后停下，最终标题与内容属于最后选中的一周。
- [ ] 点「本周」回当前周；点计算范围内的一枚日期表头，打开当天明细，关闭后仍停在该周。
- [ ] 点共同空闲色块应进入计划详情；若正在更新，等「更新中…」消失后再点。加载不应妨碍切周和拖动。
- [ ] 在网格中部向上拖，能看到下方图例/说明；向下拖回顶再继续下拉，刷新结束后仍可切周。内容不满一屏时只要求回弹/刷新，不要求虚构滚动距离。
- [ ] 抬头比旧版紧凑且没有空白加载条；浅/深色及 2× 字体下，日期范围、本周和箭头不重叠。日程录入周历也检查一次日期点击和切周。
- [ ] 共同列表、计划卡及日程录入入口仍可点击并滚动，确认共享遮罩修改没有新回归。

## 第四次反馈：首卡留白、副标题淡出、滚动闪烁及跨页扩散

用户确认实施方案，设计/步骤分别见 `docs/plans/2026-10-01-stable-scroll-headers-design.md` 和 `docs/superpowers/plans/2026-10-01-stable-scroll-headers.md`。

本次实现：

- 同休/我的 `headerHeight` 只接实际内容高度，正文 `contentInset(height)` 增加 8vp，不再增加 36vp 渐隐尾部。Sticky 的顶留白 24→16vp、底留白 12→0vp；尾部渐隐 36→16vp，叠绘而不推开首卡。大字体仍按实际内容量高，不固定标题高度。
- 副标题透明度为 `1-progress(offset, reduceMotion)`：上滑 0/48/96vp 时为 1/0.5/0，回顶恢复。节点与高度不变；减少动效开启时标题不缩放且副标题可见。
- 四个滚动入口（共同列表/周历、计划、班表）使用共享 `FadingScrollViewport`，普通 Stack 的固定子节点绘制 HeaderFadeEdge，根节点定高并 clip；移除全部旧 overlay Builder。装饰内外禁止触摸命中，只在透明度改变时更新状态，不在滚动中条件挂载/卸载。
- 原生 Column 接布局权重，Refresh 填满视口；日期抬头仍是滚动内容。切周、日期/色块、计算范围边界、双 sheet、同步/数据逻辑均未改动。

诊断边界：SDK 和官方 overlay 文档明确 CustomBuilder 随页面刷新重建；源码中的滚动更新正好触发该路径，因此作为优先修正对象。没有设备渲染日志/追踪，不能宣称它已经证实是跨页扩散的唯一原因，也不能宣称本轮已经消除所有闪烁。

验证过程：结构回归先红（发现 CoTimeView 仍有 overlay）后绿；追加两条纯逻辑用例，离线 runner 271 passed。首次 UI 门禁失败：四个自定义组件尾随内容块后直接链式设置布局属性，ArkUI 报 Declaration or statement expected；改为原生 Column 承接后重新执行门禁。

最终 `node tools/verify.mjs --steps=offline,debug,release,ohostest`：ALL PASS / exit 0。offline closed/open 各 typecheck 0 errors、271 passed / 0 failed；debug/release 均 BUILD SUCCESSFUL、WARN 287（基线 289）；ohosTest 编译 BUILD SUCCESSFUL、WARN 267（基线 269）。告警基线未调整，修改源码 diff --check 通过；日志仍在 `E:/desktop/Code/harmony/.crdtest/verify-*`。测试包只编译未运行，不把编译结论改写成设备触摸/渲染通过；未操作模拟器，未提交 WIP。

用户更新运行即可，不用卸载、清库或重新配对；建议先关闭再正常打开应用，隔离上一个进程的渲染状态，而不是通过清数据复现。

- [ ] 同休/我的回到顶部，确认首卡紧贴页头、仍有约 8vp 呼吸间距。慢慢上滑，副标题逐渐淡出而非突然删行；回顶部恢复。正文不因为收起副标题而跳动。
- [ ] 共同周历连续上下拖动 10 次，尤其让日期导航反复经过视口上沿；不出现快速闪烁、残留抬头或画到置顶栏里。抬头正常滚出视口不算闪烁。
- [ ] 周历滚动后不重启应用，立即切同休、我的、共同列表/计划，分别滚动；确认接缝不闪、没有跨页残影。随后返回周历，位置和切周仍正常。
- [ ] 点左右切周/本周、范围内日期、空闲块，分别确认明细和计划面板；计划卡、日程录入入口可点。下拉刷新转圈可见、结束后还能滚动。
- [ ] 前台切深浅色、2× 字体以及减少动效：主题随切换、大字体不重叠；减少动效下保留副标题/原标题尺寸。验证后恢复原设置。

若仍闪烁，反馈一段从周历拖动开始、切换另一页并继续拖动的短录屏，说明是否停止拖动后立即稳定、冷启动后是否暂时恢复。只凭截图不继续猜测 GPU 或系统驱动原因。

## 第五次反馈：所有相关页面闪烁，标题大小来回跳变

用户实测否定第四轮修复的充分性；第四轮设备项仍未通过。本轮不再继续改变渐隐颜色或模糊参数，而是移除源码中仍存在的布局回写与整页滚动数值状态。

### 本轮实际修改

- 同休/我的由叠绘 Stack 改普通 Column：固定标题自然量高，正文用 layoutWeight(1) 占剩余空间。删除 headerHeight/headerOffset、页头 onAreaChange/onHeaderHeight 以及 contentInset 的动态占位；首卡只留 8vp。副标题节点/高度常驻，标题 fontSize 不随滚动变化，只有 scale 与副标题 opacity 变化。
- FadingHeaderSurface 退为自然高度实色 Column，不再量高生成渐变。渐隐只在有明确 height/clip 的正文视口内，滚动偏移为 0 时透明，没有独立模糊条。
- 六个实际滚动入口（同休、我的、共同列表、共同周历、计划、班表）各有独立 ScrollHeaderState；不共用跨页信号。@State 持有稳定实例，@Track 精确观察 offset；FadingScrollViewport 仅用 @ObjectLink 传递引用，不读取 offset。只有标题/渐隐叶节点读取该属性，不通过每帧页面数值状态驱动正文 Builder。
- 使用 Scroller.currentOffset().yOffset 的绝对偏移，限制在 0–96vp，同值不赋值；无计时器、防抖、animateTo 或新的隐式动画。原生 Scroll/List/Refresh、下拉刷新、周历切周/点日期/点色块、独立 sheet 与业务数据链保留。
- 删除本轮退役的 contentInset/opaqueStop 纯 helper 及对应两条旧形态断言，替换为绝对偏移范围/单调前进与回顶两条测试，故总数仍为 271；不是丢测试降低门禁。

依据：本机 ArkUI 声明与[官方 @Track 文档](https://developer.huawei.com/consumer/cn/doc/doccenter-capabilities/api/ts-state-management-track)。第一版隔离尝试使用普通字段传 @ObjectLink，编译不允许，已经改为状态对象来源 + 属性级 @Track。API 支持验证不等于现场渲染验证；目前只能证明这两条风险路径从源码移除，不能宣布找到跨页闪烁的唯一根因或已经设备修复。

### 本机证据（2026-10-01）

- 结构回归先红（旧 HeaderFadeEdge 未叶节点观察）后绿；固定页头无量高回写、正文不读 offset、渐隐不挂卸、六个控制器无页面偏移数值状态均有源码检查。它不执行 ArkUI 渲染。
- 最终 `node tools/verify.mjs --steps=offline`：ALL PASS / exit 0；closed/open 各 typecheck 0 errors、271 passed / 0 failed。
- 默认 `node tools/verify.mjs --steps=offline,debug,release,ohostest` 本轮 **FAILED**：debug/release Node Zone Allocation out of memory，ohosTest 的 PackageHap 报 DOS 1455（页面文件太小）。读取系统资源时约 600MB 空闲物理内存；未关闭任何模拟器/程序，未调整 Windows 页面文件。
- 改用本机 CLI 已确认支持的 `--no-parallel --max-old-space-size 1024 --Xmx 256` 临时参数，三档各自 clean 后重新出包。debug/release/ohosTest 均 BUILD SUCCESSFUL，WARN 分别 287/287/267（基线 289/289/269），0 ArkTS Compiler Error；未改仓库构建配置/告警基线。不能把这次低内存串行复跑写成默认全量命令 ALL PASS。
- 低内存复跑日志：`E:/desktop/Code/harmony/.crdtest/verify-debug-serial.log`、`verify-release-serial.log`、`verify-ohostest-serial.log`；默认内存失败日志保留在原 verify-debug/release/ohostest.log。第一遍串行编译错误日志已被最终 debug 串行日志覆盖，API 修正过程仅以本文记录，不另称有独立日志归档。
- 修改源码 `git diff --check` 通过；未提交 WIP。未操作、安装或运行模拟器，未执行 ohosTest 设备测试，未清库/卸载/解除配对。

需要低内存出包时，PowerShell 设置 `DEVECO_SDK_HOME` 后使用以下命令；切换档位前重新 clean：

```powershell
$env:DEVECO_SDK_HOME='D:/local/DevEcoStudio/sdk'
node D:/local/DevEcoStudio/tools/hvigor/bin/hvigorw.js clean --no-daemon --no-parallel
node D:/local/DevEcoStudio/tools/hvigor/bin/hvigorw.js --mode module -p product=default -p module=entry@default -p buildMode=debug assembleHap --no-daemon --no-parallel --max-old-space-size 1024 --Xmx 256
```

release 使用 `module=entry@default / buildMode=release`；测试包使用 `module=entry@ohosTest / buildMode=debug`。这是编译/打包，不执行设备测试。

### 用户设备复验（尚未勾选）

DevEco 正常运行更新后的项目，关闭应用再正常打开一次，不必卸载、清数据或重新配对。运行时若电脑报内存不足，可自行暂时关闭不参与复验的第二台模拟器，再编译；本轮 UI 验证不需要两台同时运行。

- [ ] 先同休再我的，各从顶部缓慢上滑/下滑 10 次。标题只沿拖动方向平滑缩小/恢复，不在同一位置来回跳大小；副标题淡出/恢复，正文及首卡位置不跳。
- [ ] 共同 → 周历，连续上下拖动并让日期抬头越过视口上沿；停止拖动观察 3 秒。应无快速闪烁、残留抬头或画到固定栏里；正常滚出视口不算闪烁。
- [ ] 不重启应用，立即切共同列表、计划、同休、我的及班表，分别滚动，再回周历。确认异常不扩散，列表/周历/计划切换和滚动位置仍正常。
- [ ] 周历左右切周/本周、日期/空闲块、首页答案、我的管理/隐私面板各点击一次；详情能关闭。下拉刷新结束后仍可滚动。不要真的清空数据。
- [ ] 前台深浅色切换、2× 字体与减少动效下复查：文字不重叠，标题自然占位，减少动效保留原标题大小和副标题；测试后恢复设置。

若仍闪，请提供 10–20 秒录屏，包含缓慢拖动、松手停住、切到另一页继续拖动，并说明冷启动是否即闪。下一轮先对比输入偏移/实际组件更新与渲染帧，不再把某个 SDK 限制或模拟器/GPU 作为未经取证的唯一原因。
