/**
 * 「区间终点怎么念」只写一次的离线静态审计（差异文档 D-58 的防回潮判据，批次 AH）。
 *
 * 为什么这算一条检查而不是"顺手收拾一下"：整零点既是次日的 00:00 也是前一天的 24:00，
 * 两种读法指同一个瞬间，但屏幕上不能同时出现。这条口径 AH 之前抄在三处
 * （`DateLabel.endLabel`、`DateLabel.stamp`、`WindowDetailSheet` 的私有 `edgeDay` + 三元），
 * 另有**七个**终点调用点压根没接它——日详情、周历、共同时间读数各自把 `w.end` 直接喂给裸
 * `DateLabel.hm()`，于是夜班「20:00–24:00」的窗口在这些地方念成「20:00–00:00」，
 * 看着像零长度。X1／AE／AF／AG 四轮修的都是同一族（抄写的口径分家），这一条把它拦在写下来的那一刻。
 *
 * 规则两条，都只认**代码**（注释与文档里的 24:00 是规格说明，不算第二份实现）：
 * - H1：`DateLabel.hm(` 的实参里不许出现名为 `end` / `…End` / `end…` 的标识符（按驼峰与
 *   下划线切词，整词相等才算，所以 `recommend`、`blend` 这类不误伤）。终点要念日期就得走
 *   `DateLabel.edgeTime(min, true)`——它跟 `hm` 的差别只有一个整零点，而那正好是这类读数会错的地方。
 * - H2：字面量 `'24:00'` 只许出现在 `commons/src/main/ets/util/DateLabel.ets`
 *   （`edgeTime` 的定义处）。别处再写一次，就是第三个读者自己认定"午夜该念什么"。
 *
 * 判不了的情形（不猜，也不冒充覆盖）：
 * - 变量名不含 end 却装着终点的调用点（`DateLabel.hm(nextDayZero)` 这一类）。这条拦的是
 *   **照上下文该接却没接**的常见写法，不拦故意绕开命名的写法。
 * - 跨行的实参只按当前行判定；真要跨行喂终点，得先过 H2 那一条（多半会撞见手写的 24:00）。
 * - 不合规又确属必要的行，在**这一行行尾**写 `// end-read-exempt 理由` 放行（独占一行的标记
 *   不顶事：它压不住别处的读数），理由要能被人复核。
 * - 班次定义／课程节次那种 `minToHHmm(st.endMin)` 不在这条的射程内：那是"距 00:00 多少分钟"的
 *   时刻，不是区间的尾巴。它用的是 domain 的 `minToHHmm` 而非 `DateLabel.hm`，所以 H1 天然不碰它，
 *   理由记在差异文档 D-58。
 * - 读数在屏幕上到底念了什么，离线判不出来；由 `entry/src/test/DateLabelTest.ets` 与
 *   `CommonTimeQueryServiceTest.ets` 的两格在离线跑，静态口径只负责"别再抄第二份"。
 */
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { listEts } from './chain-scan.mjs';

/** 定义处：整个仓库只有这里的 24:00 是"规定"，其余都是抄写。 */
const HOME = 'commons/src/main/ets/util/DateLabel.ets';
/** 主源码树：测试与工具脚本允许把 24:00 当字面量断言（那是规格，不是第二份口径）。 */
const TREES = ['domain/src/main/ets', 'feature/src/main/ets', 'data/src/main/ets',
  'commons/src/main/ets', 'entry/src/main/ets', 'cloud/src/main/ets'];
