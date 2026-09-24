/**
 * 读屏挂点的离线静态审计（差异文档 D-29 的防回潮判据）。
 *
 * 为什么需要一条断言而不是一次人工修：`accessibilityLevel('no')` 摘掉的只是**它挂着的那个节点**，
 * 子节点各自成节点。所以把它写在 `Column`/`Row` 上，管不到里面的 `Text`——而这类挂点旁边往往
 * 就着一句"这列不朗读"的注释，注释与实况相反却看不出来（批次 D 就是在改 D-16 时从反方向撞见的：
 * 把 `no` 从容器挪到那枚 `Text` 自身，整句立刻从 dumpLayout 里消失）。人工修完这一批，下一批新页面
 * 还会照抄容器写法，所以把它做成门禁。
 *
 * 规则只有一条，且只在能静态判定的范围内报：**带 `{}` 子块的节点上挂 `no`，而子块里存在
 * Text / SymbolGlyph / Image 这类自带朗读内容的节点 → 违规**（那个 `no` 是无效的）。
 * 不报的情形：
 * - 挂在叶子节点上（`Text('›')`、`SymbolGlyph(...)`、`Circle()`）——这是正确写法；
 * - 挂在没有文字子节点的空容器上（装饰条、网格线）——现在不生效也不误导，加了字就会被上面那条逮住；
 * - 子块里只调用了别的 `@Builder` / 自定义组件——静态看不见里面有没有字，不猜。
 *
 * 违反即由 `tools/test/run.mjs` 判 `a11y: FAILED` 并非零退出，不参与"绿"的定义就不算检查。
 */
import fs from 'node:fs';
import path from 'node:path';

/** 随包源码面：与 copy-audit 的 CLAIM_TREES 同一批目录，只有这些会进包给用户读。 */
const TREES = ['entry/src/main', 'feature/src/main', 'data/src/main', 'cloud/src/main',
  'commons/src/main', 'domain/src/main'];
/** 自带朗读内容的节点：出现在子块里就意味着容器上的 `no` 盖不住。 */
const SPOKEN = new Set(['Text', 'SymbolGlyph', 'Image', 'Span', 'RichText']);
/** 挂在容器上不生效的那个属性值。 */
const SILENT = "accessibilityLevel('no')";
/** 一行里真正的组件调用只认行首：属性链里的 `this.gridH()`、`.fontColor(...)` 都不算。 */
const HEAD_CALL = /^([A-Z][A-Za-z0-9_]*)\s*\(/;

function listEts(repo, relDir) {
  const abs = path.join(repo, relDir);
  if (!fs.existsSync(abs)) {
    return [];
  }
  const out = [];
  for (const ent of fs.readdirSync(abs, { withFileTypes: true })) {
    const childRel = path.posix.join(relDir, ent.name);
    if (ent.isDirectory()) {
      out.push(...listEts(repo, childRel));
    } else if (ent.name.endsWith('.ets')) {
      out.push(childRel);
    }
  }
  return out;
}

/**
 * 逐行扫一遍组件树：任何以 `{` 收尾的行都压栈（组件行带名字，`if`/`else`/箭头函数体压匿名帧），
 * 行首的 `}` 出栈并把"里面有没有可朗读节点"往上传。遇到 `.accessibilityLevel('no')` 就判给
 * "当前主语"——刚出栈的那个组件，或上一行的叶子组件。
 *
 * 两个容易踩的点，都是这份代码存在的理由：
 * - `if (cond) {` 的 `}` 必须自己消化，否则会把外层的 `Column` 提前弹掉，后面整棵树的归属全错；
 * - 组件只认**行首**的 `Name(`，因为属性链里 `Column().height(this.gridH())` 的 `H(` 也是大写加左括号。
 */
function scan(rel, src, violations) {
  const lines = src.split(/\r?\n/);
  const stack = [];
  let subject = null;
  let inBlockComment = false;
  for (let i = 0; i < lines.length; i += 1) {
    const raw = lines[i];
    if (inBlockComment) {
      const end = raw.indexOf('*/');
      if (end < 0) {
        continue;
      }
      inBlockComment = false;
    }
    const at = stripComment(raw);
    if (at.blockOpen) {
      inBlockComment = true;
    }
    const s = at.text.trim();
    if (s === '') {
      continue;
    }
    let body = s;
    while (body.startsWith('}')) {
      const frame = stack.pop();
      if (frame !== undefined) {
        subject = frame.name === null ? null : frame;
        if (stack.length > 0 && frame.spoken) {
          stack[stack.length - 1].spoken = true;
        }
      }
      body = body.slice(1).trim();
    }
    if (body === '') {
      continue;
    }
    const m = HEAD_CALL.exec(body);
    const name = m === null ? null : m[1];
    if (body.endsWith('{')) {
      stack.push({ name: name, line: i + 1, block: true, spoken: false });
      if (name !== null) {
        subject = null; // 往后挂的属性属于这个新开的子节点，不再属于上一个
      }
      continue;
    }
    if (name !== null && !body.startsWith('.')) {
      subject = { name: name, line: i + 1, block: false, spoken: SPOKEN.has(name) };
      if (stack.length > 0 && subject.spoken) {
        stack[stack.length - 1].spoken = true;
      }
    }
    if (body.indexOf(SILENT) >= 0 && subject !== null && subject.block && subject.spoken) {
      violations.push(rel + ':' + subject.line + ' 的 `' + subject.name + '()` 带子块且子块里有可朗读节点，'
        + '挂在它上面的 ' + SILENT + ' 管不到子节点（D-29：把 no 落到那枚 Text 自己身上）');
    }
  }
}

/**
 * 去掉行尾的 `//` 注释（引号内的 `//` 不算，URL 也写在字符串里），并报告本行是否停在未闭合的
 * `/* …` 块注释里。只用于让"行尾是不是 `{`"这个判断站得住。
 */
function stripComment(line) {
  let out = '';
  let quote = '';
  for (let i = 0; i < line.length; i += 1) {
    const c = line[i];
    if (quote !== '') {
      out += c;
      if (c === quote) {
        quote = '';
      } else if (c === '\\') {
        i += 1;
        out += line[i] === undefined ? '' : line[i];
      }
      continue;
    }
    if (c === '"' || c === "'" || c === '`') {
      quote = c;
      out += c;
      continue;
    }
    if (c === '/' && line[i + 1] === '/') {
      break;
    }
    if (c === '/' && line[i + 1] === '*') {
      return { text: out, blockOpen: line.indexOf('*/', i + 2) < 0 };
    }
    out += c;
  }
  return { text: out, blockOpen: false };
}

/** @returns 违规说明清单，空数组即通过。 */
export function auditAccessibility(repo) {
  const violations = [];
  for (const tree of TREES) {
    for (const rel of listEts(repo, tree)) {
      scan(rel, fs.readFileSync(path.join(repo, rel), 'utf8'), violations);
    }
  }
  return violations;
}
