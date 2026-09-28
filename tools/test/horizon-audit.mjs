/**
 * 视界天数的上下界只写一次的离线静态审计（差异文档 D-57 的防回潮判据，批次 AG）。
 *
 * 为什么这算一条检查而不是"顺手收拾一下"：AG 之前 `Math.max(1, Math.min(…, 366))` 在四个地方
 * 各抄了一份（`CommonFreeEngine`、`SnapshotBuilder`、`ScheduleUseCase` 两处），第五处
 * （起草器那段区间的天数）**只夹了下界和用户的视界、没夹那个 366**。四份今天判得一样，
 * 第五份今天也没错——但它们已经是五份了：改上限的人要同时记得改五处，漏一处就是
 * "同一份设置，两个读者算出不同的往后多少天"。X1／AE／AF 三轮修的都是这一族（抄写的口径分家），
 * 这一条把它拦在写下来的那一刻。
 *
 * 规则三条，都只认**代码**（注释与字符串字面量不算，AG 的说明本身要提到 366）：
 * - H1：`Math.min(` 里出现裸 `366` 的那一行，只许在 `domain/src/main/ets/model/Types.ets`
 *   （`HORIZON_MAX_DAYS` 的定义处）。别处要收界就调 `clampHorizonDays()`。
 * - H2：**面向用户的字符串**里出现 `HORIZON_MAX_DAYS` 的字面值（界面上的"7–366 天"那一类）。
 *   读数要念常量，抄字面量就会跟引擎分家——AG 之前 `MeView` 的提示与无障碍朗读各写了一次 366。
 * - H3：读 `AppConst.HORIZON_DAYS` 的那一行。默认天数从 D-59 起住在 domain 的
 *   `HORIZON_DEFAULT_DAYS`（`defaultParams()` 用的就是它），commons 那份是它的第二份抄写，
 *   而且它管着**给用户看的一句话**（班表编辑器那句"自动展开未来 120 天"）——改 domain 的人
 *   不会想到去改 commons，那句界面话就替引擎承诺了一个它已经不用的数。
 *   `AppConst.HORIZON_DAYS` 的定义本身不算违规（那是用户自己的文件，删不删由他定），这条只拦读者。
 *
 * 判不了的情形（不猜，也不冒充覆盖）：
 * - 别的数字（布局宽度、别的阈值）撞上车面 `Math.min(` 又恰好等于 366：今天没有，真遇到就在
 *   **这一行行尾**写 `// horizon-ceil-exempt 理由` 放行（独占一行的标记压不住别处），理由要能被人复核。
 * - H2 只认"整份源码里出现过的上限字面值"，不认算出来的表达式（`'' + (365 + 1)` 它看不见）。
 *   这条要拦的是顺手抄一个数，不是拦一个故意绕开的写法。
 * - H3 只认 `AppConst.HORIZON_DAYS` 这个写法本身；把默认值改名或再抄第三份（例如某个页面
 *   自己写 `120`）它看不见——那要靠 H2 那种"字面值扫字符串"的写法才抓得到，今天不做是因为
 *   今天没有第三个读者，等出现了再加，不预先立一条空转的判据。
 * - 计算侧真正"有没有按这个天数展开"由 `EngineTest` 的 `compute_stops_at_the_horizon_ceiling_…`
 *   与 `SnapshotTest` 的 `oversized_horizon_…` 两格在离线跑，静态口径只负责"别再抄第二份"。
 * - D-59 新加的"读取口收界"（`RhythmRules.horizonFromStore`）由 `RhythmRulesTest` 的四格离线用例
 *   钉住数值行为，静态口径判不了"谁忘了调它"——那一句留给下一个读者。
 */
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { listEts } from './chain-scan.mjs';

/** 定义处：整个仓库只有这里的 366 是"规定"，其余都是抄写。 */
const HOME = 'domain/src/main/ets/model/Types.ets';
/** 主源码树：用例与工具脚本允许把上限当字面量写（那是规格，不是第二份口径）。 */
const TREES = ['domain/src/main/ets', 'feature/src/main/ets', 'data/src/main/ets',
  'commons/src/main/ets', 'entry/src/main/ets', 'cloud/src/main/ets'];
