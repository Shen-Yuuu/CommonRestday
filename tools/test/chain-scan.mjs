/**
 * UI 属性链的扫描机器（批次 AC 造，批次 AD 起两条门禁共用）。
 *
 * 为什么单独一个文件：`press-audit` 的 P1/P2 与 `contrast-audit` 的 C1 问的是同一个问题的两半——
 * "这一行挂在哪个节点上、这个节点的属性链里都有什么"。按压态看的是 `.onClick(` 那一行，
 * 对比度看的是 `.backgroundColor(` 那一行，而"往回找开口、往前吃到语句尾、不许把子节点的属性算进来"
 * 这套深度判定与标记无关。分两处抄写就会各修各的 bug（AC 那轮修的链尾被切掉正是这种），所以合并。
 *
 * 判据靠深度表，不靠形状猜：同一个节点的属性链全落在同一（花括号深度，圆括号深度），
 * 子节点深一层，跨行属性调用的内部圆括号不为 0。
 */
import fs from 'node:fs';
import path from 'node:path';

/** 只扫 UI 侧：属性链是组件的事，纯逻辑层没有可点节点也没有色块。 */
export const UI_TREES = ['entry/src/main/ets'];

/** 节点开口的形状：`Text(...)`／`Row({ space: 8 }) {`／`Column() {`。`this.xxx()` 是 builder 调用，不算。 */
export const NODE = /^([A-Z][A-Za-z0-9]*)\(/;

export function listEts(repo, tree) {
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
export function stripLiterals(text) {
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

export function braceDelta(text) {
  const s = stripLiterals(text);
  return countOf(s, '{') - countOf(s, '}');
}

/** 注释行：链中间夹着解释不能把链打断。也用于把"注释里举例写的 fontColor("挡在审计之外。 */
export function isComment(text) {
  return /^(\/\/|\/\*|\*)/.test(text);
}

/** 每行行首与行尾的（花括号深度，圆括号深度）。 */
export function depthTable(lines) {
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
 * 就会把它读丢；`.gesture(...)`、`.fontColor(...)` 写在后面时同样看不见。
 * 界由"下一行还在目标深度且以 `.` 起头"给出：ArkTS 里没有任何一条新语句以 `.` 开头，
 * 所以同深度的 `.` 行只可能是本条链的续写，碰上 `}`、节点开行或空行就停。
 */
function tailOf(lines, tbl, anchorLine, targetB, targetP) {
  let j = anchorLine;
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
 * 从锚点行（`.onClick(`、`.backgroundColor(` 之类属性调用所在行）交出"只属于这个节点的属性链"，
 * 返回 `{ kind, opener, chainStart, end }`。锚点行本身可以是节点开行或块闭合行。
 *
 * 四种写法都要认，且都不许把子节点的属性算进来（子节点自带圆角不代表这颗芯片是圆的）：
 * - `Text(x).onClick(...)`：开行即节点。
 * - `Column() { … }` 换行后 `.borderRadius(8).onClick(...)`：链在块闭合之后。
 * - 闭合与属性写在同一行的 `}.onClick(() => router.back())`：本行既是链头也是链尾。
 * - 链中间夹着 `.onTouch((e) => { … })` 这类跨行调用：它内部的行更深且圆括号不为 0，跳过不算闭合。
 * 尾巴（锚点之后仍属于同一条语句的行）要算进链：本仓有 `ConfirmDialog` 那样先 `onTouch` 后 `onClick`、
 * 以及 `PaintMonth` 先 `onClick` 后 `gesture` 的写法，只取锚点之前的话会把"已经接了"读成"漏了"。
 * 判不出来返回 null，不猜。
 */
export function chainOf(lines, tbl, anchorLine) {
  const self = lines[anchorLine].trim();
  const base = tbl.starts[anchorLine];
  if (!self.startsWith('.')) {
    const m = self.match(NODE);
    if (m !== null) {
      return { kind: m[1], opener: anchorLine, chainStart: anchorLine,
        end: tailOf(lines, tbl, anchorLine, base.b, base.p) };
    }
    if (self.startsWith('}')) {
      const opener = openerOf(lines, anchorLine);
      if (opener < 0) {
        return null;
      }
      // 本行开头的 `}` 属于上一层，语句结束时深度比 base 浅一格。
      return {
        kind: lines[opener].trim().match(NODE)[1],
        opener: opener,
        chainStart: anchorLine,
        end: tailOf(lines, tbl, anchorLine, base.b - 1, base.p)
      };
    }
    return null;
  }
  const anchorIndent = lines[anchorLine].search(/\S/);
  let close = -1; // 本节点子节点块的闭合行
  let opener = -1;
  let kind = '';
  for (let j = anchorLine - 1; j >= 0; j--) {
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
      if (m !== null && lines[j].search(/\S/) < anchorIndent) {
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
    end: tailOf(lines, tbl, anchorLine, base.b, base.p) };
}

/**
 * 一个节点交三段文本，两条门禁各取所需：
 * - `chain`：只属于本节点的属性链（`chainStart..end`）。
 * - `block`：本节点子节点块里的文本（`opener+1..chainStart-1`）——色块上的文字往往画在这里而不是链上。
 * - `whole`：从开行到语句尾，豁免标记写在这中间任何一行都算。
 */
export function partsOf(lines, found) {
  return {
    chain: lines.slice(found.chainStart, found.end + 1).join('\n'),
    block: lines.slice(found.opener + 1, found.chainStart).join('\n'),
    whole: lines.slice(found.opener, found.end + 1).join('\n')
  };
}

/**
 * 只取**直接子节点**那一层的行号（开行深度 +1、同圆括号深度）。
 * 为什么不用 `partsOf().block`：那份从开行一直收到链头，中间夹着孙辈、曾孙辈的属性。按压那条只看
 * 本节点的链，抄近路没代价；对比度那条要看"压在这块色上的字"，把三层下面的段落算到这块色头上
 * 就会大面积误伤（AD2 首跑一次红了 35 处，绝大多数是别人的孩子）。
 * 要行号而不是文本：红的时候要报出写死前景的那一行。
 */
export function childLines(lines, tbl, found) {
  const depth = tbl.starts[found.opener].b + 1;
  const parens = tbl.starts[found.opener].p;
  const out = [];
  for (let j = found.opener + 1; j < found.chainStart; j++) {
    const text = lines[j].trim();
    if (!text || isComment(text)) {
      continue;
    }
    if (tbl.starts[j].b === depth && tbl.starts[j].p === parens) {
      out.push(j);
    }
  }
  return out;
}

/** `childLines` 的文本形式。 */
export function blockOf(lines, tbl, found) {
  return childLines(lines, tbl, found).map((j) => lines[j].trim()).join('\n');
}
