# Startup RDB Probe Fix Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [x]`) syntax for tracking.

**Goal:** 修正升级后启动读取失败的结果集探测缺陷，原地补齐星期字段，并完成已确认的启动图标纯圆角裁剪。

**Architecture:** 保留现有 Db → RdbMigration → MigrationRunner 分层。探测必须读取结果集元数据；v4 缺星期字段时也进入事务补列。2026-10-03 用户复测否决了首轮的事务内读校验：补列与版本写入保持一个写事务，提交后才用读连接验证结构，通过后才发布 Db.store。测试直接装载生产 Db 源码，覆盖延后错误及 WAL 双连接可见性。

**Tech Stack:** ArkTS/API 26 RDB、Node SQLite/TypeScript/VM、PowerShell System.Drawing、Hvigor。

**Spec:** `docs/plans/2026-10-03-schedule-editing-design.md`；用户新增故障证据为 `startup init/recompute failed: Resultset is empty or column index is out of bounds.`；用户于本轮明确允许本地纯圆角裁剪。

## Global Constraints

- 不连接或操作模拟器，不卸载、清数据或部署云服务；设备日志及复测由用户提供。
- 本地 schema 仍为 4；新字段定义不变：`weekdays_mask INTEGER NOT NULL DEFAULT 127`。
- 不重建有效 v4 的表，不改旧行序列、起点或 owner；新版库跳过不降级。
- 原启动图标不覆盖，桌面图标不变；派生图只改变圆角区域 alpha，RGB 不改。
- 不提交、暂存或撤销已有 WIP；执行技能未安装，按本计划内联执行，不派子代理。

---

### Task 1: 结果集探测、已标 v4 的缺列修复

**Files:** `data/src/main/ets/db/Db.ets`、`data/src/main/ets/db/MigrationRunner.ets`、`entry/src/test/DbMigrationTest.ets`、新 `tools/test/rdb-adapter-regression.cjs`、`tools/test/run.mjs`。

**Interfaces:** RdbMigration.canSelect 签名不变；测试通过转译生产 Db.ets 并仅暴露内部类进行验证，替换的只有平台端口，不复制探测逻辑。

- [x] 创建延迟结果集测试：`querySql()` 先返回对象，合法空查询的 `columnCount=1`，缺字段时访问 `columnCount` 抛错；断言探测分别 true/false 且 close 执行。先运行，确认旧适配器失败。
- [x] 修正探测：

```ts
rs = await this.store.querySql(sql);
return rs.columnCount > 0;
```

- [x] 版本不高于本包时先探测 cycle 表及 weekdays 列，再决定升级；`recorded !== SCHEMA_VERSION || (cycleExists && !cycleHasDays)` 时沿用迁移事务。补列后再次探测，失败抛错，不 stamp。
- [x] 增加离线断言：v4 缺列原地补齐、失败回滚且保留版本／行、有效 v4 无结构写入；实际 Db.init + 内存 SQLite 覆盖旧 v1/v3、错误 v4、新装及异常后重试。
- [x] 将适配器测试接进 runner，继承 findTsc 的编译器路径；任何附加脚本失败都令门禁失败。运行离线与完整编译检查。

### Task 2: 非覆盖式启动圆角图标

**Files:** 新 `tools/design/round-start-icon.ps1`、新 `entry/src/main/resources/base/media/start_icon_rounded.png`、`entry/src/main/resources/base/profile/start_window.json`、`entry/src/main/module.json5`、`tools/test/start-window-regression.mjs`。

**Interfaces:** 输入 `AppScope/resources/base/media/jim1_resized.png`，圆角半径 22% 图宽；输出独立 PNG。源文件 SHA256 不变，尺寸与内部像素不变，四角 alpha=0。

- [x] 读取原图，以 C# 像素掩膜实现圆角、8×8 边缘采样，仅乘 alpha；不使用 AI 再生成，不覆盖原图。生成脚本在目标已存在时拒绝覆盖。
- [x] 验证全图 RGB 与来源一致，中心／边中 alpha 与来源一致，四角透明；查看派生图。
- [x] 仅 startWindowAppIcon 与 startWindowIcon 引用新资源；app.icon／ability.icon／品牌字标保持。
- [x] 启动静态门禁检查新资源尺寸、透明通道和四角；两档主题资源正常、首页无启动等待。

### Task 3: 交接与证据边界

**Files:** 新 `docs/validation/2026-10-03-startup-rdb-probe-fix.md`、更新本轮班表验收记录及原计划 Task 7。

- [x] 跑 `node tools/verify.mjs --steps=offline,debug,release,ohostest,perf`，记录准确数字，不扩大基线。
- [x] 检查本轮空白差异；文档分别写明适配器模拟、内存 SQLite、出包和设备复测，不将模拟边界测试说成真机通过。
- [x] 提供用户覆盖安装／重新运行的复测步骤，不清数据；列出首页、共同页、模板、冷启动图标检查，设备执行仍待用户。仍失败时请用户提供最新启动日志，不能继续猜测或建议清库掩盖问题。

### Task 4: 用户复测失败后的读写连接边界修复

**Files:** `data/src/main/ets/db/MigrationRunner.ets`、`tools/test/rdb-adapter-regression.cjs`、`entry/src/test/DbMigrationTest.ets`、`docs/validation/2026-10-03-startup-rdb-probe-fix.md`。

**Interfaces:** MigrationDb 接口不变；不增加 SDK 依赖。Db.init 仍只在 upgrade 完成后发布 store。事务提交后校验失败必须抛出，但不能对已提交事务调用 rollback。

**Spec:** 用户最新设备日志为 `cycle_template weekdays_mask is not readable after migration`，前后两次 `SELECT weekdays_mask FROM cycle_template LIMIT 0` 都报缺列。公开 RDB 源码的 querySql 申请读连接，补列尚未提交时它不必看到写连接的新列。

- [x] 新增 WAL 文件夹隔离夹具，两个 SQLite 连接分别负责写入与 querySql；使用生产适配器，先验证“写连接看得到未提交字段，读连接看不到，提交后可见”。夹具仅清理自己生成的临时文件，绝不读取用户数据库。
- [x] 在生产代码不变时运行 `node tools/test/rdb-adapter-regression.cjs`，记录旧 v1 初始化出现同一条迁移后校验失败（在首个旧库夹具即退出，不冒称三个版本都留存了红灯输出）。
- [x] 把校验移到 commit 之后、catch/rollback 之外；ALTER 与版本写入仍原子提交：

```ts
await db.setMeta(SCHEMA_VERSION_KEY, String(SCHEMA_VERSION));
db.commit();
// 退出事务 catch 后才执行：
if (cycleExists && !(await db.canSelect('SELECT weekdays_mask FROM cycle_template LIMIT 0'))) {
  throw new Error('cycle_template weekdays_mask is not readable after committed migration');
}
```

- [x] 扩充回归：新装、v1/v3、错误 v4 在单双连接都能启动，旧行保留；DDL／版本写入／提交错误回滚；提交后读故障不能发布 Db.store、不能回滚已提交事务，解除故障后重试不重复 ALTER；纯迁移测试禁止事务内探测。
- [x] 跑完整本机门禁，写入真实结果；文档撤回首轮“事务内校验适用于平台”的判断，保留历史失败记录。设备仍待用户覆盖更新复测，不操作模拟器、不暂存或提交。
