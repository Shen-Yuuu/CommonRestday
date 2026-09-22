# 离线单测入口（tools/test）

仓库内一条命令复现纯逻辑单测，不需要真机、不需要模拟器、不需要联网。

```bash
node tools/test/run.mjs
```

从仓库根目录执行。退出码：

| 码 | 含义 |
|---|---|
| 0 | 全部用例通过 |
| 1 | 有失败用例（明细见输出与日志） |
| 2 | 环境不满足（找不到 TypeScript 编译器） |

输出末尾给出日志路径：`tools/test/out/last-run.log`（转译告警 + 每个用例 PASS/FAIL + 汇总计数）。

## 环境要求

- Node 18+（用到 ESM 与 `spawnSync`）；
- 一个 `tsc`。默认取 DevEco Studio 自带的
  `D:/local/DevEcoStudio/tools/hvigor/hvigor/node_modules/typescript/bin/tsc`，
  装在别处时设 `CRD_TSC=<.../typescript/bin/tsc>` 覆盖。

只跑某个 describe：

```bash
CRD_ONLY=commonTimeQueryService node tools/test/run.mjs
```

## 它测什么、不测什么

`run.mjs` 把纯逻辑源码（`domain/src/main`、`feature` 的读模型与规则、`entry/src/test`、
`domain/src/test`）转译成 CommonJS，再用 `node_modules/@ohos/hypium` 里那份**最小 Hypium
兼容实现**（`describe/it/expect/xhsRun` 子集）执行 `List.test.ets` 注册的全部用例。

因此它证明的是：领域计算、答案装配、文案口径、筛选与迁移脚本等**纯逻辑**。

它不覆盖：`@kit.*`、RDB、Preferences、云调用与任何渲染行为。这些文件在拷贝阶段被
跳过并由类型壳替代（见 `run.mjs` 的 `TREES.skip` 与 `STUB_*`），所以新增设备耦合代码时
不需要改测试；反过来，**界面与设备行为必须由 `entry/src/ohosTest` 的真机 Instrument
Test 与 `docs/testing-checklist.md` 的人工检查负责**，不能用这里的绿灯代替。

## 加一个用例

1. 在 `entry/src/test/` 或 `domain/src/test/` 新建 `XxxTest.ets`，默认导出
   `export default function xxxTest() { describe('xxx', () => { it('case', 0, () => {...}); }); }`；
2. 在该目录的 `List.test.ets` 里 import 并调用它；
3. 跑 `node tools/test/run.mjs`。若被测源码依赖设备侧模块，把纯规则下沉到
   `feature/src/main/ets/model/` 这类无依赖位置，而不是给 `run.mjs` 加新桩。
