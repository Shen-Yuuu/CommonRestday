/**
 * 隐私政策与提示文案的离线口径审计（最终验收 R1 / R2 的复验判据）。
 *
 * 为什么放在这里而不是写成 .ets 用例：这些文字分属资源文件、组件源码与文档，`entry/src/main` 与
 * `docs/` 都不参与离线转译，Hypium 用例够不着它们。而验收报告点名的正是"同一句话在几个地方
 * 各说一遍、然后互相漂移"。所以这里用纯 Node 做逐字比对：
 *
 * 1. 应用内全文（`string.json` 的 `pp_*`，节序取自 `PrivacyPolicySheet.ets` 的书写顺序）与
 *    `docs/legal/privacy-policy.md`、`privacy-policy.html` **逐节逐字相同、顺序相同**
 *    （唯一豁免见 HTML_BODY_EXEMPT）；
 * 2. 首启摘要（`privacy_point_*`，顺序取自 `PrivacyDialog.ets`）与两份文档里的摘要清单逐字相同；
 * 3. 全文与摘要里不许出现"数据绝不离开这台设备"这类绝对化承诺（R1）；
 * 4. 系统备份/换机迁移的披露必须同时出现在三处全文里（R1 的落地判据）；
 * 5. 同一批禁令覆盖**全部随包源码**里出现的绝对化表述（`CLAIM_TREES`）——政策改了而界面上
 *    那句口号没改，用户读到的还是同一句假话（R1 的界面侧）；
 * 6. `clearAllMessageOf` 里不许再出现"稍后重试"，且 `cleanupMessageOf` 必须还有（R2：
 *    清库后重试凭据已随本机记录一起删掉，取消/改期那条路径则留着句柄）。
 *
 * 违反即由调用方（`tools/test/run.mjs`）非零退出，不参与"绿"的定义就不算检查。
 */
import fs from 'node:fs';
import path from 'node:path';

/** 绝对化表述：出现即判违规（R1）。 */
const FORBIDDEN = [
  '只存在这台手机', '仅存在这台手机', '不会离开这台手机', '不会离开这台设备',
  '绝不离开', '永远不会离开', '只在你的设备上', '仅存储在本机数据库'
];
/**
 * 随包出厂的源码面。R1 的教训是"政策改了、界面上那句口号还在原地"，所以绝对化表述的禁令
 * 不只管《隐私政策》本身，也管任何会显示给用户看的字符串。`docs/` 不在其中——验收报告与
 * 整改记录要**引用**旧措辞，那是记录不是承诺。
 */
const CLAIM_TREES = ['entry/src/main', 'feature/src/main', 'data/src/main', 'cloud/src/main',
  'commons/src/main', 'domain/src/main'];
/** 备份/换机披露必须在这三处全文都出现的关键字（两句都要有）。 */
const DISCLOSE = ['备份', '换机'];
/**
 * 托管页允许与应用内不一致的唯一一节：在线版要把"在线版地址/联系方式"就地写出来，
 * 而应用内那一节只能指向提审材料。豁免只允许这一节，且必须在这一行说明理由。
 */
const HTML_BODY_EXEMPT = new Set(['pp_version_b']);

const read = (repo, rel) => fs.readFileSync(path.join(repo, rel), 'utf8');

function readStrings(repo) {
  const raw = JSON.parse(read(repo, 'entry/src/main/resources/base/element/string.json'));
  const map = new Map();
  for (const item of raw.string) {
    map.set(item.name, item.value);
  }
  return map;
}

/** 从组件源码里按出现顺序抽出资源名——渲染顺序即口径顺序，不在脚本里重述一遍清单。 */
function resourceNames(repo, relFile, pattern) {
  const src = read(repo, relFile);
  const out = [];
  const re = new RegExp(pattern, 'g');
  let m = re.exec(src);
  while (m !== null) {
    out.push(m[1]);
    m = re.exec(src);
  }
  return out;
}

function markdownSections(repo) {
  const src = read(repo, 'docs/legal/privacy-policy.md');
  const re = /^### (.+)\r?\n\r?\n(.+)\r?$/gm;
  const out = [];
  let m = re.exec(src);
  while (m !== null) {
    out.push({ title: m[1].trim(), body: m[2].trim() });
    m = re.exec(src);
  }
  return out;
}

