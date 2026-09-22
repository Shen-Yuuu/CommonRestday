# 性能预算与 TaskPool 门槛（阶段 5 Task 5.4）

> 记录日期：2026-09-22
> 测量入口：离线 `node tools/perf/budget.mjs`（本轮已跑）；设备侧 `hdc shell hilog | grep PERF`（**未执行 → 待设备**）
> 门槛代码：`feature/src/main/ets/performance/RecomputeExecutor.ets`
> 结论：**120 天重算贴着 16ms 预算、≥150 天在开发机下界就已超预算 → 引擎段按"视界 + 实测"两级门槛迁移 TaskPool；快照编解码与列表投影低于预算两个数量级 → 明确不迁移。**

## 1. 预算表

阈值口径：16ms = 60fps 一帧，主线程上一段纯计算最多占一帧；冷启动与滚动阈值是**本项目自设口径**，没有引用外部基准（拿别家 App 的数字当标准没有意义）。

| # | 段落 | 预算 | 本轮实测 | 判定 |
|---|---|---|---|---|
| 1 | 冷启动首屏可交互 | 自设 ≤ 1000ms（P50）/ ≤ 2000ms（P95） | 未测（设备侧） | **待设备**，见 §6-1 |
| 2 | 120 天共同时间重算（引擎段） | 主线程 ≤ 16ms | 稠密配对 P50 13.57 / P95 14.30；轻班表 P50 2.10 | **贴预算**：120 天不迁移，≥150 天迁移（§4） |
| 3 | 快照编解码（120 天，L1/L2/L3） | 主线程 ≤ 16ms | build+encode+decode 合计 P95 ≤ 0.16ms | **远低于预算 → 不迁移**（§5） |
| 4 | 1000 窗口列表滚动 | 帧耗时 P95 ≤ 16.6ms | 数据投影 1000 行 P50 0.75 / P95 0.96；**渲染帧耗时未测** | 投影不是瓶颈；渲染 **待设备**，见 §6-2 |

## 2. 离线实测（可复现）

```
node tools/perf/budget.mjs        # 首次会自动先跑 node tools/test/run.mjs 产出转译结果
CRD_PERF_MACHINE=<机型/负载档> node tools/perf/budget.mjs   # 换机器时把标识打进表头
```

脚本跑的是**同一份 .ets 转译出来的 JS**（domain 引擎 / SnapshotCodec / feature 读模型装配），不是另写一遍的等价实现；`process.hrtime.bigint()` 计时，就近取秩（不插值）。

夹具（稠密档）：5 种班次类型（含夜班跨天）+ 7 长度循环模板 + 20 条单日覆盖 + 40 门课（单双周混排）+ 12 段已确认计划，对方走同一条 expand→buffer 管线；轻档为「一种白班 + 做一休一、无课程无计划、单人」。节次模板取 App 默认 12 节，参数取 `defaultParams()`。

```
segment                       n     p50       p95       max       p95 vs 16ms
recompute_120d_light          60     2.104     2.523     2.756   在预算内
recompute_120d_solo           60    11.874    12.504    12.829   在预算内
recompute_120d_paired         60    13.569    14.301    15.044   在预算内
recompute_366d_paired         30    72.281    73.446    73.875   超预算
snapshot_build_L1_120d        40     0.109     0.153     0.419   在预算内
snapshot_encode_L1_120d       60     0.025     0.034     0.054   在预算内
snapshot_decode_L1_120d       60     0.025     0.120     0.215   在预算内
snapshot_build_L2_120d        40     0.144     0.164     0.177   在预算内
snapshot_encode_L2_120d       60     0.032     0.055     0.127   在预算内
snapshot_decode_L2_120d       60     0.082     0.142     0.160   在预算内
snapshot_build_L3_120d        40     0.091     0.098     0.100   在预算内
snapshot_encode_L3_120d       60     0.014     0.022     0.073   在预算内
snapshot_decode_L3_120d       60     0.069     0.117     0.182   在预算内
page_projection_96w           80     0.090     0.147     0.431   在预算内
page_projection_1000w         60     0.746     0.961     1.654   在预算内
夹具：窗口 96 个（常规+旅行）｜列表行 89 行｜压测列表行 926 行｜L3 明文 5352 字符
```

