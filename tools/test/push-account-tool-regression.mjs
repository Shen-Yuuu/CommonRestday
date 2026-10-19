import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { generateKeyPairSync, createHash } from 'node:crypto';
import { spawnSync } from 'node:child_process';

const repo = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '../..');
const script = path.join(repo, 'tools/prepare-push-account.ps1');
const work = fs.mkdtempSync(path.join(os.tmpdir(), 'fortwo-push-fixture-'));
const fixture = path.join(work, 'synthetic-account.json');
const bad = path.join(work, 'synthetic-invalid.json');
const privateKey = generateKeyPairSync('rsa', { modulusLength: 2048 }).privateKey
  .export({ format: 'pem', type: 'pkcs8' }).toString();
fs.writeFileSync(fixture, JSON.stringify({ project_id: '123', key_id: 'synthetic-kid',
  private_key: privateKey, sub_account: 'synthetic-sub', unrelated: 'ignored-metadata' }));
fs.writeFileSync(bad, '{"private_key":"sensitive-invalid-fixture"}');
const quote = value => "'" + value.replaceAll("'", "''") + "'";
function run(code) {
  const command = "$ErrorActionPreference='Stop'; function Set-Clipboard { param($Value) $global:fixtureClipboard = [string]$Value }; " + code;
  // Stub clipboard in this isolated process; do not read or modify the user's clipboard.
  return spawnSync('powershell.exe', ['-NoProfile', '-NonInteractive', '-EncodedCommand',
    Buffer.from(command, 'utf16le').toString('base64')], { encoding: 'utf8' });
}
let passed = 0;
function test(name, action) { action(); passed++; console.log('PASS ' + name); }
const invoke = '& ' + quote(script) + ' -Path ' + quote(fixture);
try {
  test('default output contains only variable names and lengths', () => {
    const result = run(invoke);
    assert.equal(result.status, 0); assert.match(result.stdout, /FORTWO_PUSH_SERVICE_ACCOUNT_PARTS/);
    for (const secret of ['BEGIN PRIVATE KEY', 'synthetic-kid', 'synthetic-sub', 'ignored-metadata']) {
      assert.ok(!result.stdout.includes(secret)); assert.ok(!result.stderr.includes(secret));
    }
  });
  test('environment mode reconstructs the key exactly within the fragment limit', () => {
    const result = run(invoke + ' -CopyEnvironmentJson; ' +
      "$map = $global:fixtureClipboard | ConvertFrom-Json; $n = [int]$map.FORTWO_PUSH_SERVICE_ACCOUNT_PARTS; " +
      "$joined = ''; for ($i=1; $i -le $n; $i++) { $part = $map.('FORTWO_PUSH_SERVICE_ACCOUNT_' + $i); " +
      "if ($part.Length -gt 512 -or $part.Length -lt 1) { throw 'bad-length' }; $joined += $part }; " +
      "$account = $joined | ConvertFrom-Json; if ($account.PSObject.Properties.Name -contains 'unrelated') { throw 'extra-field' }; " +
      "$hash = [System.Security.Cryptography.SHA256]::Create(); Write-Output ('FixtureHash:' + " +
      "[BitConverter]::ToString($hash.ComputeHash([Text.Encoding]::UTF8.GetBytes($account.private_key))).Replace('-','').ToLower());");
    assert.equal(result.status, 0);
    assert.ok(result.stdout.includes('FixtureHash:' + createHash('sha256').update(privateKey).digest('hex')));
    assert.ok(!result.stdout.includes('BEGIN PRIVATE KEY'));
  });
  test('part clipboard mode matches environment mode, including count', () => {
    const result = run(invoke + ' -PartLength 256 -CopyEnvironmentJson; ' +
      '$expected = $global:fixtureClipboard | ConvertFrom-Json; ' + invoke + ' -PartLength 256 -CopyPart 0; ' +
      "if ($global:fixtureClipboard -ne $expected.FORTWO_PUSH_SERVICE_ACCOUNT_PARTS) { throw 'count-mismatch' }; " +
      'for ($i=1; $i -le [int]$expected.FORTWO_PUSH_SERVICE_ACCOUNT_PARTS; $i++) { ' + invoke + ' -PartLength 256 -CopyPart $i; ' +
      "if ($global:fixtureClipboard -cne $expected.('FORTWO_PUSH_SERVICE_ACCOUNT_' + $i)) { throw 'part-mismatch' } };");
    assert.equal(result.status, 0); assert.ok(!result.stdout.includes('BEGIN PRIVATE KEY'));
  });
  test('invalid file returns a fixed error without including its contents', () => {
    const result = run('& ' + quote(script) + ' -Path ' + quote(bad));
    assert.notEqual(result.status, 0); assert.match(result.stderr, /PUSH_ACCOUNT_INPUT_INVALID/);
    assert.ok(!result.stderr.includes('sensitive-invalid-fixture'));
  });
} finally {
  // Delete only exact generated fixture files, never a real account file or directory tree.
  fs.unlinkSync(fixture); fs.unlinkSync(bad); fs.rmdirSync(work);
}
console.log('push-account-tool: ' + passed + ' passed, 0 failed (synthetic keys; clipboard stubbed; no cloud requests)');
