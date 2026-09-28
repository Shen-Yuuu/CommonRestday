/**
 * 「把半开区间 `[start,end)` 裁进 `[from,to)`，裁空不算」只写一次的离线静态审计（差异文档 D-61 的防回潮判据，批次 AK）。
 *
 * 为什么这条值得写成门禁：全仓每一次"按日展开""按视界展开""算这一段共多少分钟"都要先把区间裁进窗口，
 * 而这条口径有**一个容易写错的判据**——相接不算。`[20:00, 24:00)` 裁进次日就得是空，写成
 * `Math.min(end, to) >= Math.max(start, from)` 就会多出一段零长度的"次日窗口"，页面把它念成
 * 次日 00:00 的一个块。改前有几份是在 HEAD 快照上跑本条量出来的，不是数出来的印象：
 * 非嵌套的 `Math.max`／`Math.min` 取界对**全仓 10 处**（`IntervalOps` 自家 3 处：
 * `complement`／`totalOverlap`／`overlapMin`；家以外 7 处），**三元一对** 1 处
 * （`CommonTimeQueryService` 的日详情装配），**同一条判据的谓词形状** 6 处，
 * 另有一处"整段时长直接相加"（日详情页头那句"当日空闲"）连裁都没裁——
 * 跨零点的窗口会把两整天的时长都算进那一天，那一处是真错，见 §8.23。
 * 抄写的另一重代价是**单位漂移**：`SnapshotBuilder` 的位图先把区间裁进视界、再向外取整到 30 分钟槽
 * （宁可多算忙），改前它用的是"落槽后再夹界"，与"先夹界再落槽"只是恰好等价（`base` 是日界，
 * 必为 SLOT 的整倍数）——没有人会去验证那个"恰好"。
 *
 * 规则四条，都只认**代码**（注释里的 `Math.max` 是说明，不算第二份实现）：
 * - S1：成对且**非嵌套**的 `Math.max(…)` ＋ `Math.min(…)` 只许写在
 *   `domain/src/main/ets/merge/IntervalOps.ets` 的 `clipInto` 定义处，且家里必须**恰好一处**
 *   （多一处就是家里又分叉）。成对有两种形状：本行自己两个都有，或本行与次行各写其中一个
 *   （`clipInto` 就是这么写的）。嵌套形状 `Math.max(a, Math.min(b, x))` 是另一条口径
 *   ——把一个数夹进上下界（视界天数、格高、百分比都靠它），与"裁一段区间"不同量，本条不拦。
 * - S2：相邻两行都写成"三元取界"（`X > Y ? X : Y` 与 `X < Y ? Y : X`），且操作数名字里带
 *   start／end／from／to／day 这类边界字样时，等于又抄了一遍 `clipInto`——只许走函数。
 *   单边的三元（`w.start > now ? w.start : now`，只定起点、没有上界）不算，`SwatchInk` 那种
 *   两个亮度分大小也不算：它们裁的不是区间。
 * - S3：这几位家得**有人用**——`clipInto`／`Clip`／`intersects` 的定义必须在，家以外一处读者都没有时
 *   本条判不了，直接判失败，不冒充绿。
 * - S4：同一条判据的**谓词形状**——一行里 `…start < A && …end > B`（或反序 `…end > B && …start < A`，
 *   含裸标量名 `workStart < ne && workEnd > ns`）就是"两段算不算相交"，只许走 `intersects`。
 *   这类抄写比 max/min 对更隐蔽：它不取界，只在筛选循环里比两个端点，六处各写一遍时
 *   "相接算不算"就有六个答案。AK 把六处都换成 `intersects`，本条负责不再出现第七处。
 *
 * 判不了的情形（不猜，也不冒充覆盖）：
 * - 只夹单侧边界的写法拦不住（本仓没有）。真要出现，给它加行尾豁免标记并写清理由。
 * - S2 认"相邻两行 + 分支就是被比较的那两个操作数 + 名字里带边界字样"三个条件同时成立。
 *   `commons/src/main/ets/util/SwatchInk.ets` 那两行（`l1 > l2 ? l1 : l2` 与反面）形状一模一样，
 *   只靠 `l1`／`l2` 里没有边界字样躲过——这条口子是**按命名认的**，不是按语义认的：将来谁把
 *   两个标量起名 `startAt`／`endAt` 写同样两行，会被误报。真到那一步，该改判据还是该改名字，
 *   由那时的人重新判断，别默认门禁是对的。
 * - 行尾标记 `// clip-exempt 理由` 写在**这一对涉及的任一行**行尾都放行（跨行的两行形状把理由
 *   写在次行是常态），理由要能被人复核；判定用的是剥掉行尾注释的代码，所以标记必须写在原文末尾。
 *   豁免计数与读者水位按行单独统计一遍，不吃成对判定的游标。
 * - "整段时长直接相加"这种根本没取界的写法静态判不出来（它不长得像裁剪）。AK 的处理是把它并回
 *   `CommonTimeQueryService.regularFreeMin`，并让 `clip-audit` 的水位只数 `clipInto` 的读者，
 *   不去猜哪段循环本该是裁剪。
 * - `mergeIntervals` 里"相接要合并"（`cur.start <= last.end`）与本条"相接不算"是**两回事**：
 *   一条说的是两个忙碌段挨着算一段，一条说的是区间与窗口的交叠。别把它们并成一个函数。
 * - S4 **只认严格比较**：`<=`／`>=` 那一类是"包含"（`WindowClassifier:89` 判窗口包不包住核心段），
 *   不是交叠，不拦。代价写在明处：谁把交叠写成 `start <= to && end >= from`（相接也算相交，正是本条
 *   要防的那个错），S4 看不见——那一行会同时被 S1 或 S2 抓住的概率不高，所以这条口子按已知欠账留着，
 *   不假装判据覆盖到了。
 */
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { listEts } from './chain-scan.mjs';

