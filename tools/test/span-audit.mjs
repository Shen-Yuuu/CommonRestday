/**
 * 「一个瞬间算哪一天／一段区间跨几天」只写一次的离线静态审计（差异文档 D-60 的防回潮判据，批次 AJ）。
 *
 * 为什么这条值得写成门禁：半开区间 `[start, end)` 的两个端点**归日规则不一样**——起点整零点归当天，
 * 终点整零点归前一天（`[…, 24:00)` 说的是这一天的尾巴）。AH（D-58）处理的是这条口径的"念法"半边，
 * 这一条是"算法"半边：AJ 之前同一件事在仓内有五份抄写，其中三种拼法——
 * `Math.floor(x / MIN_PER_DAY)`（四处）、`Math.floor(x / 1440)`（裸字面量，两处）、
 * `Math.max(firstDay, Math.ceil(x / MIN_PER_DAY) - 1)`（起草器那处，把终点向上取整再减一）。
 * 三种在今天等价，但只有第一种接得住"终点是整零点"：夜班窗口 `[20:00, 24:00)` 用第二种会多出
 * 一个次日零点也算进去的日子，用第三种在 `end` 恰好落在整零点时反倒少一天。跨零点作息那条同理，
 * 判定 `bedMin < wakeMin` 原本在引擎（AvailabilityBuilder）与分类器（WindowClassifier）各写一遍，
 * 页面（RhythmRules.isCrossMidnight）还有第三遍——引擎延到次日、页面说"没跨"，就是屏幕上
 * 「就寝 01:00」被解释成两回。
 *
 * 规则三条，都只认**代码**（注释与文档里的 1440 是规格说明，不算第二份实现）：
 * - S1：一行里同时出现「取整」（`Math.floor`／`Math.ceil`／`Math.trunc`）与「**除以**一天长度」
 *   （`/ MIN_PER_DAY`、`/ DAY_MIN`、`/ 1440`，除数位置才算，乘回去与除 60 都不算）时，
 *   只许写在 `domain/src/main/ets/utils/TimeUtil.ets`
 *   （`dayOfStart`／`dayOfEnd`／`daySpan`／`epochDayOf` 的定义处）。端点归日请走那两个函数。
 * - S2：「就寝早于起床」这一比较（`bed… < wake…`，严格小于）只许出现在同一文件里，
 *   也就是 `bedCrossesMidnight` 的定义处。`bed === wake`（校验层的退化输入）与 `bed < 0`
 *   （解析失败）不是这条口径，不拦。
 * - S3：这几位家得**有人用**——`dayOfStart`／`dayOfEnd`／`daySpan`／`bedEndMin` 在自家以外
 *   一处读者都没有时，本条判不了，直接判失败，不冒充绿。
 *
 * 判不了的情形（不猜，也不冒充覆盖）：
 * - **乘法与取模方向**（`epochDay * MIN_PER_DAY`、`nowMin % MIN_PER_DAY`）不在射程内：那是"由日号求
 *   当天 00:00"和"当日第几分钟"，没有端点歧义。本条只拦归日。
 * - 比例读数（`(be - bs) / MIN_PER_DAY * 100` 这类画条图宽度的）不在射程内：它算的是"一天占百分之几"，
 *   不是"这一刻归哪天"。这条离它最近，写在这里是因为它最容易被误当成一份归日实现"顺手并进来"——
 *   那是错的，并了就把两种量搅成一锅。
 * - `commons/src/main/ets/util/DateLabel.ets` 的 `edgeDay` 是**明知故留的第二份**：`commons` 不能
 *   import `domain`（依赖图的底，加边要用户裁定，见差异文档 §7 待裁定第 2 条），所以它的
 *   `Math.floor(min / DAY_MIN)` 靠行尾标记放行，同函数里 `min / DAY_MIN - 1` 那一支不含取整、
 *   本条看不见。两份等不等价由 `entry/src/test/DateLabelTest.ets` 的
 *   `edge_day_and_time_agree_with_the_domain_edge_rule` 在离线跑，静态这一条只负责"别再抄第三份"。
 * - 不合规又确属必要的行，在**这一行行尾**写 `// day-span-exempt 理由` 放行（独占一行的标记
 *   不顶事：它压不住别处的读数），理由要能被人复核。
 * - `lastDay - firstDay + 1` 这一类"自己数日子"的写法离线判不出语义（循环边界长得一样），
 *   本批靠的是把五个读数点都换成 `daySpan`，不是靠一条猜想的正则。
 */
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { listEts } from './chain-scan.mjs';

/** 归日与跨零点的唯一定义处。 */
const HOME = 'domain/src/main/ets/utils/TimeUtil.ets';
/** 主源码树：测试与工具脚本允许把 1440 当字面量断言（那是规格，不是第二份口径）。 */
const TREES = ['domain/src/main/ets', 'feature/src/main/ets', 'data/src/main/ets',
  'commons/src/main/ets', 'entry/src/main/ets', 'cloud/src/main/ets'];
