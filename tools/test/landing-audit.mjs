/**
 * 并发读数落地闸门的离线静态审计（差异文档 D-51 的防回潮判据）。
 *
 * 为什么需要一条断言而不是一次人工修：一次读数从发起到写状态之间隔着 await，而 RDB 与云读数
 * **返回顺序没有保证**。读数触发点从来不止一个（重算广播、下拉刷新、父页 @Prop 变化、翻页/切侧
 * 的点击、写操作本地收尾），所以两次读数必然重叠；先起的那次晚落地就会把界面按回旧结果，
 * 更坏的是它的 catch 分支——旧读数抛错会把新读数的成功念成"没读到"。批次 Z 修的是"节点不重绘"，
 * 这一条修的是"落地顺序反过来"，两者都是同一种用户可见症状（改了不跟着变），但机制不同。
 *
 * 规则三条：
 * - R1：**订阅 `recomputeCount` 的文件必须带闸门**（引用 `LatestLanding` 且 begin / isCurrent 都在），
 *   不在表里就得进豁免表，豁免要写理由。新增一个订阅者却忘了闸门 → 门禁直接红。
 * - R2：**begin 的次数不许多于 isCurrent 的次数**（按文件计），即每次领号都要至少问一次归属；
 *   有人复制了闸门字段却漏掉检查，这一条会逮住。
 * - R3：**`@Prop` 上的 `@Watch` 目标若会跨 await 重读（含一层被调方法），该文件必须带闸门**；
 *   R1 只看广播订阅者，而"父页改入参 → 本页重读"是同一个族的另一半（`DayShiftSheet` 的 owner/epochDay、
 *   `WindowDetailSheet` 的窗口起止都藏在这里）。确实重叠不了的进 EXEMPT_WATCH，理由要写"为什么走不通"。
 *
 * 判不了的情形（不猜，也不冒充覆盖）：
 * - 没有被任何 watcher 触发的读数（例如只在 `aboutToAppear` 读一次的路由页）——单发无重叠，不需要闸门；
 * - 参数会变但**只由按钮点击**触发的页面（PaintMonth 的翻月）：R1、R3 都看不见它，
 *   靠 R2 保证"已经上了闸的文件不许半上"，新页面要人复核；
 * - 跨 await 之后**只写界面态、不写读数**的收尾（五页 `onRefresh` 的 `refreshing = false`）：
 *   这一条只管"旧数据盖新数据"，圈早停一秒不是那一族，而且 `Refresh` 的 `$$` 绑定在一次下拉
 *   结束前不会再起第二次——序列本来组不出来，就别为它上闸门（§8.11 的 D-49 教训）。
 *
 * 违反即由 `tools/test/run.mjs` 判 `landing: FAILED` 并非零退出——不参与"绿"的定义就不算检查。
 */
import fs from 'node:fs';
import path from 'node:path';

/** 只扫 UI 侧：闸门管的是"组件状态落地顺序"，纯逻辑层没有 @State。 */
const TREES = ['entry/src/main/ets'];
/** 重算广播键：订阅它 = 会在别的读数飞行途中再起一次读数。 */
const SUBSCRIBES = "@StorageProp('recomputeCount')";
/** 闸门机制的名字：引用它才算"这一页考虑过落地顺序"。 */
const MECHANISM = 'LatestLanding';
/** 机制本体自己不是使用方——它声明闸门、不领号，别把它算成"空闸门"。 */
const DEFINITION = 'export class ' + MECHANISM;
/**
 * 订阅了广播但确实不需要闸门的文件，值是要能被复核的理由。
 * 加一条之前先读那个 watch 目标——只有"数据写入点全程同步"才配进这里。
 * 注意别把 `onRefresh` 里那句 `await syncOnPull(); this.refreshing = false;` 当成需要闸门的读数：
 * 它 await 之后只落一颗转圈标记、不落任何读数，而且五页（含带闸门的四页）都是同一个形状。
 */
const EXEMPT = {
  'entry/src/main/ets/view/MeView.ets':
    'reload 全程同步（ProfileSettingsService 的 getSync 读数 + 本地配对状态），数据写入点之间没有 await；'
    + '唯一跨 await 的写是 onRefresh 收尾的 refreshing，不携带任何读数'
};
/**
 * R3 的豁免表：@Prop 的 @Watch 目标确实跨 await 重读，但"两次读数重叠"这条路在本 App 里走不通的文件。
 * 理由必须写"为什么组不出这条序列"，不能写"应该没人这么快"。
 */