const EXEMPT_MARK = 'horizon-ceil-exempt';
/** 默认天数的旧抄写：D-59 起它没有读者了，出现读者就是违规（H3）。 */
const OLD_DEFAULT = 'AppConst.HORIZON_DAYS';
const STRING_LITERALS = /(['"`])((?:\\.|(?!\1)[^\\])*)\1/g;

/** 注释（`//` 与块注释的 `*` 续行）不参与判定：AG 的说明里就得写清 366 是多少。 */
function codeOf(line) {
  const t = line.trim();
  if (t.startsWith('*') || t.startsWith('//') || t.startsWith('/*')) {
    return '';
  }
  const i = line.indexOf('//');
  return i >= 0 ? line.slice(0, i) : line;
}

function literalsOf(code) {
  const out = [];
  for (const m of code.matchAll(STRING_LITERALS)) {
    out.push(m[2]);
  }
  return out;
}

/**
 * 扫描主源码，返回 `{ violations, callSites, defaultReads, ceiling }`。
 * `callSites` 是给门禁看的水位：有几个地方在调那一道闸；`defaultReads` 是还在读 commons 那份默认值
 * 的行数（D-59 起应为 0）；`ceiling` 是定义处读到的上限。
 */
export function auditHorizonCeiling(repo) {
  const violations = [];
  let callSites = 0;
  let defaultReads = 0;
  let defaultHome = false;
  let ceiling = -1;
  for (const tree of TREES) {
    for (const rel of listEts(repo, tree)) {
      const lines = fs.readFileSync(path.join(repo, rel), 'utf8').split(/\r?\n/);
      for (let i = 0; i < lines.length; i++) {
        // 豁免标记看**整行原文**：codeOf 已经把行尾注释剥掉了，拿剥完的 code 找标记等于没这条口子
        if (lines[i].includes(EXEMPT_MARK)) {
          continue;
        }
        const code = codeOf(lines[i]);
        if (rel === HOME) {
          const def = code.match(/export const HORIZON_MAX_DAYS:\s*number\s*=\s*(\d+)/);
          if (def != null) {
            ceiling = Number(def[1]);
          }
          if (/export const HORIZON_DEFAULT_DAYS:\s*number\s*=\s*\d+/.test(code)) {
            defaultHome = true;
          }
        }
        if (code.includes('clampHorizonDays(')) {
          callSites++;
        }
        // H3：默认天数又从 commons 那份里读了一次
        if (code.includes(OLD_DEFAULT)) {
          defaultReads++;
          violations.push(rel + ':' + (i + 1) + '：这里读了 ' + OLD_DEFAULT + '——视界的默认天数只在 '
            + HOME + ' 的 HORIZON_DEFAULT_DAYS 定义一次，commons 那份是它的第二份抄写（AI·D-59）');
        }
        // H1：手抄一份上下界
        if (rel !== HOME && /\bMath\.min\s*\([^)]*\b366\b/.test(code)) {
          violations.push(rel + ':' + (i + 1) + '：这里又抄了一遍视界上限——上限只在 ' + HOME
            + ' 定义一次，请调 clampHorizonDays()（AG·D-57）');
        }
        // H2：面向用户的读数里抄了那个数
        if (rel !== HOME && ceiling > 0) {
          for (const lit of literalsOf(code)) {
            if (lit.startsWith('#')) {
              continue; // 色值：'#366' 是合法的三位缩写色，不是天数
            }
            // 认独立的那个数字：'1366' 之类只是碰巧含了它
            if (new RegExp('(^|[^0-9])' + ceiling + '([^0-9]|$)').test(lit)) {
              violations.push(rel + ':' + (i + 1) + '：字符串里写了 ' + ceiling
                + '——界面上的天数要念 HORIZON_MIN／HORIZON_MAX，抄字面量就会跟引擎分家（AG·D-57）');
            }
          }
        }
      }
    }
  }
  if (ceiling <= 0) {
    violations.push(HOME + '：读不到 HORIZON_MAX_DAYS 的字面量定义——这条口径判不了，别把它当成绿');
  }
  if (!defaultHome) {
    violations.push(HOME + '：读不到 HORIZON_DEFAULT_DAYS 的字面量定义——H3 说的"默认值有家"就不成立');
  }
  return { violations: violations, callSites: callSites, defaultReads: defaultReads, ceiling: ceiling };
}

// 直接跑这个文件时打一份清单，供批次盘点与人工核对用。
const self = path.resolve(fileURLToPath(import.meta.url));
if (process.argv[1] && path.resolve(process.argv[1]) === self) {
  const repo = path.resolve(path.dirname(self), '..', '..');
  const r = auditHorizonCeiling(repo);
  console.log('上限 ' + r.ceiling + ' 天（定义在 ' + HOME + '），clampHorizonDays 调用 ' + r.callSites
    + ' 处，commons 那份默认值的读者 ' + r.defaultReads + ' 处，越界抄写 ' + r.violations.length + ' 处');
  for (const v of r.violations) {
    console.log('  ' + v);
  }
}
