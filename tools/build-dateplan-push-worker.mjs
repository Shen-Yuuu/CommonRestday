/** Local build only. No AGC login, deployment, live request, secret or simulator operation. */
import fs from 'node:fs';
import path from 'node:path';
import { createRequire } from 'node:module';
import { fileURLToPath } from 'node:url';
import { spawnSync } from 'node:child_process';

const repo = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const source = path.join(repo, 'cloud-backend/cloudfunctions/dateplan');
const wake = process.argv.includes('--wake');
const name = wake ? 'dateplanwake' : 'dateplanpush';
const output = path.resolve(repo, '../.crdtest/' + name);
const archive = path.resolve(repo, '../.crdtest/' + name + '.zip');
const require = createRequire(import.meta.url);
const ts = require('D:/local/DevEcoStudio/tools/hvigor/hvigor/node_modules/typescript');
const dependencies = path.resolve(repo, '../CloudDevSpikeOfficial/CloudProgram/cloudfunctions/dateplan/node_modules');
if (!fs.existsSync(path.join(dependencies, '@hw-agconnect/cloud-server'))) throw new Error('Dateplan Server SDK dependencies missing');
// Output is exclusively a generated build tree; never recursively remove or relocate a project checkout.
if (path.dirname(output) !== path.resolve(repo, '../.crdtest')) throw new Error('Unsafe build output');
fs.mkdirSync(output, { recursive: true });
const entries = ['identity', 'protocol', 'storage-v2', 'push-account', 'push', wake ? 'wake' : 'dispatch'];
for (const file of entries) {
  const result = ts.transpileModule(fs.readFileSync(path.join(source, file + '.ts'), 'utf8'), {
    compilerOptions: { target: ts.ScriptTarget.ES2020, module: ts.ModuleKind.CommonJS, strict: true } });
  fs.writeFileSync(path.join(output, file + '.js'), result.outputText);
}
fs.copyFileSync(path.join(source, 'models.js'), path.join(output, 'models.js'));
fs.copyFileSync(path.join(source, 'additional-models.js'), path.join(output, 'additional-models.js'));
fs.writeFileSync(path.join(output, 'package.json'), JSON.stringify({ name: 'fortwo-' + name, version: '0.2.0',
  private: true, dependencies: { '@hw-agconnect/cloud-server': '1.0.5' } }, null, 2));
fs.cpSync(dependencies, path.join(output, 'node_modules'), { recursive: true });
const packed = spawnSync('powershell.exe', ['-NoProfile', '-NonInteractive', '-Command',
  'Compress-Archive -LiteralPath ' + entries.map(n => n + '.js').concat(['models.js', 'additional-models.js', 'package.json', 'node_modules'])
    .map(n => "'" + path.join(output, n).replace(/'/g, "''") + "'").join(',')
    + " -DestinationPath '" + archive.replace(/'/g, "''") + "' -Force"], { encoding: 'utf8' });
if (packed.status !== 0) throw new Error('Push worker archive failed: ' + packed.stderr);
console.log('Worker ZIP: ' + archive);
console.log(wake ? 'AGC entry: wake.handler; DATABASE trigger on PairPlanWake/onUpsert only; automatic INSERT trigger must be verified before opt-in.'
  : 'AGC entry: dispatch.handler; TIMER only, no HTTP/API gateway trigger.');
console.log('Node.js 20; configure FORTWO_PLAN_DISPATCH_SECRET on server only (same across dateplan and workers).');
console.log('No secrets included. Configure the same project/zone/shared-plan/Push environment variables in AGC.');
