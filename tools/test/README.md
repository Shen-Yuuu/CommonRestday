# 离线单测入口（tools/test）

仓库内一条命令复现纯逻辑单测，不需要真机、不需要模拟器、不需要联网。

```bash
node tools/test/run.mjs
```

从仓库根目录执行。退出码：

| 码 | 含义 |
|---|---|
| 0 | 类型编译 0 error **且**全部用例通过 **且**三条离线口径审计（文案 / 读屏挂点 / 读数落地与提交闩）都通过 |
| 1 | 有失败用例，或离线口径审计报出冲突（明细见输出与日志） |
| 2 | 环境不满足（找不到 TypeScript 编译器） |
| 3 | 类型编译未通过：不产出 JS、**不启动用例** |

输出末尾给出日志路径：`tools/test/out/last-run.log`（`copy:` + `a11y:` + `landing:` + `typecheck: N errors` +
每个用例 PASS/FAIL + 汇总计数 + `tests: passed/FAILED`）。

**"全绿"的唯一口径是 `copy: PASS` + `a11y: PASS` + `landing: PASS` + `typecheck: 0 errors` + `tests: passed` + 退出码 0。**
`tsconfig.json` 用 `noEmitOnError: true`，转译有类型错误时既没有产物也没有绿灯——曾经
`noEmitOnError: false` 让 5 个类型错误照样跑出 "177 passed, exit 0"，那种数字不能写进任何验收文档。

## 文案口径审计（`copy-audit.mjs`）

《隐私政策》的全文同时存在于三处（应用内 `string.json` 的 `pp_*`、`docs/legal/privacy-policy.md`、
`privacy-policy.html`，渲染顺序另由 `PrivacyPolicySheet.ets` / `PrivacyDialog.ets` 决定），首启摘要另有两处。
这几份文字一旦各说各话，用户在一个地方读到的承诺在另一个地方就不成立——最终验收 R1 报的就是这一类问题，
所以这里用纯 Node 逐字比对，而不是在文件头写一句"请两边同批改"然后指望人记得。

禁令同时覆盖**所有随包源码**（`entry/feature/data/cloud/commons/domain` 的 `src/main`）：政策改口了，
界面上那句"数据只存在这台手机"的口号还留在原地，用户读到的仍是同一句假话。`docs/` 不参与这一项检查，
因为验收记录要**引用**旧措辞，那是记录不是承诺。

审计的六条规则见 `copy-audit.mjs` 文件头。它不需要 `tsc`，也不参与转译，
所以资源文件与文档都能被钉住；违反任何一条即退出码 1。

## 读屏挂点审计（`a11y-audit.mjs`）

`accessibilityLevel('no')` 摘掉的只是**它挂着的那个节点**：写在 `Column`/`Row` 上，里面的 `Text`
各自成节点、照样朗读。差异文档 D-29 数出来的 3 处失效挂点旁边都配着一句"这列不朗读"的注释，
注释与实况相反却看不出来，所以做成门禁而不是修完就算：规则只有一条——**带 `{}` 子块的节点上挂
`no`，而子块里出现 `Text`/`SymbolGlyph`/`Image`/`Span`/`RichText` 即违规**。挂在叶子节点上
（正确写法）、挂在没有文字子节点的容器上（装饰条、网格线）、子块里只调用别的 `@Builder`
（静态看不见里面有没有字）都不报。扫描面与 `copy-audit` 的 `CLAIM_TREES` 同一批目录。

## 并发落地与提交重入审计（`landing-audit.mjs`）

一次读数从发起到写 `@State` 之间隔着 `await`，而 RDB 与云读数的**返回顺序没有保证**。读数的触发点
从来不止一个（重算广播、下拉刷新、父页 `@Prop` 变化、翻页/切侧点击、写操作本地收尾），两次读数
必然重叠；先起的那次晚落地就把界面按回旧结果，而表头/选中档/侧别这些**同步**改掉的部分已经是新的
——数据和它的说明分家。旧读数抛错时更坏：`failed = true` 会盖掉新读数的成功，把好数据念成"没读到"。
差异文档 D-51 修的是这一类，机制与批次 Z 的"节点不重绘"不同，症状同为"改了不跟着变"。
D-52 是同一个文件里的第四条规则，管的是写入那一侧。