/** 裁剪的唯一定义处。 */
const HOME = 'domain/src/main/ets/merge/IntervalOps.ets';
/** 主源码树：测试与工具脚本允许自行取界（那是断言，不是第二份口径）。 */
const TREES = ['domain/src/main/ets', 'feature/src/main/ets', 'data/src/main/ets',
  'commons/src/main/ets', 'entry/src/main/ets', 'cloud/src/main/ets'];
const EXEMPT_MARK = 'clip-exempt';
/** 边界字样：三元对里连这个都没有，就不是在裁区间（SwatchInk 的两个亮度、时长比较）。 */
const BOUND_NAME = /(start|end|from|to|day|bound)/i;
/** `X > Y ? X : Y`／`X < Y ? Y : X`：两个分支就是被比较的那两个操作数。 */
const TERN_BOUND = /([A-Za-z_][\w.]*)\s*([<>])\s*([A-Za-z_][\w.]*)\s*\?\s*([A-Za-z_][\w.]*)\s*:\s*([A-Za-z_][\w.]*)/;
/**
 * S4：交叠判据的谓词形状，两个顺序都认。名字只要求**以 start／end 结尾**，于是
 * `w.start`／`all[i].start`／裸标量 `workStart` 都在射程内（`startMin` 这类带后缀的不认，
 * 那是另一族名字，真要出现由人加进来）。`<`／`>` 后面跟 `=` 不算——那是"包含"，见文件头。
 */
const OVERLAP_START_FIRST = /\b\w*(?:start|Start)\s*<(?!=)[^&]*&&[^&]*\b\w*(?:end|End)\s*>(?!=)/;
const OVERLAP_END_FIRST = /\b\w*(?:end|End)\s*>(?!=)[^&]*&&[^&]*\b\w*(?:start|Start)\s*<(?!=)/;

/** 注释（`//` 与块注释的 `*` 续行）不参与判定：这条口径的说明本身就得写出 max/min 长什么样。 */
function codeOf(line) {
  const t = line.trim();
  if (t.startsWith('*') || t.startsWith('//') || t.startsWith('/*')) {
    return '';
  }
  const i = line.indexOf('//');
  return i >= 0 ? line.slice(0, i) : line;
}

/**
 * `openAt` 处那个开括号自己的范围内（含嵌套行）是否出现过 `needle`。
 * 用来分清"嵌套的夹界"与"成对的裁剪"：扫描整段文本从 `openAt` 往后数括号，最深回到 0 时结束。
 */
