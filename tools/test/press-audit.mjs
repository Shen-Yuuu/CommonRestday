/**
 * 自制芯片按压回弹的离线静态审计（差异文档 D-53 的防回潮判据，批次 AC）。
 *
 * 为什么这算一条检查而不是"顺手美化"：原型 02 给圆角控件写死了按下那一格——
 * `.chip:active,.btn:active{transform:scale(.98)}`（第 279 行）与 `.chip:active{transform:scale(.94)}`
 * （第 454 行）。系统 `Button` 有内置按压态（`stateEffect` 默认 true，见 Button.md 参数表），
 * 所以按钮那一族本来就兑现了；**没兑现的是自制节点那一族**：用 `Text`／`Row`／`Column`／`Stack`
 * 画的芯片、胶囊、格子，按下去什么都不动——同一屏里按钮变暗、芯片不动，用户分不清哪个还能点。
 * 已有四件自制节点组件（`EditorialCard`／`QuickAnswerRow`／`ConflictNotice`／`AppNavigator`）自绘了
 * 按压态（`onTouch` 配 `scale`/`jelly`），它们是这条规矩的出处；其余站点漏了，漏的原因是**没人拦住**，
 * 所以这里拦。`ConfirmDialog`／`StatePanel` 的按钮也自绘了果冻态，但那两颗挂在系统 `Button` 上，
 * 不归这条管。
 *
 * 规则两条：
 * - P1：**非 Button 的可点节点，属性链里出现 `borderRadius(`（自制圆角控件）就必须同链有按压态**——
 *   `clickEffect(` 或 `onTouch(`。确实不该加的（比如带涂抹手势的格子）写一行 `// press-exempt 理由`，
 *   理由要能被人复核；不写理由就红。
 * - P2：**加了 `clickEffect(` 的那条链不许同时挂手势**。SDK 的说明原文是
 *   "After the click feedback effect triggers scaling, the touch point may fall outside the control, making the
 *   component unresponsive to gesture events"（本机 SDK `component/common.d.ts:20566`）——
 *   两者同挂就是"滑动偶尔不认"，这类问题在设备上一眼看不出来，所以由门禁拦住而不靠人记。
 *
 * 判不了的情形（不猜，也不冒充覆盖）：
 * - **按压好不好用**只有设备上能判：这条只看"有没有接"，不看幅度、时长、是否跟手。
 * - 圆角不是芯片的唯一形状：方角的可点行（计划卡整行、设置项行）这一族它看不见——
 *   要不要给它们加反馈是外观裁定，归原型不归门禁。
 * - `@Builder` 调用点（`this.rowChip(...)`）不收属性链，本来也加不了 clickEffect，跳过；
 *   认不出开口的写法一律算判不了。宁漏不误伤，新页面的圆角芯片要人复核一次。
 *
 * "这一行挂在哪个节点上、这条链里有什么"的机器在 `chain-scan.mjs`，与 `contrast-audit.mjs` 共用（§8.15）。
 */
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { UI_TREES, chainOf, depthTable, listEts, partsOf } from './chain-scan.mjs';

/** 豁免标记：写在这一条链的任意一行上都算，理由跟在同一行后面。 */
const EXEMPT_MARK = 'press-exempt';
const PRESS = /clickEffect\(|onTouch\(/;
const GESTURE = /\.gesture\(|PanGesture|SwipeGesture|LongPressGesture|PinchGesture/;

/**
 * 扫描 UI 侧，返回 `{ violations, wired, exempt, skipped }`。
 * `wired`／`exempt` 是给门禁看的水位：接了几处、写明理由豁免了几处。
 * `skipped` 是"这条规则看不见多少颗 `.onClick`"（判不出开口 + 系统 Button），只在自查清单里打，
 * 免得下一个人把 wired 当成全仓覆盖数。
 */
export function auditPress(repo) {
  const violations = [];
  let wired = 0;
  let exempt = 0;
  let skipped = 0;
  for (const rel of UI_TREES.flatMap((t) => listEts(repo, t))) {
    const lines = fs.readFileSync(path.join(repo, rel), 'utf8').split(/\r?\n/);
    const tbl = depthTable(lines);
    for (let i = 0; i < lines.length; i++) {
      if (!lines[i].includes('.onClick(')) {
        continue;
      }
      const found = chainOf(lines, tbl, i);
      if (found === null || found.kind === 'Button') {
        skipped++;
        continue; // 判不了的、以及系统按钮（自带按压态）都不归这条管
      }
      const parts = partsOf(lines, found);
      if (parts.whole.includes(EXEMPT_MARK)) {
        exempt++;
        continue;
      }
      if (PRESS.test(parts.chain)) {
        wired++;
      } else if (/borderRadius\(/.test(parts.chain)) {
        violations.push(rel + ':' + (i + 1) + '：自制圆角可点节点（' + found.kind
          + '）没有按压回弹——原型 .chip:active 写的是 scale(.94)，这一族按下去不动');
      }
      if (/clickEffect\(/.test(parts.chain) && GESTURE.test(parts.chain)) {
        violations.push(rel + ':' + (i + 1) + '：同一条链既加 clickEffect 又挂手势——回弹缩放后触摸点可能落在控件之外，'
          + '手势事件收不到（SDK 对 clickEffect 的原文警告）');
      }
    }
  }
  return { violations: violations, wired: wired, exempt: exempt, skipped: skipped };
}

// 直接跑这个文件时打一份清单，供批次盘点与人工核对用。
const self = path.resolve(fileURLToPath(import.meta.url));
if (process.argv[1] && path.resolve(process.argv[1]) === self) {
  const repo = path.resolve(path.dirname(self), '..', '..');
  const r = auditPress(repo);
  console.log('已接按压态 ' + r.wired + ' 处，写明理由豁免 ' + r.exempt + ' 处，待补 ' + r.violations.length
    + ' 处，这条规则看不见 ' + r.skipped + ' 处（判不出开口 + 系统 Button）');
  for (const v of r.violations) {
    console.log('  ' + v);
  }
}