function markdownSummary(repo) {
  const lines = read(repo, 'docs/legal/privacy-policy.md').split(/\r?\n/);
  const start = lines.findIndex((l) => l.startsWith('## 商店与首启共用摘要'));
  if (start < 0) {
    return [];
  }
  const out = [];
  for (let i = start + 1; i < lines.length && !lines[i].startsWith('## '); i += 1) {
    if (lines[i].startsWith('- ')) {
      out.push(lines[i].slice(2).trim());
    }
  }
  return out;
}

function htmlSections(repo) {
  const src = read(repo, 'docs/legal/privacy-policy.html');
  const re = /<h2>(.*?)<\/h2><p>(.*?)<\/p>/g;
  const out = [];
  let m = re.exec(src);
  while (m !== null) {
    out.push({ title: m[1], body: m[2] });
    m = re.exec(src);
  }
  return out;
}

function htmlSummary(repo) {
  const src = read(repo, 'docs/legal/privacy-policy.html');
  const at = src.indexOf('<h2>要点摘要</h2>');
  if (at < 0) {
    return [];
  }
  const block = src.slice(at, src.indexOf('</section>', at));
  const out = [];
  const re = /<li>(.*?)<\/li>/g;
  let m = re.exec(block);
  while (m !== null) {
    out.push(m[1]);
    m = re.exec(block);
  }
  return out;
}

/** 递归列出随包源码里的 .ets / .json（相对路径，正斜杠）。 */
function listSource(repo, relDir) {
  const abs = path.join(repo, relDir);
  if (!fs.existsSync(abs)) {
    return [];
  }
  const out = [];
  for (const ent of fs.readdirSync(abs, { withFileTypes: true })) {
    const childRel = path.posix.join(relDir, ent.name);
    if (ent.isDirectory()) {
      out.push(...listSource(repo, childRel));
    } else if (/\.(ets|json)$/.test(ent.name)) {
      out.push(childRel);
    }
  }
  return out;
}

/** 只取某个 export 函数体（到下一个顶层 export 为止），用于静态钉住一句用户可见文案。 */
function functionSlice(src, exportedName) {
  const at = src.indexOf('export function ' + exportedName);
  if (at < 0) {
    return null;
  }
  const next = src.indexOf('\nexport ', at + 1);
  return next < 0 ? src.slice(at) : src.slice(at, next);
}

function describeDiff(label, expected, actual, out) {
  if (expected === actual) {
    return;
  }
  if (actual === undefined) {
    out.push(label + ' 缺失');
    return;
  }
  let i = 0;
  while (i < expected.length && i < actual.length && expected[i] === actual[i]) {
    i += 1;
  }
  out.push(label + ' 与「' + expected + '」不一致：第 ' + (i + 1) + ' 字起为「'
    + actual.slice(Math.max(0, i - 8), i + 24) + '…」');
}