const EXEMPT_MARK = 'day-span-exempt';
const ROUNDING = ['Math.floor(', 'Math.ceil(', 'Math.trunc('];
/**
 * 「除以一天长度」要按**除数位置**认：`x / MIN_PER_DAY`、`x / (1440 * 60 * 1000)` 算，
 * `epochDay * MIN_PER_DAY`（乘回去）与 `… / 60`（除的是分钟）都不算。
 * 上一版只要求"同一行既有取整又有 1440"，于是周历那行 `Math.floor((startMin - epochDay * MIN_PER_DAY) / 60)`
 * 被当成归日误报——除数是 60，它算的是"当日第几分钟"，跟端点归哪天无关。
 */
const DIVIDED_BY_DAY = /\/\s*\(?\s*(MIN_PER_DAY|DAY_MIN|1440)\b/;
/** 家以外的读者计数：一处都没有就说明这条口径压根没接上。 */
const HELPERS = ['dayOfStart(', 'dayOfEnd(', 'daySpan(', 'bedEndMin(', 'bedCrossesMidnight('];
/** S2 的形状：`bed…` 严格小于 `wake…`（不含 `<=`、`===`，也不含与 0 的比较）。 */
const BED_RULE = /\bbed[A-Za-z0-9_]*\s*<\s*[a-z][A-Za-z0-9_]*wake[A-Za-z0-9_]*/i;

/** 注释（`//` 与块注释的 `*` 续行）不参与判定：D-60 的说明本身就得写清 1440 长什么样。 */
function codeOf(line) {
  const t = line.trim();
  if (t.startsWith('*') || t.startsWith('//') || t.startsWith('/*')) {
    return '';
  }
  const i = line.indexOf('//');
  return i >= 0 ? line.slice(0, i) : line;
}

/**
 * 扫描主源码，返回 `{ violations, readerSites, exempt, dayDivisions }`。
 * `dayDivisions` 是"取整 + 一天长度"的总行数（含家里的），给门禁看水位；
 * `readerSites` 数的是家以外的调用点，只有一处都没有才判失败。
 */
export function auditDaySpan(repo) {
  const violations = [];
  let readerSites = 0;
  let exempt = 0;
  let dayDivisions = 0;
  for (const tree of TREES) {
    for (const rel of listEts(repo, tree)) {
      const lines = fs.readFileSync(path.join(repo, rel), 'utf8').split(/\r?\n/);
      for (let i = 0; i < lines.length; i++) {
        // 豁免标记看**整行原文**：判定用的 code 已经把行尾注释剥掉了，拿它找标记等于没这条口子
        if (lines[i].includes(EXEMPT_MARK)) {
          exempt++;
          continue;
        }
        const code = codeOf(lines[i]);
        if (code === '') {
          continue;
        }
        for (const h of HELPERS) {
          if (rel !== HOME && code.includes(h)) {
            readerSites++;
          }
        }
        // S1：把"一个瞬间算哪天"又除了一遍一天长度
        const isDivision = ROUNDING.some((f) => code.includes(f)) && DIVIDED_BY_DAY.test(code);
        if (isDivision) {
          dayDivisions++;
          if (rel !== HOME) {
            violations.push(rel + ':' + (i + 1) + '：这里自己除了一次"一天多少分钟"来定日号——'
              + '端点归日只有 ' + HOME + ' 的 dayOfStart／dayOfEnd 两处，跨零点的终点用 floor 会多算一天'
              + '（AJ·D-60）');
          }
        }
        // S2：别处又判了一遍"就寝算不算跨零点"
        if (rel !== HOME && BED_RULE.test(code)) {
          violations.push(rel + ':' + (i + 1) + '：这里又写了一遍 bed<wake 的判定——跨零点作息只由 '
            + HOME + ' 的 bedCrossesMidnight 解释，两份判定会让引擎与页面对同一条作息各说各话（AJ·D-60）');
        }
      }
    }
  }
  const home = path.join(repo, HOME);
  if (!fs.existsSync(home)) {
    violations.push(HOME + '：读不到定义处的文件——这条口径判不了，别把它当成绿');
  } else {
    const src = fs.readFileSync(home, 'utf8');
    for (const name of ['dayOfStart', 'dayOfEnd', 'daySpan', 'bedCrossesMidnight', 'bedEndMin']) {
      if (!src.includes('export function ' + name + '(')) {
        violations.push(HOME + '：读不到 ' + name + ' 的定义——这条口径判不了，别把它当成绿');
      }
    }
  }
  if (readerSites === 0) {
    violations.push(HOME + '：家以外读不到 dayOfStart／dayOfEnd／daySpan／bedEndMin 的任何调用——'
      + '口径写了没人用，本条判不了（AJ·D-60）');
  }
  return { violations: violations, readerSites: readerSites, exempt: exempt,
    dayDivisions: dayDivisions };
}

// 直接跑这个文件时打一份清单，供批次盘点与人工核对用。
const self = path.resolve(fileURLToPath(import.meta.url));
if (process.argv[1] && path.resolve(process.argv[1]) === self) {
  const repo = path.resolve(path.dirname(self), '..', '..');
  const r = auditDaySpan(repo);
  console.log('取整×一天长度 ' + r.dayDivisions + ' 处（都该在家里），家以外读者 '
    + r.readerSites + ' 处，写明理由豁免 ' + r.exempt + ' 处，归日／跨零点抄写 '
    + r.violations.length + ' 处');
  for (const v of r.violations) {
    console.log('  ' + v);
  }
}
