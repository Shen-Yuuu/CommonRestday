/**
 * 字号与关怀模式状态链的离线静态审计（批次 O·长辈模式 A 的防回潮判据）。
 *
 * 立这条审计的原因很具体：用户否掉了"135 处令牌字号已调整"这种交付口径——**报数不等于审完**。
 * 令牌那一半确实已经由编译器保证（`DesignTokens.fontXxx` 是方法，漏传 senior 就编不过），
 * 但 186 处裸数字 `fontSize(13)` 不会报错，只会在长辈模式下悄悄保持原尺寸。
 * 所以这里做三件编译器做不到的事：
 *
 * 1. **裸数字只减不增**：逐文件比对 `tools/verify-baseline.json` 的 `fontNumeric` 台账。
 *    新增一处裸数字、或某文件审完后台账没跟着下调，都判违规——前者防回潮，后者防"改了没记"。
 * 2. **senior 不许当值传进 `@Builder`**：D-24 那一族的老坑（值传参的 @Builder 不随状态重渲染）。
 *    关怀模式要生效的写法只有一个：在属性表达式里读组件自己的 `this.senior` 成员。
 * 3. **AppStorage 键字面量不得漂移**：装饰器实参只能是字面量，所以 22 处组件都手写
 *    `'crd_senior_mode'`。哪天 `SENIOR_MODE_KEY` 改了名而组件没改，订阅会静默失效（不报错、不闪退，
 *    只是长辈模式再也不起作用）——这条唯一能廉价地把它钉住。
 *
 * 不判的情形：某个具体位置该不该跳档是设计判断，归差异文档与设备取证，静态规则只保证"没有漏网的裸数字"。
 */
import fs from 'node:fs';
import path from 'node:path';

/** 随包源码面：与 a11y-audit 的 TREES 同一批目录。 */
const TREES = ['entry/src/main', 'feature/src/main', 'data/src/main', 'cloud/src/main',
  'commons/src/main', 'domain/src/main'];

/** 各有一条硬理由、不参与本轮字号审计的文件。 */
const EXCLUDED = new Map([
  // 用户未提交的 WIP 页：本仓约定永不提交，也不由本批次替用户改它的排版。
  ['entry/src/main/ets/pages/PaintMonth.ets', '用户 WIP 文件，不由本批次改动'],
  // FormExtension 跑在独立进程，UIAbility 写的 AppStorage 到不了这里，订阅 senior 只会读到默认 false。
  ['entry/src/main/ets/widget/RestCard2x2.ets', '卡片进程收不到 AppStorage'],
]);

/** 裸数字字号：`fontSize(13)`、`fontSize(13.5)`。带引号或单位的（'13fp'）不在本仓写法里，不算。 */
const NUMERIC = /\.fontSize\(\s*\d+(?:\.\d+)?\s*\)/g;
/**
 * 装饰器里手写的 AppStorage 键。只认装饰器形参这一处：`'crd_settings'` 这类同名前缀的
 * Preferences 存储名不是键，把它一起判会误伤（第一次跑就撞上了）。
 */
const STORAGE_KEY = /@Storage(?:Prop|Link|Get|Set|Consume)?\s*\(\s*'(crd_[a-z_]+)'/g;
/** 键的权威定义处：只认这两个文件里的 `export const XXX_KEY: string = 'crd_…'`。 */
const KEY_DECL = /export const ([A-Z][A-Z0-9_]*_KEY): string = '(crd_[a-z_]+)'/g;
const KEY_DECL_FILES = ['entry/src/main/ets/accessibility/AccessibilityPolicy.ets',
  'entry/src/main/ets/theme/DesignTokens.ets'];

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
 * 取 `@Builder` 后面的那个函数签名里的参数表。
 * 声明有两种写法（`@Builder\n  name(a, b) {` 与 `@Builder name(a, b) {`），所以从 @Builder 起
 * 往后找第一个 '(' 到与之配对的 ')'；找不到就不判，不猜。
 */
function builderParams(text, from) {
  const open = text.indexOf('(', from);
  if (open < 0) {
    return null;
  }
  const close = text.indexOf(')', open);
  if (close < 0) {
    return null;
  }
  return text.slice(open + 1, close);
}

function scanBuilderArgs(rel, src, violations) {
  let at = src.indexOf('@Builder');
  while (at >= 0) {
    const params = builderParams(src, at);
    if (params !== null && /\bsenior\b/.test(params)) {
      const line = src.slice(0, at).split(/\r?\n/).length;
      violations.push(rel + ':' + line + ' 把 senior 当参数传进了 @Builder（D-24：值传参的 Builder 不随状态重渲染，'
        + '关怀模式会失效；改成在 Builder 体内读 this.senior）');
    }
    at = src.indexOf('@Builder', at + 1);
  }
}

function scanStorageKeys(rel, src, legalKeys, violations) {
  for (const m of src.matchAll(STORAGE_KEY)) {
    const key = m[1];
    if (!legalKeys.has(key)) {
      const line = src.slice(0, m.index).split(/\r?\n/).length;
      violations.push(rel + ':' + line + ' 的 @StorageProp 用了没有权威定义的 AppStorage 键 \'' + key
        + '\'（权威定义只有 ' + KEY_DECL_FILES.join(' / ') + ' 里的 *_KEY 常量）');
    }
  }
}

/** @returns 违规说明清单，空数组即通过。 */
export function auditFonts(repo) {
  const violations = [];
  const baselinePath = path.join(repo, 'tools', 'verify-baseline.json');
  let baseline = null;
  try {
    baseline = JSON.parse(fs.readFileSync(baselinePath, 'utf8'));
  } catch (e) {
    violations.push('读不到 tools/verify-baseline.json（' + e.message + '），字号台账无法比对');
  }
  const ledger = (baseline && baseline.fontNumeric) || {};

  const legalKeys = new Set();
  for (const rel of KEY_DECL_FILES) {
    const abs = path.join(repo, rel);
    if (!fs.existsSync(abs)) {
      violations.push(rel + ' 读不到，AppStorage 键的权威定义无法核对');
      continue;
    }
    for (const m of fs.readFileSync(abs, 'utf8').matchAll(KEY_DECL)) {
      legalKeys.add(m[2]);
    }
  }

  const seen = new Set();
  for (const tree of TREES) {
    for (const rel of listEts(repo, tree)) {
      if (EXCLUDED.has(rel)) {
        continue;
      }
      seen.add(rel);
      const src = fs.readFileSync(path.join(repo, rel), 'utf8');
      const hits = (src.match(NUMERIC) || []).length;
      const allowed = ledger[rel] || 0;
      if (hits > allowed) {
        violations.push(rel + ' 有 ' + hits + ' 处裸数字 fontSize，台账上限 ' + allowed
          + '（新增裸数字要接进 DesignTokens 的字号档；确有理由保留要在差异文档里写明并回填台账）');
      } else if (hits < allowed) {
        violations.push(rel + ' 只剩 ' + hits + ' 处裸数字 fontSize，台账还记着 ' + allowed
          + '（审完要当场下调 tools/verify-baseline.json，不留"改了没记"的余数）');
      }
      scanBuilderArgs(rel, src, violations);
      scanStorageKeys(rel, src, legalKeys, violations);
    }
  }
  for (const rel of Object.keys(ledger)) {
    if (!seen.has(rel) && !EXCLUDED.has(rel)) {
      violations.push('台账里的 ' + rel + ' 已经不存在或不在审计面上，条目要删除');
    }
  }
  return violations;
}