const EXEMPT_MARK = 'end-read-exempt';
const STRING_LITERALS = /(['"`])((?:\\.|(?!\1)[^\\])*)\1/g;
const CALL = 'DateLabel.hm(';
/** 24:00 这一个读数只许出现在定义处。 */
const MIDNIGHT_TEXT = '24:00';

/** 注释（`//` 与块注释的 `*` 续行）不参与判定：D-58 的说明本身就得写清 24:00 长什么样。 */
function codeOf(line) {
  const t = line.trim();
  if (t.startsWith('*') || t.startsWith('//') || t.startsWith('/*')) {
    return '';
  }
  const i = line.indexOf('//');
  return i >= 0 ? line.slice(0, i) : line;
}

/**
 * 取 `open` 处左括号之后的实参文本（配平到 depth 0；行内不闭合就吃到行尾）。
 * 只有这一种取值方式够用：全仓 `DateLabel.hm(` 都是单行调用。
 */
function argsOf(code, open) {
  let depth = 0;
  for (let i = open; i < code.length; i++) {
    const c = code[i];
    if (c === '(') {
      depth++;
    } else if (c === ')') {
      depth--;
      if (depth === 0) {
        return code.slice(open + 1, i);
      }
    }
  }
  return code.slice(open + 1);
}

/**
 * 实参里有没有"终点"这个词：先按下划线/非字母数字切，再把驼峰拆开，比整词相等。
 * `w.end` → [w, end] 命中；`winEnd` → [win, End] 命中；`recommend` → [recommend] 不命中。
 */
function mentionsEnd(args) {
  for (const word of args.split(/[^A-Za-z0-9_]+/)) {
    for (const token of word.split(/(?<=[a-z0-9])(?=[A-Z])/)) {
      if (token.toLowerCase() === 'end') {
        return true;
      }
    }
  }
  return false;
}

function literalsOf(code) {
  const out = [];
  for (const m of code.matchAll(STRING_LITERALS)) {
    out.push(m[2]);
  }
  return out;
}

/**
 * 扫描主源码，返回 `{ violations, callSites, edgeSites, exempt }`。
 * 后三个水位是给门禁看的：裸 `hm` 还剩几处（都该是起点或纯时刻），`edgeTime` 接上了几处，
 * 又写明理由豁免了几处。
 */
export function auditEndRead(repo) {
  const violations = [];
  let callSites = 0;
  let edgeSites = 0;
  let exempt = 0;
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
        if (code.includes('DateLabel.edgeTime(')) {
          edgeSites++;
        }
        let at = code.indexOf(CALL);
        while (at >= 0) {
          callSites++;
          // H1：终点被喂给了只认时刻的格式化函数（定义处自己的内部调用除外）
          if (rel !== HOME && mentionsEnd(argsOf(code, at + CALL.length - 1))) {
            violations.push(rel + ':' + (i + 1) + '：这里把区间的尾巴喂给了 DateLabel.hm——'
              + '整零点会被念成 00:00，终点请走 DateLabel.edgeTime(min, true)（AH·D-58）');
          }
          at = code.indexOf(CALL, at + CALL.length);
        }
        // H2：别处又写了一遍那个读数
        if (rel !== HOME) {
          for (const lit of literalsOf(code)) {
            if (lit.includes(MIDNIGHT_TEXT)) {
              violations.push(rel + ':' + (i + 1) + '：字符串里写了 ' + MIDNIGHT_TEXT
                + '——午夜终点只在 ' + HOME + ' 的 edgeTime 里定一次，抄字面量就会跟它分家（AH·D-58）');
            }
          }
        }
      }
    }
  }
  if (edgeSites === 0) {
    violations.push(HOME + '：读不到 edgeTime 的调用——这条口径判不了，别把它当成绿');
  }
  return { violations: violations, callSites: callSites, edgeSites: edgeSites, exempt: exempt };
}

// 直接跑这个文件时打一份清单，供批次盘点与人工核对用。
const self = path.resolve(fileURLToPath(import.meta.url));
if (process.argv[1] && path.resolve(process.argv[1]) === self) {
  const repo = path.resolve(path.dirname(self), '..', '..');
  const r = auditEndRead(repo);
  console.log('裸 DateLabel.hm ' + r.callSites + ' 处，edgeTime ' + r.edgeSites + ' 处，'
    + '写明理由豁免 ' + r.exempt + ' 处，终点误读/抄写 ' + r.violations.length + ' 处');
  for (const v of r.violations) {
    console.log('  ' + v);
  }
}
