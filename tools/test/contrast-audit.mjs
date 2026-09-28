/**
 * 色块前景对比度的离线静态审计（差异文档 D-54 的防回潮判据，批次 AD）。
 *
 * 要拦住的事实：班次的底色是用户拿取色器随便挑的（`HdsColorPicker` 的 GRID/SPECTRUM/SLIDERS 三档，
 * 回调直接给十六进制串），而画它的那几处原先把前景写死成暖白——浅色档下白字压在近白底色上实测
 * 1.2–1.8:1，等于看不见。批次 AD1 把九处站点换成 `DesignTokens.foregroundOn(...)`（判据在
 * `commons` 的 `SwatchInk`，数学式由 `SwatchInkTest` 逐色钉住），这一条负责让"再写死一处"过不了门禁。
 *
 * 规则两条：
 * - C1：**底色是"用户自选色形状"的节点，它自己这条链和直接子节点里的前景必须由底色决定**——
 *   写 `DesignTokens.foregroundOn(同一个底色)`。确实该写死的（比如底色其实是令牌的三元）写一行
 *   `// contrast-exempt 理由`，理由要能被人复核；不写理由就红。
 *   写死的两种形态都算：暖白那一族（`'#FFFFFF'`／`Color.White`／`DesignTokens.heroText`），
 *   以及会随深浅色翻面的文字令牌（`app.color.text_*`／`DesignTokens.textPrimary` 那一族）——
 *   后者是同一件事的另一半：深色档里 `text_secondary` 是浅紫，压在同一块浅灰休息色上实测 1.11:1，
 *   **底色不随模式翻面，前景就不许翻**。
 * - C2：`app.color.swatch_fg` 在 base 与 dark 两套 color.json 里必须都等于 `SwatchInk.inkHex()`，
 *   `app.color.hero_fg` 必须等于 `warmWhiteHex()`，且 `swatch_fg` 两档同值。这条的全部意义就是
 *   "两档同值"；而 `SwatchInk` 里的两个常量与资源里的字面量是抄写的两份，改一处忘另一处由这里拦。
 *
 * 判不了的情形（不猜，也不冒充覆盖）：
 * - 底色只认两条形状：对象上的 `.color` 属性，和配色助手 `typeColor(`／`colorOf(` 等。**换个别的名
 *   把用户色传进 `backgroundColor` 就看不见**——所以清单会打出"底色取自助手/令牌"的站点数，
 *   加新助手的人能看到自己有没有绕开这条（`DayShiftSheet.chipBg` 就是现存的一处）。
 * - 前景是方法或变量（`this.ink()`）时看不见取值：算判不了，必须在该节点写 `contrast-exempt`，
 *   红得有道理——审的人看得见方法名，能顺着去看方法体。
 * - 没有任何文字的色块（粒子、图例点、进度条段）不归这条管，计入"链上和直接子节点都没有文字"。
 * - `@Builder` 调用点不收属性链；认不出开口的写法一律算判不了，计入 skipped。
 * - 桌面卡片（`widget/RestCard2x2.ets`）那五处 `'#FFFFFF'` 归卡片自己的固定渐变底管，这条不判。
 * - **真浅真深要设备上判**：这条只看"前景有没有跟着底色走"，看得清不清还得人眼过一遍。
 *
 * "这一行挂在哪个节点上、这条链和它的直接子节点里有什么"的机器在 `chain-scan.mjs`，
 * 与 `press-audit.mjs` 共用（§8.15）。
 */
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { UI_TREES, chainOf, childLines, depthTable, isComment, listEts, partsOf } from './chain-scan.mjs';

