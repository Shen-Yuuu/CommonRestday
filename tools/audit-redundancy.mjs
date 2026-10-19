/** Read-only candidates, NOT an automatic deletion tool. Dynamic/framework/history consumers need review. */
import fs from 'node:fs';
import path from 'node:path';
import { createRequire } from 'node:module';
import { spawnSync } from 'node:child_process';
import { createHash } from 'node:crypto';
const root = path.resolve(import.meta.dirname, '..');
const require = createRequire(import.meta.url);
const ts = require('D:/local/DevEcoStudio/tools/hvigor/hvigor/node_modules/typescript');
const modules = ['entry', 'feature', 'domain', 'data', 'cloud', 'commons'];
const listed = spawnSync('rg', ['--files', ...modules.map(m => `${m}/src/main`), 'AppScope', 'cloud-backend/cloudfunctions',
  '-g', '*.ets', '-g', '*.ts', '-g', '*.json', '-g', '*.json5', '-g', '*.svg', '-g', '*.png', '-g', '*.jpg'],
  { cwd: root, encoding: 'utf8' });
if (listed.status !== 0) throw Error('rg inventory failed');
const files = listed.stdout.trim().split(/\r?\n/).map(p => p.replaceAll('\\', '/'));
const sources = files.filter(p => /\.(ets|ts)$/.test(p));
const resourceConsumers = files.filter(p => /\.(ets|ts|json|json5)$/.test(p));
const sourceText = new Map(resourceConsumers.map(p => [p, fs.readFileSync(path.join(root, p), 'utf8')]));
const imports = [], privateCandidates = [], builderCandidates = [], unusedEntryFiles = [];
for (const file of sources) {
  const text = sourceText.get(file);
  const node = ts.createSourceFile(file, text, ts.ScriptTarget.Latest, true, ts.ScriptKind.TS);
  const words = text.match(/[A-Za-z_$][A-Za-z0-9_$]*/g) ?? [];
  const counts = new Map();
  for (const word of words) counts.set(word, (counts.get(word) ?? 0) + 1);
  for (const statement of node.statements) {
    if (!ts.isImportDeclaration(statement)) continue;
    const clause = statement.importClause;
    if (!clause) continue; // side-effect-only imports are never dead by name count.
    const names = [];
    if (clause.name) names.push(clause.name.text);
    if (clause.namedBindings) {
      if (ts.isNamedImports(clause.namedBindings)) names.push(...clause.namedBindings.elements.map(n => n.name.text));
      else names.push(clause.namedBindings.name.text);
    }
    for (const name of names) if (counts.get(name) === 1) imports.push({ file, name });
  }
  // Counts include quoted Watch callback names and comments: conservative false negatives are intentional.
  for (const match of text.matchAll(/private\s+(?:static\s+)?(?:async\s+)?([A-Za-z_]\w*)\s*(?:[:(])/g)) {
    if (counts.get(match[1]) === 1) privateCandidates.push({ file, name: match[1] });
  }
  for (const match of text.matchAll(/@Builder\s+([A-Za-z_]\w*)\s*\(/g)) {
    if (counts.get(match[1]) === 1) builderCandidates.push({ file, name: match[1] });
  }
  if (file.startsWith('entry/src/main/ets/component/') || file.startsWith('entry/src/main/ets/util/')) {
    const name = path.basename(file, '.ets');
    const consumers = [...sourceText].filter(([other, body]) => other !== file && body.includes(name)).map(([other]) => other);
    if (consumers.length === 0) unusedEntryFiles.push(file);
  }
}
const media = files.filter(p => /\/media\//.test(p) && /\.(png|svg|jpg)$/.test(p));
const mediaCandidates = [];
for (const file of media) {
  const name = path.basename(file, path.extname(file));
  const consumers = [...sourceText].filter(([other, text]) => other !== file &&
    (text.includes(`app.media.${name}`) || text.includes(`$media:${name}`) || text.includes(`"${path.basename(file)}"`)));
  if (!consumers.length) mediaCandidates.push({ file, bytes: fs.statSync(path.join(root, file)).size });
}
const hashedMedia = new Map();
for (const file of media) {
  const hash = createHash('sha256').update(fs.readFileSync(path.join(root, file))).digest('hex');
  if (!hashedMedia.has(hash)) hashedMedia.set(hash, []);
  hashedMedia.get(hash).push(file);
}
const duplicateMedia = [...hashedMedia.values()].filter(group => group.length > 1);
const unusedStrings = [];
for (const file of files.filter(p => /\/resources\/base\/element\/string\.json$/.test(p))) {
  for (const item of JSON.parse(sourceText.get(file)).string ?? []) {
    const referenced = [...sourceText].some(([other, text]) => other !== file && text.includes(`app.string.${item.name}`));
    // Module/ability metadata, other locale files and platform consumers still need manual checking.
    const platform = [...sourceText].some(([other, text]) => other !== file && text.includes(`$string:${item.name}`));
    if (!referenced && !platform) unusedStrings.push({ file, name: item.name });
  }
}
const inventory = spawnSync('rg', ['--files', '--hidden',
  '-g', '!.git/**', '-g', '!.idea/**', '-g', '!.cache/**', '-g', '!.ohpm/**', '-g', '!.hvigor/**', '-g', '!.crdtest/**',
  '-g', '!**/node_modules/**', '-g', '!**/oh_modules/**', '-g', '!**/build/**', '-g', '!tools/test/src/**', '-g', '!tools/test/out/**'],
  { cwd: root, encoding: 'utf8' });
if (inventory.status !== 0) throw Error('project inventory failed');
const projectFiles = inventory.stdout.trim().split(/\r?\n/).map(p => p.replaceAll('\\', '/'));
const groups = { clientMain: 0, server: 0, tests: 0, docs: 0, experiments: 0, tooling: 0, other: 0 };
for (const file of projectFiles) {
  if (/^(?:entry|feature|domain|data|cloud|commons)\/src\/main\//.test(file)) groups.clientMain++;
  else if (/^(?:tools\/test|cloud-backend\/test)\//.test(file) || /\/src\/(?:test|ohosTest)\//.test(file)) groups.tests++;
  else if (file.startsWith('cloud-backend/')) groups.server++;
  else if (file.startsWith('docs/')) groups.docs++;
  else if (file.startsWith('experiments/')) groups.experiments++;
  else if (file.startsWith('tools/')) groups.tooling++;
  else groups.other++;
}
const report = { warning: 'Candidates only; includes comments and excludes generated/dependency files. Inspect routes, dynamic names, public exports, history and tests before deletion.',
  projectInventory: groups,
  sourceFiles: sources.length, packagedMediaFiles: media.length,
  packagedMediaBytes: media.reduce((n, p) => n + fs.statSync(path.join(root, p)).size, 0),
  unusedNamedImports: imports, privateCandidates, builderCandidates, unreferencedEntryFileNames: unusedEntryFiles,
  mediaCandidates, duplicateMedia, unusedStrings };
console.log(JSON.stringify(report, null, 2));
