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
 * 规则五条，都只认**代码**（注释与字符串字面量不算，AG 的说明本身要提到 366）：
 * - H1：`Math.min(` 里出现裸 `366` 的那一行，只许在 `domain/src/main/ets/model/Types.ets`
 *   （`HORIZON_MAX_DAYS` 的定义处）。别处要收界就调 `clampHorizonDays()`。
 * - H2：**面向用户的字符串**里出现 `HORIZON_MAX_DAYS` 的字面值（界面上的"7–366 天"那一类）。
 *   读数要念常量，抄字面量就会跟引擎分家——AG 之前 `MeView` 的提示与无障碍朗读各写了一次 366。
 * - H3：读 `AppConst.HORIZON_DAYS` 的那一行。默认天数从 D-59 起住在 domain 的
 *   `HORIZON_DEFAULT_DAYS`（`defaultParams()` 用的就是它），commons 那份是它的第二份抄写，
 *   而且它管着**给用户看的一句话**（班表编辑器那句"自动展开未来 120 天"）——改 domain 的人
 *   不会想到去改 commons，那句界面话就替引擎承诺了一个它已经不用的数。
 *   `AppConst.HORIZON_DAYS` 的定义本身不算违规（那是用户自己的文件，删不删由他定），这条只拦读者。
 * - H4：直接调 `SettingsStore.getParams()` 的文件只许是白名单里那两个口子。收界（`horizonFromStore`）
 *   发生在"刚离开存储的那一刻"，所以它的覆盖面**等于口子的名单**——AI 就是靠这条数出来的：
 *   以为只有一个读取口，grep 之后发现「我的 · 作息」回填输入框是第二个，而那一处正是改前真红的那格。
 *   新增口子要么走 `SettingsStoreParams()`，要么自己收界并登记进白名单，并回答"为什么不能并成一个"。
 * - H5：**面向用户的一句话把出厂默认天数额外当自己的数念了一遍**，两种形状都算：
 *   ① `HORIZON_DEFAULT_DAYS` 被 `+` 拼进字符串（`'…未来 ' + HORIZON_DEFAULT_DAYS + ' 天…'`）；
 *   ② 字符串字面量里出现默认天数的**字面值**（`'120'`），即 H2 对上限做的那件事换到默认值上。
 *   这条是 D-63 现形的地方，也是 H3 当年写下"今天没有第三个读者，等出现了再加"的那个时刻：
 *   班表编辑器那句承诺从 commons 的 `AppConst.HORIZON_DAYS` 换成 domain 的 `HORIZON_DEFAULT_DAYS`
 *   之后 H3 绿了，可那句界面话**还是替引擎承诺出厂值**——用户把天数改成 30，保存按钮底下继续写 120。
 *   真正要拦的不是"用了这个常量"，而是"把出厂值念成了当前值"：常量本身照样能用（`horizonFromStore`
 *   的 0/负数回退、`CoTimeView` 的"还没有参数"回退都是合法读者），被禁的是它**落进一句给用户的话**。
 *
 * 判不了的情形（不猜，也不冒充覆盖）：
 * - 别的数字（布局宽度、别的阈值）撞上车面 `Math.min(` 又恰好等于 366：今天没有，真遇到就在
 *   **这一行行尾**写 `// horizon-ceil-exempt 理由` 放行（独占一行的标记压不住别处），理由要能被人复核。
 * - H2 只认"整份源码里出现过的上限字面值"，不认算出来的表达式（`'' + (365 + 1)` 它看不见）。
 *   这条要拦的是顺手抄一个数，不是拦一个故意绕开的写法。H5 的第 ② 形同样看不见算出来的式子。
 * - H3 只认 `AppConst.HORIZON_DAYS` 这个写法本身；把默认值改名或再抄第三份（例如某个页面
 *   自己写 `120`）它看不见——那正是 H5 的第 ② 形负责的（D-63 之后它有了读者：`MeView` 的
 *   `myHorizon` 初值就抄了一次 `'120'`，同批改成 `'' + HORIZON_DEFAULT_DAYS`）。
 * - H5 只认默认天数那**一个**值。同一批回填字段里 `myWake` 的 `'07:00'`、`myBed` 的 `'22:30'`、
 *   `myWind` 的 `'20'` 也是 `defaultParams()` 的抄写，但它们不是"往后多少天"这条口径，
 *   这条闸不越界去管——真要并那一条得先回答"分钟的默认值该住哪"，那是另一批次的事。
 * - 计算侧真正"有没有按这个天数展开"由 `EngineTest` 的 `compute_stops_at_the_horizon_ceiling_…`
 *   与 `SnapshotTest` 的 `oversized_horizon_…` 两格在离线跑，静态口径只负责"别再抄第二份"。
 * - D-59 新加的"离开存储就收界"（`RhythmRules.horizonFromStore`）由 `RhythmRulesTest` 的三格离线用例钉住
 *   数值行为（收界四形、默认值同源、设置页回填）。H4 管的是"口子有哪几个"，**判不了"某个口子里忘了调它"**——
 *   那一格要靠读代码或靠下面这格新用例，别把 H4 绿当成收界齐了。同理，H5 判不了"这句话念的是出厂值
 *   还是实设值"里的那条**数据流**：它只拦常量拼进字符串，拦不住某个页面自己 `= 120` 起步又不回填。
 *   班表编辑器改读 `SettingsStoreParams()` 这一半是靠 `RhythmRulesTest` 的
 *   `the_cycle_hint_promises_the_days_the_engine_will_expand` 钉的，不是靠这条静态判据。
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
/** 离开存储那一刻的合法口子（H4 的白名单）：新增口子要先回答"视界天数收没收界"。 */
const MOUTHS = ['feature/src/main/ets/usecase/ScheduleUseCase.ets',
  'feature/src/main/ets/usecase/ProfileSettingsService.ets'];