规则四条，R1–R3 管读数落地：**订阅 `recomputeCount` 的文件必须带 `LatestLanding` 闸门**（不进闸门表
就要进 `EXEMPT` 并写出"这条读数的数据写入点全程同步"的理由）；**按文件计 `begin()` 次数不得多于
`isCurrent(` 次数**（防"复制了闸门字段却漏掉检查"）；**挂在 `@Prop` 上的 `@Watch` 若会跨 await 重读
（含一层被调方法），该文件必须带闸门**——前一条只管广播订阅者，这一条管"父页改参数"那半边，豁免同样
要写"这条序列为什么走不通"。R4 管提交重入：**函数体里同时出现 `generateRandomUUID(`、写命令调用
（`ScheduleCommandService.save/import/paint/set/clear/remove*`、`PlanUseCase.createPlan`）与跨 await，
首行就必须有忙碌闩**（`if (this.<flag>)` 早退且体内看得见 `this.<flag> = true`）。理由是 repo 层全是
`INSERT OR REPLACE`，幂等只在**同主键**上成立——id 每次点击现生成，连点两下就是两行。
豁免表 `EXEMPT_SUBMIT` 的键是 `文件#方法`，理由要写清"那行生成主键的代码为什么走不到"（R4 只看函数体
形状，判不出分支可达性）；三张表都校验文件与方法仍然存在。扫描面只有 `entry/src/main/ets`——闸门管的
是组件状态落地顺序与按钮重入，纯逻辑层没有 `@State`。
R4 的判据是"每次点击现生成主键"，所以它**看不见固定主键但写入非事务的那一族**：
`CycleEditor.save` 的 id 恒为 `'main'`，而 `ScheduleRepo.saveTemplate` 是先 delete 再 insert 两条独立
SQL，两次点击排成 delete→delete→insert→insert，后一次 insert 撞刚建好的那一行、命令层回 `WRITE_FAILED`
（已经落库的保存被念成"保存失败"）。这一格靠人工盘点补（批次 AB），要判它得能看见 repo 的 SQL 形状，
而 R4 的扫描面只有 UI 侧。

## 按压回弹审计（`press-audit.mjs`）

原型 02 把按下那一格写死了：`:279 .chip:active,.btn:active{scale(.98)}`、`:454 .chip:active{scale(.94)}`、
`:521 .tabbar .t:active{scale(.92)}`。系统 `Button` 自带 `stateEffect`（默认 true）已经兑现，
漏的是 `Text`／`Row`／`Column`／`Stack` 自绘的芯片、胶囊、格子——它们接了 `.onClick` 却按下去一动不动（D-53）。
修法用系统的 `.clickEffect()`，不用 `stateStyles`：后者只覆盖通用属性里少数几项，且**在 `@Builder` 内不生效**
（官方原话"因Builder不具备独立的自定义父节点"），而本仓多数芯片正画在 builder 里。
幅度两档都取现成规格：芯片 0.94 ← 原型 `:454`，按钮／整行／整卡 0.98 ← 原型 `:279` 与本仓 `pressScale` 同档。

规则两条：**P1** 非 `Button` 的可点节点，属性链里有 `borderRadius(` 就必须同链有 `clickEffect(`／`onTouch(`，
否则要在节点上写一行 `// press-exempt 理由`（`PaintMonth` 的涂抹格就是这么豁免的——它下面挂着 `PanGesture`）。
**P2** 同一条链不许既 `clickEffect` 又挂手势：SDK 原文警告回弹缩放后触摸点可能落到控件之外，手势事件收不到。

三条看不见，别把水位当成全仓覆盖数：
① 按压好不好用只有设备能判，静态只查"接没接"；
② **方角**可点行不在 P1 的触发条件里（判据是圆角，方角按下去不动本来就不是这一族的设计意图）；
③ `this.rowChip(...)` 这类 builder 调用不收属性链，所以规则只看直接写在页面里的节点。
退出码口径行 `press:` 与 `copy:`／`a11y:`／`landing:` 同排，`skipped`（系统 `Button` 数）只在
`node tools/test/press-audit.mjs` 自查清单里打。

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

写命令的编排可以测：`ScheduleCommandService` 的仓储与 `ScheduleUseCase` 依赖都是类型壳，
`boot.cjs` 另给了一个 `AppStorage` 运行时替身，`run.mjs` 生成的 `src/globals.d.ts` 补上它的编译期签名
（只有真用到的 `get<T>/setOrCreate<T>`），因此用例用与设备同名的 `recomputeCount` 键断言
"一次保存恰好一次重算、空批次不重算"，不引入任何测试专用字段。

## 加一个用例

1. 在 `entry/src/test/` 或 `domain/src/test/` 新建 `XxxTest.ets`，默认导出
   `export default function xxxTest() { describe('xxx', () => { it('case', 0, async () => {...}); }); }`；
   用例可以是 `async`：`xhsRun` 会串行 await 到底再判定（断言在汇总之后才抛会退化成假绿灯）；
2. 在该目录的 `List.test.ets` 里 import 并调用它；
3. 跑 `node tools/test/run.mjs`。若被测源码依赖设备侧模块，把纯规则下沉到
   `feature/src/main/ets/model/` 这类无依赖位置，而不是给 `run.mjs` 加新桩。