视界扫描（稠密配对，P50）：`60d=3.4ms 90d=7.6ms 120d=13.6ms 150d=20.3ms 180d=25.6ms 240d=40.0ms 366d=72.0ms`
→ 在开发机上约 130 天处穿过 16ms，且成本对视界近似线性。`HORIZON_MAX = 366`（`feature/src/main/ets/model/RhythmRules.ets:5`）是用户可设的合法值，所以**超预算路径今天就能走到**，不是假想情形。

口径边界（必须连着这张表一起读）：

- 采样环境是开发机 x86 单线程，设备主线程通常更慢 → 这张表是**下界**。下界已超预算（≥150 天）足以判定要迁移；下界未超（120 天 13.6ms）不能反过来证明设备上安全。
- **设备倍率本轮不猜**（没有真机，任何 ×2/×4 都是编的）。设备数字只能由 §6 的 hilog 采样回填。
- Node 的 GC 与时钟精度和 ArkTS 运行时不同，亚毫秒段（encode/decode）只用于比较量级，不用于报绝对值。

## 3. 列表规模的结构性上界

`CommonTimeQueryService.mergeByDay()` 每天只保留最长的一段，因此**列表行数 ≤ 视界天数 ≤ 366**，与引擎产出多少窗口无关（120 天稠密档：96 个窗口 → 89 行）。所以：

- 文档口径里的「1000 窗口列表」在现网数据模型下不可达，`page_projection_1000w` 是人为超量参照（把 96 个窗口平移复制 10 遍）；
- 该量级下 `List + ForEach` 的投影成本 P95 0.96ms，不是瓶颈，**本轮不引入 `LazyForEach`**（见 §5）；
- 若将来把列表改成"按窗口不归并"或放开 `HORIZON_MAX`，这一条要重测。

## 4. 门槛规则（代码里的判定）

`RecomputeExecutor` 是唯一决定"引擎段跑在哪个线程"的地方，`ScheduleUseCase.recompute()` 的 4 个调用方（冷启动 `EntryAbility`、卡片 `FormAbility`、首页、共同时间页）都经它。

| 规则 | 取值 | 依据 |
|---|---|---|
| 预算 | 16ms | 一帧；超过就要付掉帧代价 |
| 静态下限 | `horizonDays >= 150` 直接上 TaskPool | §2 扫描里**下界已超预算**的最小档；等真机攒够样本才迁移，等于先让第一批用户各卡一次 |
| 实测门槛 | 同标签 ≥8 个样本且 **P95 > 16ms** 才迁移 | 一次抖动不足以改变线程归属；P95 而非 max，是为了不被单次 GC 毛刺永久改策略 |
| 迁移后不回落 | 进程内 sticky | 切换本身要付一次跨线程序列化；视界调小靠下次冷启动自然回到内联 |
| TaskPool 失败 | 捕获后**退回内联** | worker 起不来（10200003）/序列化失败（10200006）都不能让本机算不出共同时间——本地主流程优先于线程策略 |
| 计时时钟 | `systemDateTime.getUptime(ACTIVE, ns)` | 纳秒分辨率（微秒级 codec 段才量得出）、跨深睡不产生负值或巨大值；`Date.now()` 毫秒级不够 |
| 只测纯计算段 | 线程归属只看 `common_free_engine` | `save_recompute`（写入+重算+广播的端到端墙钟，含 RDB I/O）同样记录，但超预算不能靠挪线程解决，所以不参与判定 |

每次采样都会打一行 hilog（`Logger.perf` → 固定 `PERF` 前缀、info 级，因为 debug 级在 release 包默认被过滤，验收取不到数）：

```
PERF common_free_engine mode=inline horizon=120 n=8 last=13.912 p50=12.904 p95=14.301 max=15.044 budget=16
```

## 5. 明确不迁移（以及为什么）

「不得为小数据强行引入跨线程序列化」在本轮的具体落点：

