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
 */
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

/** 只扫 UI 侧：按压态是组件的事，纯逻辑层没有可点节点。 */
const TREES = ['entry/src/main/ets'];
/** 节点开口的形状：`Text(...)`／`Row({ space: 8 }) {`／`Column() {`。`this.xxx()` 是 builder 调用，不算。 */
const NODE = /^([A-Z][A-Za-z0-9]*)\(/;
/** 豁免标记：写在这一条链的任意一行上都算，理由跟在同一行后面。 */
const EXEMPT_MARK = 'press-exempt';
const PRESS = /clickEffect\(|onTouch\(/;
const GESTURE = /\.gesture\(|PanGesture|SwipeGesture|LongPressGesture|PinchGesture/;

function listEts(repo, tree) {
  const out = [];
  const dir = path.join(repo, tree);
  if (!fs.existsSync(dir)) {
    return out;
  }
  const walk = (d) => {
    for (const e of fs.readdirSync(d, { withFileTypes: true })) {
      const p = path.join(d, e.name);
      if (e.isDirectory()) {
        walk(p);
      } else if (e.name.endsWith('.ets')) {
        out.push(path.relative(repo, p).replace(/\\/g, '/'));
      }
    }
  };
  walk(dir);
  return out.sort();
}

/** 字符串/模板串与行注释换成空串：`Text('}')` 不该被数成一个闭合花括号。 */
function stripLiterals(text) {
  return text.replace(/(["'`])(?:\\.|(?!\1)[^\\])*\1/g, '""').replace(/\/\/.*$/, '');
}

function countOf(text, ch) {
  let n = 0;
  for (const c of text) {
    if (c === ch) {
      n++;
    }
  }
  return n;
}

function braceDelta(text) {
  const s = stripLiterals(text);
  return countOf(s, '{') - countOf(s, '}');
}

/** 注释行：链中间夹着解释不能把链打断。 */
function isComment(text) {
  return /^(\/\/|\/\*|\*)/.test(text);
}

/**
 * 每行行首与行尾的（花括号深度，圆括号深度）。
 * 有了这张表，"这一行挂在谁身上"就靠深度判而不是靠形状猜：同一个节点的属性链全落在同一深度，
 * 子节点深一层，跨行属性调用的内部圆括号不为 0。
 */
function depthTable(lines) {
  const starts = [];
  const ends = [];
  let b = 0;
  let p = 0;
  for (const raw of lines) {
    starts.push({ b: b, p: p });
    const s = stripLiterals(raw);
    b += countOf(s, '{') - countOf(s, '}');
    p += countOf(s, '(') - countOf(s, ')');
    if (b < 0) {
      b = 0;
    }
    if (p < 0) {
      p = 0;
    }
    ends.push({ b: b, p: p });
  }
  return { starts: starts, ends: ends };
}

/**
 * 本条语句的最后一行。一条链可以一直往下同深度续 `.属性(...)`，所以"回到目标深度的那一行"
 * 只是本段调用的结尾，不是整条语句的结尾。
 * 为什么要走到语句结尾：`clickEffect` 按原型顺序写在 `onClick` **之后**，停在第一个回深的行
 * 就会把它读丢；`.gesture(...)` 写在后面时 P2 也看不见。
 * 界由"下一行还在目标深度且以 `.` 起头"给出：ArkTS 里没有任何一条新语句以 `.` 开头，
 * 所以同深度的 `.` 行只可能是本条链的续写，碰上 `}`、节点开行或空行就停。
 */
function tailOf(lines, tbl, clickLine, targetB, targetP) {
  let j = clickLine;
  for (;;) {
    while (j < tbl.ends.length && !(tbl.ends[j].b === targetB && tbl.ends[j].p === targetP)) {
      j++;
    }
    if (j >= tbl.ends.length) {
      return tbl.ends.length - 1; // 深度一直没回到目标（括号不配对）：收到文件尾，不越界
    }
    let k = j + 1;
    while (k < lines.length && (!lines[k].trim() || isComment(lines[k].trim()))) {
      k++;
    }
    if (k >= lines.length) {
      return j;
    }
    const d = tbl.starts[k];
    if (d.b === targetB && d.p === targetP && lines[k].trim().startsWith('.')) {
      j = k; // 同深度的下一条属性调用：语句还没写完
      continue;
    }
    return j;
  }
}

/** 从块闭合行往上找该块的开口；认不出节点名（`this.rowChip(...)` 这类）返回 -1。 */
function openerOf(lines, closeLine) {
  let sum = 0;
  for (let k = closeLine; k >= 0; k--) {
    sum += braceDelta(lines[k].trim());
    if (sum === 0) {
      return lines[k].trim().match(NODE) === null ? -1 : k;
    }
  }
  return -1;
}

/**
 * 从 `.onClick(` 那一行交出"只属于这个节点的属性链"，返回 `{ kind, opener, chainStart, end }`。
 *
 * 四种写法都要认，且都不许把子节点的属性算进来（子节点自带圆角不代表这颗芯片是圆的）：
 * - `Text(x).onClick(...)`：开行即节点。
 * - `Column() { … }` 换行后 `.borderRadius(8).onClick(...)`：链在块闭合之后。
 * - 闭合与属性写在同一行的 `}.onClick(() => router.back())`：本行既是链头也是链尾。
 * - 链中间夹着 `.onTouch((e) => { … })` 这类跨行调用：它内部的行更深且圆括号不为 0，跳过不算闭合。
 * 尾巴（`onClick` 之后仍属于同一条语句的行）要算进链：本仓有 `ConfirmDialog` 那样
 * 先 `onTouch` 后 `onClick`、以及 `PaintMonth` 先 `onClick` 后 `gesture` 的写法，
 * 只取 `onClick` 之前的话会把"已经接了"读成"漏了"，P2 也看不见后面挂的手势。
 * 判不出来返回 null，不猜。
 */
function chainOf(lines, tbl, clickLine) {
  const self = lines[clickLine].trim();
  const base = tbl.starts[clickLine];
  if (!self.startsWith('.')) {
    const m = self.match(NODE);
    if (m !== null) {
      return { kind: m[1], opener: clickLine, chainStart: clickLine,
        end: tailOf(lines, tbl, clickLine, base.b, base.p) };
    }
    if (self.startsWith('}')) {
      const opener = openerOf(lines, clickLine);
      if (opener < 0) {
        return null;
      }
      // 本行开头的 `}` 属于上一层，语句结束时深度比 base 浅一格。
      return {
        kind: lines[opener].trim().match(NODE)[1],
        opener: opener,
        chainStart: clickLine,
        end: tailOf(lines, tbl, clickLine, base.b - 1, base.p)
      };
    }
    return null;
  }
  const clickIndent = lines[clickLine].search(/\S/);
  let close = -1; // 本节点子节点块的闭合行
  let opener = -1;
  let kind = '';
  for (let j = clickLine - 1; j >= 0; j--) {
    const d = tbl.starts[j];
    const text = lines[j].trim();
    if (!text || isComment(text)) {
      continue;
    }
    if (d.b === base.b && d.p === base.p) {
      if (text.startsWith('.')) {
        continue; // 同一条链上的兄弟属性
      }
      const m = text.match(NODE);
      if (m !== null && lines[j].search(/\S/) < clickIndent) {
        opener = j; // 节点开行后直接跟更深缩进的属性链
        kind = m[1];
        close = j + 1;
        break;
      }
      return null; // 同层的另一条语句：这条链没有根
    }
    if (d.b === base.b + 1 && d.p === base.p && text.startsWith('}')) {
      close = j; // 子节点块闭合
      break;
    }
    if (d.b > base.b || d.p !== base.p) {
      continue; // 跨行属性调用的内部
    }
    return null;
  }
  if (close < 0) {
    return null;
  }
  if (opener < 0) {
    opener = openerOf(lines, close);
    if (opener >= 0) {
      kind = lines[opener].trim().match(NODE)[1];
    }
  }
  if (opener < 0) {
    return null;
  }
  return { kind: kind, opener: opener, chainStart: close,
    end: tailOf(lines, tbl, clickLine, base.b, base.p) };
}

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
  for (const rel of TREES.flatMap((t) => listEts(repo, t))) {
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
      const chain = lines.slice(found.chainStart, found.end + 1).join('\n');
      const whole = lines.slice(found.opener, found.end + 1).join('\n');
      if (whole.includes(EXEMPT_MARK)) {
        exempt++;
        continue;
      }
      if (PRESS.test(chain)) {
        wired++;
      } else if (/borderRadius\(/.test(chain)) {
        violations.push(rel + ':' + (i + 1) + '：自制圆角可点节点（' + found.kind
          + '）没有按压回弹——原型 .chip:active 写的是 scale(.94)，这一族按下去不动');
      }
      if (/clickEffect\(/.test(chain) && GESTURE.test(chain)) {
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