/** @returns 违规说明清单，空数组即通过。 */
export function auditPrivacyCopy(repo) {
  const violations = [];
  const strings = readStrings(repo);
  const textOf = (name) => (strings.has(name) ? strings.get(name) : undefined);

  const sheetKeys = resourceNames(repo, 'entry/src/main/ets/component/PrivacyPolicySheet.ets',
    /app\.string\.(pp_[a-z]+)_[tb]'\)/g);
  const pairs = [];
  for (let i = 0; i < sheetKeys.length; i += 1) {
    const key = sheetKeys[i];
    if (pairs[pairs.length - 1] !== key) {
      pairs.push(key);
    }
  }
  const md = markdownSections(repo);
  const html = htmlSections(repo);
  if (pairs.length === 0) {
    violations.push('PrivacyPolicySheet 没抽到 pp_* 分节（组件改名了？审计要跟着改）');
  }
  if (md.length !== pairs.length) {
    violations.push('privacy-policy.md 分节数 ' + md.length + ' ≠ 应用内 ' + pairs.length);
  }
  if (html.length !== pairs.length) {
    violations.push('privacy-policy.html 分节数 ' + html.length + ' ≠ 应用内 ' + pairs.length);
  }
  const n = Math.min(pairs.length, md.length, html.length);
  for (let i = 0; i < n; i += 1) {
    const key = pairs[i];
    describeDiff('md 第 ' + (i + 1) + ' 节标题（' + key + '_t）', textOf(key + '_t'), md[i].title, violations);
    describeDiff('md 第 ' + (i + 1) + ' 节正文（' + key + '_b）', textOf(key + '_b'), md[i].body, violations);
    describeDiff('html 第 ' + (i + 1) + ' 节标题（' + key + '_t）', textOf(key + '_t'), html[i].title, violations);
    if (!HTML_BODY_EXEMPT.has(key + '_b')) {
      describeDiff('html 第 ' + (i + 1) + ' 节正文（' + key + '_b）', textOf(key + '_b'), html[i].body, violations);
    }
  }

  const pointNames = resourceNames(repo, 'entry/src/main/ets/component/PrivacyDialog.ets',
    /app\.string\.(privacy_point_[a-z]+)'\)/g);
  const points = pointNames.map(textOf);
  const mdSum = markdownSummary(repo);
  const htmlSum = htmlSummary(repo);
  if (mdSum.length !== points.length || htmlSum.length !== points.length) {
    violations.push('首启摘要条数不一致：应用内 ' + points.length + ' / md ' + mdSum.length
      + ' / html ' + htmlSum.length);
  }
  for (let i = 0; i < Math.min(points.length, mdSum.length); i += 1) {
    describeDiff('md 摘要第 ' + (i + 1) + ' 条（' + pointNames[i] + '）', points[i], mdSum[i], violations);
  }
  for (let i = 0; i < Math.min(points.length, htmlSum.length); i += 1) {
    describeDiff('html 摘要第 ' + (i + 1) + ' 条（' + pointNames[i] + '）', points[i], htmlSum[i], violations);
  }

  // R1：不许出现绝对化的"数据绝不离开这台设备"，且备份/换机披露必须四处都在。
  const corpus = [
    ['string.json', points.concat(pairs.map((k) => textOf(k + '_b'))).join('\n')],
    ['privacy-policy.md', md.map((s) => s.title + s.body).join('\n') + '\n' + mdSum.join('\n')],
    ['privacy-policy.html', html.map((s) => s.title + s.body).join('\n') + '\n' + htmlSum.join('\n')],
    ['首启摘要', points.join('\n')]
  ];
  for (const [label, text] of corpus) {
    for (const word of FORBIDDEN) {
      if (text.indexOf(word) >= 0) {
        violations.push(label + ' 仍含绝对化表述「' + word + '」（最终验收 R1）');
      }
    }
  }
  for (const [label, text] of corpus.slice(0, 3)) {
    for (const word of DISCLOSE) {
      if (text.indexOf(word) < 0) {
        violations.push(label + ' 缺少「' + word + '」相关披露（最终验收 R1）');
      }
    }
  }

  // R1 的界面侧：政策改口了，界面上那句口号也得跟着改，所以禁令覆盖全部随包源码。
  for (const tree of CLAIM_TREES) {
    for (const rel of listSource(repo, tree)) {
      if (rel === 'entry/src/main/resources/base/element/string.json') {
        continue; // 这一份上面已按节逐字检查，一条违规只报一次
      }
      const text = read(repo, rel);
      for (const word of FORBIDDEN) {
        if (text.indexOf(word) >= 0) {
          violations.push(rel + ' 含绝对化表述「' + word + '」（最终验收 R1：界面与政策同一口径）');
        }
      }
    }
  }

  // R2：清空之后的那句话不许再承诺可稍后重试；取消/改期那句保持原样。
  const flow = read(repo, 'feature/src/main/ets/model/PlanFlow.ets');
  const clearAll = functionSlice(flow, 'clearAllMessageOf');
  if (clearAll === null) {
    violations.push('PlanFlow.ets 里找不到 clearAllMessageOf');
  } else if (clearAll.indexOf('稍后重试') >= 0) {
    violations.push('clearAllMessageOf 仍出现「稍后重试」：清库后已无重试凭据（最终验收 R2）');
  }
  const cancel = functionSlice(flow, 'cleanupMessageOf');
  if (cancel === null || cancel.indexOf('稍后重试') < 0) {
    violations.push('cleanupMessageOf 的「稍后重试」被改掉了：取消/改期仍留着句柄，那句话是可兑现的');
  }
  return violations;
}