- **快照 build/encode/decode**：合计 ≤0.5ms（§2）。跨线程要把 `SnapshotData` 里 5760 位位图和分钟级分段整份克隆到 worker，序列化代价与省下的主线程时间同量级，净亏。云端链路本身仍处 `CLOUD_BLOCKED`（Task 0.4 门禁），更没有必要提前优化。
- **读模型投影 `assemblePage`**：366 行上限下 P95 1.5ms 以内。
- **日视图 `buildAvailability(days=1)`**：单日量级远低于 120 天，且是点开 Sheet 的同步路径，挪走反而要加一次异步态。
- **RDB 读写（`replaceWindows` / `listOverrides`）**：TaskPool 任务体拿不到 UI 上下文里的 `relationalStore`，也不该拿；这条的正确解法是索引与批量写入，不是换线程。
- **`LazyForEach` + `IDataSource`**：设备帧耗时未测（§6-2）之前引入，等于用一个未量到的数去换一次结构性重构。

## 6. 待设备（不得因为离线通过而勾掉）

1. **冷启动首屏可交互**：P50/P95 未测。取数：`hdc shell hilog | grep -E "AAmp|AppLaunch|PERF"`，记"进程起来 → 首页答案可见可点"，并单独记 `PERF common_free_engine` 那一行的 `mode/last/p95`（冷启动的重算就藏在这个数里）。
2. **列表滚动帧耗时**：366 天视界 + 稠密班表（≈366 行）快速滚动，记 P95 帧耗时与掉帧率（SmartPerf/hiAppEvent 均可）。**只有这一项超预算才动 `List` 的复用策略。**
3. **TaskPool 迁移的真实代价**：把视界设到 ≥150 天，比对 `mode=inline` 与 `mode=taskpool` 两种下的 `PERF` 行 `last`（含序列化）与同一次保存的 `save_recompute` `p50`，确认"主线程不再被占满"确实换到了更低的感知延迟；同时确认设备上没有出现 `taskpool compute failed, fallback inline`。
4. **120 天档是否也要迁移**：下界 13.6ms 已在预算边缘。若 §6-1 显示设备 P50 > 16ms，就把 `MIGRATE_HORIZON_DAYS` 下调（这是改一个常数，不是改架构），并回填本表。

回填位置：§1 表格第 1、4 行的"本轮实测"列 + §2 增加一列设备采样机型号与负载档。

## 7. 本轮改动与验证

| 文件 | 改动 |
|---|---|
| `feature/src/main/ets/performance/RecomputeExecutor.ets` | 新增：预算常量、两级门槛、@Concurrent 引擎任务、采样与 `PERF` 日志、失败退回内联 |
| `feature/src/main/ets/usecase/ScheduleUseCase.ets` | **列表外，必要改动**：唯一引擎调用点 `CommonFreeEngine.compute(input)` → `await RecomputeExecutor.compute(input)`（否则门槛无人执行）；`recomputed … in Xms` 改成 `engineMs=X`，避免把 worker 内计时误读成主线程占用 |
| `feature/src/main/ets/usecase/ScheduleCommandService.ets` | 保存路径的重算段套上 `RecomputeExecutor.measure(LABEL_SAVE_FLOW, …)` |
| `commons/src/main/ets/log/Logger.ets` | 新增 `Logger.perf`：固定 `PERF` 前缀、info 级（release 可取数） |
| `tools/perf/budget.mjs` | 新增：可复现的离线预算测量入口（§2 的表与扫描都由它产出） |
| `tools/test/run.mjs` | **列表外，必要改动**：新文件包 `@kit.ArkTS`/`@kit.BasicServicesKit`，加入 feature 跳过清单并补同名离线桩（计算照跑、永远内联），否则离线套件会在 `ScheduleCommandService → RecomputeExecutor` 这条 import 上挂掉 |

验证：`node tools/test/run.mjs` → **171 passed / 0 failed**（离线桩路径，不含 taskpool）；`entry@default` 构建见提交信息；§1 表中标 **待设备** 的三项**未判定**。
