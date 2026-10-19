/**
 * 免设备的云对象契约回归。只替换 CloudDB 存储口，不替换 pairing/contract 的业务逻辑。
 * 运行：node cloud-backend/test/pairing-contract.mjs
 */
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { createRequire } from 'node:module';
import { dirname, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

const require = createRequire(import.meta.url);
const repo = resolve(dirname(fileURLToPath(import.meta.url)), '../..');
const compiler = require(resolve(repo, '../CloudDevSpikeOfficial/CloudProgram/node_modules/typescript'));
const cloudDir = resolve(repo, 'cloud-backend/cloudfunctions/pairing');
const rows = new Map();

function modelRow(row) {
  return new Proxy({}, {
    get(_target, property) {
      if (typeof property === 'string' && property.startsWith('get')) {
        const name = property.charAt(3).toLowerCase() + property.slice(4);
        return () => row[name];
      }
      return undefined;
    }
  });
}

function collection(model) {
  const name = model.name;
  if (!rows.has(name)) rows.set(name, []);
  const table = rows.get(name);
  return {
    query() {
      const filters = [];
      const query = {
        equalTo(field, value) { filters.push([field, value]); return query; },
        async get() {
          return table.filter(row => filters.every(([field, value]) => row[field] === value)).map(modelRow);
        }
      };
      return query;
    },
    async upsert(row) {
      const key = row.pairId;
      const index = table.findIndex(item => item.pairId === key);
      if (index >= 0) table[index] = { ...row };
      else table.push({ ...row });
      return 1;
    },
    async delete(selected) {
      for (const item of selected) {
        const key = item.getPairId();
        const index = table.findIndex(row => row.pairId === key);
        if (index >= 0) table.splice(index, 1);
      }
      return selected.length;
    }
  };
}

const sdk = {
  cloud: { createInstance: () => ({ database: () => ({ collection }) }) },
  Region: { REGION_CN: 'CN' }
};

function loadTypeScript(file, imports) {
  const source = readFileSync(resolve(cloudDir, file), 'utf8');
  const js = compiler.transpileModule(source, {
    compilerOptions: { module: compiler.ModuleKind.CommonJS, target: compiler.ScriptTarget.ES2020 }
  }).outputText;
  const module = { exports: {} };
  const localRequire = name => name === '@hw-agconnect/cloud-server' ? sdk
    : name in imports ? imports[name] : require(name);
  new Function('require', 'module', 'exports', js)(localRequire, module, module.exports);
  return module.exports;
}

const contract = loadTypeScript('contract.ts', {
  './PairSession': require(resolve(cloudDir, 'PairSession.js')),
  './PairSnapshot': require(resolve(cloudDir, 'PairSnapshot.js'))
});
const { Pairing } = loadTypeScript('pairing.ts', { './contract': contract });
const pairing = new Pairing();
const creator = 'aabbccdd-0000-0000-0000-000000000001';
const joiner = 'aabbccdd-0000-0000-0000-000000000002';
const publicKey = 'AQIDBA==';

const created = await pairing.create(creator, publicKey, contract.SCHEMA_VERSION);
assert.equal(created.code, 'OK');
assert.match(created.inviteCode, /^\d{6}$/);
assert.match(created.confirmToken, /^[A-Za-z0-9_-]{32}$/);
assert.equal(created.status, 'WAITING');

const before = await pairing.status(created.pairId, creator);
assert.equal(before.status, 'WAITING');
assert.equal(Object.hasOwn(before, 'confirmToken'), false);
assert.equal(Object.hasOwn(before, 'inviteCode'), false);

const joined = await pairing.join(created.inviteCode, joiner, publicKey, contract.SCHEMA_VERSION);
assert.equal(joined.code, 'OK');
assert.equal(joined.status, 'PENDING_CONFIRM');
assert.equal(Object.hasOwn(joined, 'confirmToken'), false);
assert.equal(Object.hasOwn(joined, 'inviteCode'), false);
const replay = await pairing.join(created.inviteCode, joiner, publicKey, contract.SCHEMA_VERSION);
assert.equal(Object.hasOwn(replay, 'confirmToken'), false);

const pending = await pairing.status(created.pairId, joiner);
assert.equal(pending.status, 'PENDING_CONFIRM');
assert.equal(Object.hasOwn(pending, 'confirmToken'), false);
assert.equal((await pairing.confirm(created.pairId, joiner, created.confirmToken)).code, 'FORBIDDEN');
assert.equal((await pairing.confirm(created.pairId, creator, 'wrong')).code, 'FORBIDDEN');

const confirmed = await pairing.confirm(created.pairId, creator, created.confirmToken);
assert.equal(confirmed.code, 'OK');
assert.equal(confirmed.status, 'ACTIVE');
assert.equal(Object.hasOwn(confirmed, 'confirmToken'), false);
assert.equal((await pairing.status(created.pairId, joiner)).status, 'ACTIVE');
assert.equal(rows.get('PairSession')[0].confirmToken, '');
process.stdout.write('pairing contract: PASS (create-only proof, join/status hidden, inviter-only confirmation)\n');