function nestedWithin(text, openAt, needle) {
  let depth = 0;
  let i = openAt;
  const from = text.indexOf('(', i);
  if (from < 0) {
    return false;
  }
  i = from;
  while (i < text.length) {
    const ch = text[i];
    if (ch === '(') {
      depth++;
    } else if (ch === ')') {
      depth--;
      if (depth === 0) {
        return false;
      }
    } else if (depth > 0 && ch === needle[0] && text.startsWith(needle, i)) {
      return true;
    }
    i++;
  }
  return false;
}

/** 一行里 max/min 是否成对（且非嵌套）。跨行的对由调用方把次行拼进来再看一次。 */
function isClipPair(text) {
  const maxAt = text.indexOf('Math.max(');
  const minAt = text.indexOf('Math.min(');
  if (maxAt < 0 || minAt < 0) {
    return false;
  }
  // 谁在外面，就看它自己的括号里有没有另一个——嵌套就是"把一个数夹进上下界"，不是裁区间。
  return maxAt < minAt ? !nestedWithin(text, maxAt, 'Math.min(')
    : !nestedWithin(text, minAt, 'Math.max(');
}

function only(t) {
  return { max: t.includes('Math.max('), min: t.includes('Math.min(') };
}

/**
 * 本行与次行是否**各写一个**取界函数（拼起来才成对）。
 * 上一版是"本行原文 + 次行原文里两个都在"就算，于是`function probe(…): number {` 这种
 * 谁都不含的行也能跟下一行拼成一笔：报出来的行号偏一行，而且成对后游标多走一步，
 * 把写着 `// clip-exempt` 的次行直接吞掉——那种形状就永远免不掉（探针 p8 抓到的正是这条）。
 * 要求两行各只含其中一个，行号才落在真正的起点，次行的标记也才有机会被看到。
 */
function isSplitPair(codeLines) {
  const a = codeLines[0];
  const b = codeLines[1];
  if (a === '' || b === '') {
    return false;
  }
  const oa = only(a);
  const ob = only(b);
  return (oa.max !== oa.min) && (ob.max !== ob.min) && isClipPair(a + '\n' + b);
}

/** 三元取界形状：两个分支恰为被比较的那两个操作数（顺序不论）。 */
function ternBoundPairOf(line) {
  const code = codeOf(line);
  const m = TERN_BOUND.exec(code);
  if (m == null) {
    return null;
  }
  const a = m[1];
  const b = m[3];
  const x = m[4];
  const y = m[5];
  const sameSet = (x === a && y === b) || (x === b && y === a);
  if (!sameSet) {
    return null;
  }
  return BOUND_NAME.test(a + b + x + y) ? code : null;
}

/**
 * 扫描主源码，返回 `{ violations, readerSites, predicateSites, pairSites, exempt, homePairs }`。
 * `readerSites` 是家以外 `clipInto(` 的调用点，`predicateSites` 是家以外 `intersects(` 的调用点
 * （两个水位各 0 处才判"没人用"）；`pairSites` 是全仓非嵌套 max/min 对的总数
 * （含家里那一处，应当恰好 1）；`exempt` 数的是写了行尾豁免标记的行。
 */