const EXEMPT_WATCH = {
  'entry/src/main/ets/component/DayShiftSheet.ets':
    'reload 盯的 owner/epochDay 只能由父页给：班表页在点日格时设 sheetDay 并打开半模态，明细页在 editing '
    + '为真时才挂它——两者都在 sheet 关着的时候改，开着时遮罩挡住别的入口，一次飞行里参数不会变',
  'entry/src/main/ets/component/WindowDetailSheet.ets':
    'resetDraft → arrangePastOwnRhythm 自带比序号更严的丢弃条件：落地前比对 timeTouched 与窗口起止逐字'
    + '相等（见该文件 arrangePastOwnRhythm 的 if）。宽屏 inline 详情栏点另一张卡片时 winStart/winEnd 会变，'
    + '旧那次的参数对不上就整批丢掉；同窗口重复点不触发 @Watch（值没变）'
};

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

function count(hay, needle) {
  let n = 0;
  let i = hay.indexOf(needle);
  while (i !== -1) {
    n++;
    i = hay.indexOf(needle, i + needle.length);
  }
  return n;
}

/**
 * 方法体：从定义行（行首允许 private/async/static 修饰）的 `name(` 起按花括号配平取到闭合处。
 * 取不到就返回 null——R3 宁可漏报一个文件，也不靠猜把人家的闸门判没。
 */
function methodBody(src, name) {
  const re = new RegExp('^[ \\t]*(?:(?:private|async|static)[ \\t]+)*' + name + '[ \\t]*\\(', 'm');
  const m = re.exec(src);
  if (m === null) {
    return null;
  }
  const open = src.indexOf('{', m.index + m[0].length - 1);
  if (open < 0) {
    return null;
  }
  let depth = 0;
  for (let p = open; p < src.length; p++) {
    if (src[p] === '{') {
      depth++;
    } else if (src[p] === '}') {
      depth--;
      if (depth === 0) {
        return src.slice(open, p + 1);
      }
    }
  }
  return null;
}

/** 本体里跨 await，或它调用的本文件方法里跨 await，都算"这条 @Watch 会起一次异步读数"。 */
const ASYNC_READ = /(?:^|[^.\w])await[ \t]|\.then\(/;

function rereadsAsync(src, name) {
  const body = methodBody(src, name);
  if (body === null) {
    return false;
  }
  if (ASYNC_READ.test(body)) {
    return true;
  }
  for (const m of body.matchAll(/this\.([A-Za-z_]\w*)[ \t]*\(/g)) {
    if (m[1] === name) {
      continue;
    }
    const called = methodBody(src, m[1]);
    if (called !== null && ASYNC_READ.test(called)) {
      return true;
    }
  }
  return false;
}

export function auditLanding(repo) {
  const violations = [];
  const files = [];
  for (const t of TREES) {
    files.push(...listEts(repo, t));
  }
  for (const rel of files) {
    const src = fs.readFileSync(path.join(repo, rel), 'utf8');
    const subscribed = src.includes(SUBSCRIBES);
    const begin = count(src, '.begin()');
    const check = count(src, 'isCurrent(');
    // R3：@Prop 的 @Watch 起异步重读 = 父页连着改参数时两次读数重叠
    const watched = [];
    for (const m of src.matchAll(/@Prop[^;\n]*@Watch\('(\w+)'\)/g)) {
      if (rereadsAsync(src, m[1]) && watched.indexOf(m[1]) === -1) {
        watched.push(m[1]);
      }
    }
    if (watched.length > 0 && !src.includes(MECHANISM) && EXEMPT_WATCH[rel] === undefined) {
      violations.push(rel + '：@Watch(' + watched.join('/') + ') 挂在 @Prop 上且跨 await 重读，'
        + '却没带落地闸门——父页连着改两次入参时，旧那次晚落地会把界面按回旧参数的那一天/那一侧');
    }
    if (subscribed && !src.includes(MECHANISM)) {
      if (EXEMPT[rel] === undefined) {
        violations.push(rel + '：订阅重算广播却不带落地闸门（'
          + '要么接 LatestLanding，要么在 landing-audit 的 EXEMPT 里写清"这条读数全程同步"的理由）');
      }
      continue;
    }
    if (begin > check) {
      violations.push(rel + '：领号 ' + begin + ' 次、问归属 ' + check
        + ' 次——有读数只 begin 不 isCurrent，旧结果照样会盖掉新的');
    }
    if (src.includes(MECHANISM) && !src.includes(DEFINITION) && begin === 0) {
      violations.push(rel + '：引了 LatestLanding 却一次都没 begin()，闸门是空的');
    }
  }
  for (const rel of Object.keys(EXEMPT).concat(Object.keys(EXEMPT_WATCH))) {
    if (!fs.existsSync(path.join(repo, rel))) {
      violations.push('豁免表指向的文件不存在：' + rel + '（改名或删掉了就把这一格一起删）');
    }
  }
  return violations;
}