const STORE_READ = 'SettingsStore.getParams()';
const STRING_LITERALS = /(['"`])((?:\\.|(?!\1)[^\\])*)\1/g;
const DEFAULT_NAME = 'HORIZON_DEFAULT_DAYS';
/**
 * H5 第①形：出厂默认天数被 `+` 拼进一句用户看得到的话（D-63 那一处就是这个形状）。
 * 只认"紧贴着**非空**字符串字面量的那一次相加"，两处都要有：
 * - 空串（`'' + HORIZON_DEFAULT_DAYS`）是把数字转成文本，不是一句话，放行；
 * - 这样 `horizonLabel(p == null ? HORIZON_DEFAULT_DAYS : …)` 这种"把默认值当输入喂给读数函数"
 *   的合法读者也不会被误伤——它落进的是函数，不是一句话。
 */
const DEFAULT_PASTED = /(['"`])[^'"`]+\1\s*\+\s*HORIZON_DEFAULT_DAYS\b|\bHORIZON_DEFAULT_DAYS\s*\+\s*(['"`])[^'"`]+\2/;

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
 * 扫描主源码，返回 `{ violations, callSites, defaultReads, mouths, defaultPaste, ceiling, defaultDays }`。
 * `callSites` 是给门禁看的水位：有几个地方在调那一道闸；`defaultReads` 是还在读 commons 那份默认值
 * 的行数（D-59 起应为 0）；`mouths` 是离开存储的口子数（H4 白名单里实际被走到的那几个）；
 * `defaultPaste` 是"出厂默认念进了一句话"的行数（H5，D-63 起应为 0）；
 * `ceiling` 是定义处读到的上限，`defaultDays` 是定义处读到的出厂默认天数。
 */
export function auditHorizonCeiling(repo) {
  const violations = [];
  let callSites = 0;
  let defaultReads = 0;
  let defaultPaste = 0;
  let defaultHome = false;
  const mouthSites = new Set();
  let ceiling = -1;
  let defaultDays = -1;
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
          const dflt = code.match(/export const HORIZON_DEFAULT_DAYS:\s*number\s*=\s*(\d+)/);
          if (dflt != null) {
            defaultDays = Number(dflt[1]);
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
        // H4：离开存储的口子只许是白名单里那两个
        if (code.includes(STORE_READ)) {
          mouthSites.add(rel);
          if (MOUTHS.indexOf(rel) < 0) {
            violations.push(rel + ':' + (i + 1) + '：这里绕过白名单直接调 ' + STORE_READ
              + '——收界（horizonFromStore）发生在"刚离开存储的那一刻"，它的覆盖面就等于口子的名单：'
              + '新口子要么走 SettingsStoreParams()，要么自己收界并登记进本文件的白名单（AI·D-59）');
          }
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
        // H5：出厂默认天数念进了一句给用户的话（D-63）
        if (rel !== HOME) {
          if (DEFAULT_PASTED.test(code)) {
            defaultPaste++;
            violations.push(rel + ':' + (i + 1) + '：这里把 ' + DEFAULT_NAME
              + ' 拼进了一句话——界面要念的是**实设**视界（SettingsStoreParams().horizonDays），'
              + '出厂值只是"用户没改过"时恰好相等的那一个；用户改了天数，这句话就替引擎承诺了一个它已经不用的数（AN·D-63）');
          }
          for (const lit of literalsOf(code)) {
            if (lit.startsWith('#')) {
              continue; // 色值：'#120' 是合法的三位缩写色，不是天数
            }
            // 两种形状才判：整串就是那个数（输入框的初值），或"这个数 + 天"在同一句里（一句承诺）。
            // 单靠"串里含 120"会误伤分钟与像素（'共 120 分钟'），那不在这条口径上。
            const standalone = lit.trim() === '' + defaultDays;
            const dayPhrase = new RegExp('(^|[^0-9])' + defaultDays + '([^0-9]|$)').test(lit)
              && lit.includes('天');
            if (defaultDays > 0 && (standalone || dayPhrase)) {
              defaultPaste++;
              violations.push(rel + ':' + (i + 1) + '：字符串里写了 ' + defaultDays
                + '——出厂默认天数只在 ' + HOME + ' 定义一次，界面要么念 ' + DEFAULT_NAME
                + ' 要么念实设值，抄字面量就是第三份（AN·D-63）');
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
  return { violations: violations, callSites: callSites, defaultReads: defaultReads,
    mouths: mouthSites.size, defaultPaste: defaultPaste, ceiling: ceiling, defaultDays: defaultDays };
}

// 直接跑这个文件时打一份清单，供批次盘点与人工核对用。
const self = path.resolve(fileURLToPath(import.meta.url));
if (process.argv[1] && path.resolve(process.argv[1]) === self) {
  const repo = path.resolve(path.dirname(self), '..', '..');
  const r = auditHorizonCeiling(repo);
  console.log('上限 ' + r.ceiling + ' 天／出厂 ' + r.defaultDays + ' 天（定义在 ' + HOME + '），clampHorizonDays 调用 '
    + r.callSites + ' 处，commons 那份默认值的读者 ' + r.defaultReads + ' 处，出厂值念进句子的 '
    + r.defaultPaste + ' 处，离开存储的口子 ' + r.mouths + ' 个（白名单 ' + MOUTHS.length + ' 个），越界抄写 '
    + r.violations.length + ' 处');
  for (const v of r.violations) {
    console.log('  ' + v);
  }
}