export function auditClip(repo) {
  const violations = [];
  let readerSites = 0;
  let predicateSites = 0;
  let pairSites = 0;
  let homePairs = 0;
  let exempt = 0;
  for (const tree of TREES) {
    for (const rel of listEts(repo, tree)) {
      const lines = fs.readFileSync(path.join(repo, rel), 'utf8').split(/\r?\n/);
      // 豁免标记与读者水位先按行各数一遍：成对判定一次吃两行，把这两件事挂在它的游标上
      // 就会漏（写在次行的标记会被游标吞掉，被吞的那行里若有 clipInto 调用也少计一处读者）。
      const marked = lines.map((l) => l.includes(EXEMPT_MARK));
      for (let i = 0; i < lines.length; i++) {
        if (marked[i]) {
          exempt++;
          continue;
        }
        const code = codeOf(lines[i]);
        if (code === '' || rel === HOME) {
          continue;
        }
        if (code.includes('clipInto(')) {
          readerSites++;
        }
        if (code.includes('intersects(')) {
          predicateSites++;
        }
      }
      for (let i = 0; i < lines.length; i++) {
        if (marked[i]) {
          continue;
        }
        const code = codeOf(lines[i]);
        if (code === '') {
          continue;
        }
        const hasNext = i + 1 < lines.length;
        const next = hasNext ? codeOf(lines[i + 1]) : '';
        // S1：成对的取界。本行自己成对，或本行与次行各写一个；次行写了理由就整对放行。
        const own = isClipPair(code);
        const split = !own && hasNext && !marked[i + 1] && isSplitPair([code, next]);
        let consumed = false;
        if (own || split) {
          pairSites++;
          if (rel === HOME) {
            homePairs++;
          } else {
            violations.push(rel + ':' + (i + 1) + '：这里又写了一遍"把区间裁进窗口"的 max/min 对——'
              + '这条口径只有 ' + HOME + ' 的 clipInto，相接算不算只有它一处说了算（AK·D-61）');
          }
          consumed = split;
        }
        // S2：相邻两行的三元取界
        if (rel !== HOME && ternBoundPairOf(code) != null && hasNext && !marked[i + 1]
          && ternBoundPairOf(next) != null) {
          violations.push(rel + ':' + (i + 1) + '：相邻两行用三元各自取了两边的界，等于把 clipInto '
            + '又抄了一遍（相接不算这一条也会跟着漂移）（AK·D-61）');
          consumed = true;
        }
        // S4：交叠判据写成谓词（不取界，只在筛选循环里比两个端点）
        if (rel !== HOME && (OVERLAP_START_FIRST.test(code) || OVERLAP_END_FIRST.test(code))) {
          violations.push(rel + ':' + (i + 1) + '：这里又写了一遍"两段算不算相交"的端点比较——'
            + '相接算不算由 ' + HOME + ' 的 clipInto／intersects 一处定，抄在筛选循环里就是六个答案（AK·D-61）');
        }
        if (consumed) {
          i++;
        }
      }
    }
  }
  const home = path.join(repo, HOME);
  if (!fs.existsSync(home)) {
    violations.push(HOME + '：读不到定义处的文件——这条口径判不了，别把它当成绿');
  } else {
    const src = fs.readFileSync(home, 'utf8');
    if (!src.includes('export function clipInto(')) {
      violations.push(HOME + '：读不到 clipInto 的定义——这条口径判不了，别把它当成绿');
    }
    if (!src.includes('export interface Clip {')) {
      violations.push(HOME + '：读不到 Clip 的定义——裁剪结果没有形状，调用方就还得自己写一对 max/min');
    }
    if (!src.includes('export function intersects(')) {
      violations.push(HOME + '：读不到 intersects 的定义——只想筛掉不相交区间的调用点没有谓词可用，'
        + '就会回去自己写一遍端点比较（S4 管的那一族）');
    }
    if (homePairs !== 1) {
      violations.push(HOME + '：家里的 max/min 取界对有 ' + homePairs + ' 处，应当恰好 1 处'
        + '（`clipInto` 那一处）——多于 1 处就是同一份口径在家里又分叉（AK·D-61）');
    }
  }
  if (readerSites === 0) {
    violations.push(HOME + '：家以外读不到 clipInto 的任何调用——口径写了没人用，本条判不了（AK·D-61）');
  }
  if (predicateSites === 0) {
    violations.push(HOME + '：家以外读不到 intersects 的任何调用——谓词形状要么接上要么删掉，'
        + '留着一个没人读的家不算覆盖（AK·D-61）');
  }
  return { violations: violations, readerSites: readerSites, predicateSites: predicateSites,
    pairSites: pairSites, exempt: exempt, homePairs: homePairs };
}

// 直接跑这个文件时打一份清单，供批次盘点与人工核对用。
const self = path.resolve(fileURLToPath(import.meta.url));
if (process.argv[1] && path.resolve(process.argv[1]) === self) {
  const repo = path.resolve(path.dirname(self), '..', '..');
  const r = auditClip(repo);
  console.log('非嵌套的 max/min 取界对全仓 ' + r.pairSites + ' 处（家里 ' + r.homePairs
    + ' 处，应当恰好 1），家以外 clipInto 读者 ' + r.readerSites + ' 处／intersects 读者 '
    + r.predicateSites + ' 处，写明理由豁免 ' + r.exempt + ' 处，抄写 ' + r.violations.length + ' 处');
  for (const v of r.violations) {
    console.log('  ' + v);
  }
}
