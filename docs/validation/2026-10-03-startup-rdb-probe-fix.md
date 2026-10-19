# 启动读取失败修复与圆角图标补齐

日期：2026-10-03。用户设备证据：

```text
startup init/recompute failed: Resultset is empty or column index is out of bounds.
```

**更新：首轮修复被用户设备复测否决。** 下文 §1–§5 留存首轮实施和本机结果，不代表设备通过。最新失败日志、原因修订及第二轮修复见 §6；当前必须在保留数据的设备覆盖更新后再确认。

## 1. 诊断结论

本次增加循环星期字段后，发现启动迁移探测存在真实缺陷：`RdbMigration.canSelect()` 仅等待 `querySql()` 返回对象，就认定该列可读，没有检查结果集元数据。返回 ResultSet 与列实际可读不能等同。

核查的 [OpenHarmony 查询接口实现](https://github.com/openharmony/distributeddatamgr_relational_store/blob/master/frameworks/js/napi/rdb/src/napi_rdb_store.cpp) 判断结果集对象非空后创建 JS 对象；[结果集实现](https://github.com/openharmony/distributeddatamgr_relational_store/blob/master/frameworks/native/rdb/src/sqlite_shared_result_set.cpp) 单独保留 prepare 错误，并在获取列元数据时返回错误。公开源码不是当前模拟器二进制的取证，不能冒充用户设备复现，但它证明“仅获对象就判成功”的契约不可靠。

**由项目代码和用户日志作出的判断：** 旧库的 `weekdays_mask` 可能被误判为已存在，升级只登记 v4 而未补列；随后读取模板新列的索引无效，就会触发用户日志中的结果集错误，启动重算无法完成。缺列还会使首页读取模型失败。这与用户现象高度吻合；最终设备因果确认仍以覆盖更新后的复测或更完整的日志为准。

上轮 296 条离线用例及出包通过并未覆盖该平台适配器。上轮内存 SQLite 的探测立即执行 SQL，与鸿蒙查询先给对象、访问元数据再暴露失败的边界不同。因此那些结果有效，但不足以宣称设备启动升级已通过；这一覆盖遗漏由本轮补齐。

## 2. 首轮修复内容（设备复测未通过）

- `Db.ets`：探测读取 `ResultSet.columnCount`，大于 0 才视为有效；空表的合法查询仍成功，缺表／缺列或元数据异常返回 false，结果集始终关闭。
- `MigrationRunner.ets`：版本不高于本包时检查实际星期列，即使版本已标为 4 但列缺失，也进入原事务补列；首轮在事务内再次检查列可读，成功才登记版本。**这项校验时机有误，已由 §6 的提交后校验取代。** 有效 v4 不重建、不更改行；更高版本仍不降级。
- 补列为 `INTEGER NOT NULL DEFAULT 127`，原模板默认每天；不修改 seq、anchor、owner，不清库，不删配对，不重部署云服务。
- 新增适配器回归直接装载生产 `Db.ets`，仅模拟平台查询对象，SQL 在内存 SQLite 执行；不连接用户数据库或模拟器。
- 首轮离线替身允许事务内读到自己补的列，这只符合同一 SQLite 连接的情况，**不能据此推断 RdbStore 的 querySql 与写事务共用连接**。这是首轮第二项测试覆盖遗漏，§6 已补齐。

### 留存的失败验证

1. 未改适配器时，新回归失败：缺列查询被旧 `canSelect()` 判为 true。
2. 仅修适配器时，回归仍失败：错误标为 v4 的库跳过补列，实际 SQLite 读取报 `no such column: weekdays_mask`。
3. 补齐 v4 结构修复和测试替身事务读语义后，适配器回归及离线 298 条用例通过。

回归覆盖生产 Db 新装、v1／v3 升级、错误 v4 原地补齐、有效 v4 保留两侧自定义 mask、补列失败回滚／再次初始化重试、合法空表，以及各结果集关闭。模拟平台边界测试不等于原生 RDB 设备测试。

## 3. 启动图标

用户本轮同意本地纯圆角裁剪。新资源为 `entry/src/main/resources/base/media/start_icon_rounded.png`，由 `tools/design/round-start-icon.ps1` 非覆盖式生成：1024×1024，半径 22%，8×8 边缘采样，仅改变四角区域透明度。

- 44,328 个像素 alpha 改变；全图 RGB 与原图逐像素一致，内部 alpha 不变，四角透明。
- 来源 `AppScope/resources/base/media/jim1_resized.png` SHA256 保持 `EFEC03382C5E266608C99ADFC1B9BB4D4A643B25DD50D70E3013380AA433458D`。
- 仅原生增强启动配置 `startWindowAppIcon` 与兼容字段 `startWindowIcon` 改为派生资源；桌面／Ability 图标、品牌字标和启动时间不改。
- 生成脚本自身校验之外，启动门禁使用独立 PNG 解码逐像素验证 RGB／alpha，并检查两个配置引用。
- 未采用此前两张图像生成结果，不声称是 AI 生成资产；本轮是明确授权的确定性裁剪，图片已经人工视觉检查，设备启动显示仍待用户确认。

## 4. 本机验证

执行 `node tools/verify.mjs --steps=offline,debug,release,ohostest,perf`，退出码 0，`verify: ALL PASS`，基线未调宽。

| 检查 | 结果与边界 |
| --- | --- |
| 离线 closed／open | 两档均 0 type error，298 passed / 0 failed |
| 生产 Db 适配器模拟 | PASS；先返回查询对象、缺列在元数据访问报错的边界已覆盖，不是实际原生设备执行 |
| 内存 SQLite | PASS；实际 SQL、旧模板两侧行、失败回滚及错误 v4 结构补齐 |
| debug／release | 均 BUILD SUCCESSFUL，WARN 287／287，基线 289／289 |
| ohosTest | BUILD SUCCESSFUL，WARN 267，基线 269；仅编译，设备未执行 |
| perf | 退出码 0，预算内；paired120 开发机 P50 为 16.4ms，不替代真机结论 |
| 启动 PNG | 独立解码逐像素 RGB／alpha 检查 PASS，两个启动引用已接入 |
| 空白检查 | 本轮已跟踪文件 diff --check 通过；新增脚本与文档逐行检查通过 |

本轮新增两条 Hypium 用例（296 → 298）；适配器及 SQLite 脚本另计，不混入这一数量。最新编译／离线日志在 `E:/desktop/Code/harmony/.crdtest/verify-offline-closed.log`、`verify-offline-open.log`、`verify-debug.log`、`verify-release.log`、`verify-ohostest.log`。perf 见本轮命令输出，没有独立日志文件。

## 5. 用户如何复测

1. 在 DevEco Studio 重新运行最新工程，或覆盖安装新生成的包；不要卸载、清数据，也不需要取消云配对。若只是重新打开已安装的旧包，修复不会生效。
2. 更新后进入“同休”与“共同”，检查是否恢复正常读取。原班表、课程、计划和配对应该保留；进入循环模板确认原序列与起点未变。
3. 退出后再次启动，检查不再出现读取失败；启动图标应有透明圆角，桌面图标不变。
4. 查看 DevEco 日志，正常会出现 `db ready schema=4/4`。如果仍失败，请提供最新 `startup init/recompute failed` 与附近 RDB 错误行；此时不能把本轮推断升级为已证实，也不能建议清库来掩盖迁移故障。

本轮未操作模拟器或桌面界面，没有 git 暂存、提交、回退或清理其他 WIP。发布结论仍不变：设备复测、真机与签名等既有发布门槛需要另行完成。

## 6. 用户复测失败后的第二轮修复

### 6.1 新证据与原因修订

用户重新运行后仍然显示“首页读取失败”，提供了：

```text
no such column: weekdays_mask in "SELECT weekdays_mask FROM cycle_template LIMIT 0"
startup init/recompute failed: cycle_template weekdays_mask is not readable after migration
```

后一条是首轮新增的迁移后校验错误，证明启动仍未越过迁移。后面的 HdsTabs、样式和图形警告不能解释这一明确的缺列查询失败，本轮不因这些伴随日志修改 UI。

核查本机 API 26 SDK 的 RdbStore 接口以及 [OpenHarmony RDB 实现](https://github.com/openharmony/distributeddatamgr_relational_store/blob/master/frameworks/native/rdb/src/rdb_store_impl.cpp) 和 [连接池实现](https://github.com/openharmony/distributeddatamgr_relational_store/blob/master/frameworks/native/rdb/src/connection_pool.cpp)：querySql 可取得独立读连接，写事务尚未提交的新结构不保证对它可见。公开源码仍不等于本机 HarmonyOS 二进制证据；结合下面的双连接复现，这是当前修复依据，最终仍需设备复测。

新测试使用临时 WAL SQLite 文件、一个写连接与一个只读查询连接，装载生产 Db.ets／MigrationRunner，不复制产品迁移逻辑。它先证明同一笔未提交 ALTER 在写连接上可读、在读连接上不可读，提交后两侧都可读。随后旧代码在 v1 升级的生产 Db.init 路径抛出 **与用户相同的 `cycle_template weekdays_mask is not readable after migration`**。这不是模拟器测试，但已独立复现所遗漏的连接边界。

原因链：补列 → 事务内读连接仍见旧结构 → 校验误报缺列 → catch 回滚补列 → 下次启动重复失败。首轮单连接测试不足以发现它；不应再让用户通过卸载或清库绕开升级问题。

### 6.2 当前实施

- 保留 `columnCount` 探测及错误标为 v4 的原地修复。
- 补列、旧主键升级及 schema_version 写入仍在一个事务，任何写步骤或提交失败都进入回滚。
- **commit 完成后、事务 catch 之外才检查星期列可读。** 检查成功后 Db.init 才发布 store；读故障仍抛出，但不对已提交的事务执行 rollback。故障消失后再次初始化看到有效结构，不重复补列。
- 无新 SDK 接口、无 schema 再升级、无业务默认值修改；旧模板每日默认 127，seq／anchor／owner 保留。没有接触用户数据库、配对、设备或云部署。
- 纯迁移替身按独立读连接处理，新增两条 Hypium 用例，断言事务内没有任何读探测、提交后读故障不会回滚已提交结构。
- 生产适配器回归在单连接与 WAL 双连接上分别覆盖新装、v1／v3、错误 v4、有效 v4、自定义星期保留；注入 ALTER、版本写入、commit 三种失败并确认旧版本／行回滚后可重试；另注入提交后元数据读故障，确认 store 不发布、事务不错误回滚。

临时夹具关闭连接后只删除自己生成的具名文件，目录通过非递归 rmdir 清理，未清理工作区或用户数据。测试仍模拟平台适配端口，不能标成原生 RDB／设备通过。

### 6.3 第二轮验证与交接

完整执行 `node tools/verify.mjs --steps=offline,debug,release,ohostest,perf`，退出码 0，**verify: ALL PASS**，没有调整基线：

| 本机检查 | 第二轮结果 |
| --- | --- |
| 离线 closed／open | 两档均 0 type error，300 passed / 0 failed |
| 生产 Db 适配器 | 延后错误、单双连接初始化、回滚及提交后读故障回归 PASS；平台端口仍为模拟 |
| debug／release clean 出包 | 均 BUILD SUCCESSFUL，WARN 287／287，基线 289／289 |
| ohosTest clean 出包 | BUILD SUCCESSFUL，WARN 267，基线 269；只编译，未在设备执行 |
| perf | 退出码 0，预算内；开发机 paired120 P50 16.1ms，不是设备性能证据 |

最新日志仍在上述 `.crdtest/verify-*.log`，其中的数字属于第二轮。300 为 Hypium 数量（首轮 298 → 第二轮 300）；SQLite／生产适配器脚本另计。本轮修改文件的空白检查与新增脚本语法检查通过。

用户复测只需在 DevEco Studio **重新构建并覆盖运行最新包，关闭会卸载／清数据的选项**；保留现有模板与配对。不需要新模拟器。检查同休与共同恢复读取、原模板序列／起点保留，再退出应用冷启动一次。正常日志应出现 `db ready schema=4/4`。

尚未从用户设备收到本轮通过证据。若仍失败，请提供 `startup init/recompute failed` 前后 RDB 错误；最新校验失败文案会含 `after committed migration`，可区分是否运行了本轮包。不要仅重新打开上一版已安装应用，也不要清库掩盖迁移故障。