const EXEMPT_MARK = 'contrast-exempt';
/** 用户自选底色到达节点的两条形状：对象上的 `.color`，和班次配色助手。 */
const USER_BG = /\b[A-Za-z_]\w*(?:\.\w+)*\.color\b|\b(?:typeColor|colorOf|shiftColor|brushColor|swatchColor)\s*\(/;
/** 跟着底色走的唯一写法。 */
const FOLLOWS = /foregroundOn\(/;
/** 写死的暖白前景三形——D-54 出事的就是它们。 */
const WARM_WHITE_FG = /fontColor\(\s*'#(?:[Ff]{3,8}|[Ff]{2}[Ee][0-9A-Fa-f]{3})|fontColor\(\s*Color\.White|fontColor\(\s*DesignTokens\.heroText\b/;
/** 会随深浅色翻面的文字令牌：压在固定底色上同样不许写死。 */
const FLIPPING_FG = /fontColor\(\s*\$r\('app\.color\.text_|fontColor\(\s*DesignTokens\.(?:textPrimary|textSecondary|textHint|textTertiary|textWeak|textOnWeak)\b/;
/** 裸十六进制前景（不是暖白那一族也算写死）。 */
const HEX_FG = /fontColor\(\s*['"]#/;
/** 底色像"从助手取的"而不是直接给色值：不判，只数给覆盖边界。 */
const CALL = /[A-Za-z_]\w*(?:\.\w+)*\s*\(/;

const COLOR_JSON = {
  base: 'entry/src/main/resources/base/element/color.json',
  dark: 'entry/src/main/resources/dark/element/color.json'
};
const SWATCH_INK = 'commons/src/main/ets/util/SwatchInk.ets';

/**
 * 把字符串/模板串与注释换成空格，**长度不变**：实参要从原文按索引切出来（`$r('app.color.x')` 里的
 * 引号内容得留着看），而找闭合括号时又不能把 `'{'` 数成一个花括号。
 */
function blankKeep(src) {
  const a = src.split('');
  let quote = null;
  for (let i = 0; i < a.length; i++) {
    const c = a[i];
    if (quote !== null) {
      if (c === '\\') {
        a[i + 1] = ' ';
        i++;
      } else if (c === quote) {
        quote = null;
      } else {
        a[i] = ' ';
      }
      continue;
    }
    if (c === '"' || c === "'" || c === '`') {
      quote = c;
      continue;
    }
    if (c === '/' && a[i + 1] === '/') {
      let j = i;
      while (j < a.length && a[j] !== '\n') {
        a[j] = ' ';
        j++;
      }
      i = j;
      continue;
    }
    if (c === '/' && a[i + 1] === '*') {
      let j = i;
      while (j + 1 < a.length && !(a[j] === '*' && a[j + 1] === '/')) {
        if (a[j] !== '\n') {
          a[j] = ' ';
        }
        j++;
      }
      a[j] = ' ';
      if (j + 1 < a.length) {
        a[j + 1] = ' ';
      }
      i = j + 1;
    }
  }
  return a.join('');
}

/**
 * 实参里"设计令牌"的写法先抹掉，剩下的才是可能跟着用户走的表达式。
 * 不抹就会把 `$r('app.color.text_secondary')` 读成"对象上的 .color"——AD2 首跑红的那一大片就是这么来的。
 */
function nonTokenArg(arg) {
  return blankKeep(arg)
    .replace(/\$[a-z]\w*\s*\([^)]*\)/g, ' ')
    .replace(/DesignTokens\.\w+/g, ' ')
    .replace(/\bColor\.\w+/g, ' ');
}

/** 空白化文本里 `n` 之下的行号（0 基）。一处 `.backgroundColor(` 找一次，量小到不必建表。 */
function lineAt(blank, n) {
  let line = 0;
  for (let i = 0; i < n; i++) {
    if (blank[i] === '\n') {
      line++;
    }
  }
  return line;
}

/** 取出 `.backgroundColor(` 的实参原文（跨行也收，靠圆括号配对）；配不上返回 null。 */
function argOf(raw, blank, open) {
  let depth = 1;
  for (let i = open + 1; i < blank.length; i++) {
    if (blank[i] === '(') {
      depth++;
    } else if (blank[i] === ')') {
      depth--;
      if (depth === 0) {
        return raw.slice(open + 1, i);
      }
    }
  }
  return null;
}

/** 一条前景写法属于哪一族：判不了返回 ''。 */
function fgKind(text) {
  if (WARM_WHITE_FG.test(text)) {
    return '前景写死成暖白';
  }
  if (FLIPPING_FG.test(text)) {
    return '前景用了会随深浅色翻面的文字令牌';
  }
  if (HEX_FG.test(text)) {
    return '前景写死成十六进制色';
  }
  if (/fontColor\(\s*[A-Za-z_$]/.test(text)) {
    return '前景由方法或变量给出（静态判不了）';
  }
  return '';
}

/**
 * C1：底色是用户自选色的节点，前景必须由底色决定。
 * 返回 `{ violations, wired, exempt, textless, helper, skipped }`——helper 是"底色像从助手取的、
 * 这条判不了"的站点数，写在清单里当覆盖边界，不当通过。
 */
function auditForeground(repo) {
  const violations = [];
  let wired = 0;
  let exempt = 0;
  let textless = 0;
  let helper = 0;
  let skipped = 0;
  for (const rel of UI_TREES.flatMap((t) => listEts(repo, t))) {
    const raw = fs.readFileSync(path.join(repo, rel), 'utf8');
    const lines = raw.split(/\r?\n/);
    const tbl = depthTable(lines);
    const blank = blankKeep(raw);
    let n = blank.indexOf('.backgroundColor(');
    while (n >= 0) {
      const line = lineAt(blank, n);
      const arg = argOf(raw, blank, n + '.backgroundColor'.length);
      if (arg === null) {
        skipped++;
      } else if (USER_BG.test(nonTokenArg(arg))) {
        const found = chainOf(lines, tbl, line);
        if (found === null) {
          skipped++;
        } else {
          const parts = partsOf(lines, found);
          if (parts.whole.includes(EXEMPT_MARK)) {
            exempt++;
          } else {
            // 链上的行（连续区间）加直接子节点那几行，才凑齐"压在这块色上的字"
            const idx = [];
            for (let j = found.chainStart; j <= found.end; j++) {
              idx.push(j);
            }
            for (const j of childLines(lines, tbl, found)) {
              idx.push(j);
            }
            const fgs = [];
            for (const j of idx) {
              const text = lines[j].trim();
              if (text && !isComment(text) && text.includes('fontColor(')) {
                fgs.push({ n: j, text: text });
              }
            }
            if (fgs.length === 0) {
              textless++; // 纯色块：没有文字要读
            } else {
              const bad = fgs.filter((f) => !FOLLOWS.test(f.text));
              if (bad.length === 0) {
                wired++;
              } else {
                for (const f of bad) {
                  violations.push(rel + ':' + (f.n + 1) + '：这里压的是用户自选的班次色（' + found.kind
                    + '，底色在 ' + (line + 1) + ' 行），' + (fgKind(f.text) || '前景没跟着底色走') + '——'
                    + f.text.slice(0, 72) + '。浅色档下这样能低到 1.2:1，改 DesignTokens.foregroundOn(同一个底色)'
                    + '，或在该节点写一行 // ' + EXEMPT_MARK + ' 理由');
                }
              }
            }
          }
        }
      } else if (CALL.test(nonTokenArg(arg))) {
        helper++;
      }
      n = blank.indexOf('.backgroundColor(', n + 1);
    }
  }
  return { violations: violations, wired: wired, exempt: exempt, textless: textless,
    helper: helper, skipped: skipped };
}

/** color.json 里取一个 name 的 value；找不到返回 null。 */
function resourceColor(repo, rel, name) {
  const text = fs.readFileSync(path.join(repo, rel), 'utf8');
  const m = new RegExp('"name"\\s*:\\s*"' + name + '"\\s*,\\s*"value"\\s*:\\s*"([^"]+)"').exec(text);
  return m === null ? null : m[1];
}

/** `SwatchInk.ets` 里声明的两个墨色字面量——本条把它们当唯一出处，资源抄写得跟它一致。 */
function inkLiterals(repo) {
  const text = fs.readFileSync(path.join(repo, SWATCH_INK), 'utf8');
  const ink = /const INK: string = '([^']+)'/.exec(text);
  const white = /const WARM_WHITE: string = '([^']+)'/.exec(text);
  return { ink: ink === null ? null : ink[1], white: white === null ? null : white[1] };
}

/**
 * C2：两个墨色的"资源抄写"必须跟 `SwatchInk` 一致，且 `swatch_fg` 两档同值。
 * 依赖方向是反的（资源去跟 ArkTS 常量），因为判据写在 `SwatchInk` 里、`DesignTokens.foregroundOn`
 * 也只是把那两个资源递出去；真值在哪边，就得由另一边来核。
 */
function auditInkLiterals(repo) {
  const violations = [];
  const lit = inkLiterals(repo);
  if (lit.ink === null || lit.white === null) {
    return [SWATCH_INK + '：读不到 const INK／const WARM_WHITE，对比度门禁无法核对字面量'];
  }
  const values = {};
  for (const tier of Object.keys(COLOR_JSON)) {
    const rel = COLOR_JSON[tier];
    if (!fs.existsSync(path.join(repo, rel))) {
      violations.push(rel + '：色板文件不在，无法核对 swatch_fg／hero_fg');
      continue;
    }
    const swatch = resourceColor(repo, rel, 'swatch_fg');
    const hero = resourceColor(repo, rel, 'hero_fg');
    values[tier] = { swatch: swatch, hero: hero };
    if (swatch === null) {
      violations.push(rel + '：缺 app.color.swatch_fg（亮底色块的前景）');
    } else if (swatch.toUpperCase() !== lit.ink.toUpperCase()) {
      violations.push(rel + '：swatch_fg 是 ' + swatch + '，与 SwatchInk.inkHex()=' + lit.ink
        + ' 不一致——前景判据算的是后者，深墨会跟资源对不上号');
    }
    if (hero === null) {
      violations.push(rel + '：缺 app.color.hero_fg（暗底暖白）');
    } else if (hero.toUpperCase() !== lit.white.toUpperCase()) {
      violations.push(rel + '：hero_fg 是 ' + hero + '，与 SwatchInk.warmWhiteHex()=' + lit.white + ' 不一致');
    }
  }
  if (values.base && values.dark && values.base.swatch !== null && values.dark.swatch !== null
    && values.base.swatch !== values.dark.swatch) {
    violations.push('swatch_fg 在两档里不等（base ' + values.base.swatch + ' / dark ' + values.dark.swatch
      + '）：用户选的底色不随深浅色翻面，压它的前景也不许翻');
  }
  return violations;
}

/**
 * 扫 UI 侧，返回 `{ violations, ...水位 }`。`violations` 把 C1 与 C2 并成一条口径，门禁只看它空不空；
 * 分开的计数留给清单，免得下一个人把 wired 当成全仓覆盖数。
 */
export function auditContrast(repo) {
  const fg = auditForeground(repo);
  const violations = fg.violations.concat(auditInkLiterals(repo));
  return { violations: violations, wired: fg.wired, exempt: fg.exempt, textless: fg.textless,
    helper: fg.helper, skipped: fg.skipped };
}

// 直接跑这个文件时打一份清单，供批次盘点与人工核对用。
const self = path.resolve(fileURLToPath(import.meta.url));
if (process.argv[1] && path.resolve(process.argv[1]) === self) {
  const repo = path.resolve(path.dirname(self), '..', '..');
  const r = auditContrast(repo);
  console.log('底色为用户自选色的色块：前景跟着底色走的 ' + r.wired + ' 处，写明理由豁免 ' + r.exempt
    + ' 处，没有文字的 ' + r.textless + ' 处，底色取自助手/令牌（这条不判）' + r.helper
    + ' 处，认不出开口的 ' + r.skipped + ' 处，待补 ' + r.violations.length + ' 处');
  for (const v of r.violations) {
    console.log('  ' + v);
  }
}
