/** Actual coordinator and bridge, isolated ports / test AES key. No device/cloud/user secrets. */
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const crypto = require('node:crypto');
const ts = require('D:/local/DevEcoStudio/tools/hvigor/hvigor/node_modules/typescript');
const root = path.resolve(__dirname, '../..');
function source(rel, deps = {}) {
  const mod = { exports: {} };
  vm.runInNewContext(ts.transpileModule(fs.readFileSync(path.join(root, rel), 'utf8'), {
    compilerOptions: { target: ts.ScriptTarget.ES2021, module: ts.ModuleKind.CommonJS }
  }).outputText, { module: mod, exports: mod.exports, Date, Promise, require: n => {
    if (!(n in deps)) throw Error('Unexpected import ' + n); return deps[n];
  } });
  return mod.exports;
}
const { UnifiedPairingUseCase } = source('feature/src/main/ets/usecase/UnifiedPairingUseCase.ets');
const key = crypto.randomBytes(32);
const keyPort = {
  async seal(pair, aad, plain) {
    const iv = crypto.randomBytes(12), cipher = crypto.createCipheriv('aes-256-gcm', key, iv);
    cipher.setAAD(Buffer.from(aad));
    return { algorithm: 'AES-256-GCM', iv: iv.toString('base64'),
      ciphertext: Buffer.concat([cipher.update(plain, 'utf8'), cipher.final()]).toString('base64'), authTag: cipher.getAuthTag().toString('base64') };
  },
  async open(pair, aad, value) {
    try {
      const decipher = crypto.createDecipheriv('aes-256-gcm', key, Buffer.from(value.iv, 'base64'));
      decipher.setAAD(Buffer.from(aad)); decipher.setAuthTag(Buffer.from(value.authTag, 'base64'));
      return Buffer.concat([decipher.update(Buffer.from(value.ciphertext, 'base64')), decipher.final()]).toString('utf8');
    } catch { return null; }
  }
};
const { PlanPairingBridge } = source('cloud/src/main/ets/api/PlanPairingBridge.ets', {
  './PairKeyStore': { PairKeyStore: keyPort }, './SnapshotCrypto': {},
  './SecurePlanKeyStore': { SecurePlanKeyStore: { async pairingRoute(pair) {
    return crypto.createHash('sha256').update('FORTWO_UNIFIED_PAIRING_V1|' + pair).digest('hex'); } } }
});
const securePair = 'sp-' + 'a'.repeat(32), publicKey = 'B' + 'A'.repeat(86) + '=';
const offer = () => ({ pairId: securePair, publicKey, inviteCode: '123456', expiresAt: Date.now() + 60000 });
function uiFixture() {
 const raw = fs.readFileSync(path.join(root, 'entry/src/main/ets/component/UnifiedPairingStatus.ets'), 'utf8');
 const methods = raw.slice(raw.indexOf('  aboutToAppear()'), raw.indexOf('  private message()'));
 const { LatestLanding } = source('entry/src/main/ets/util/LatestLanding.ets');
 const f = { now: 0, timers: new Map(), calls: [], events: [], next: { code: 'OK', phase: 'WAITING' }, work: null, id: 0 };
 const mod = { exports: {} };
 const typed = `export class Status { constructor() { this.mounted=false; this.active=true; this.foreground=true;
 this.generation=0; this.timer=-1; this.deadline=0; this.busy=false; this.phase='CONNECTING'; this.code='OK';
 this.landing=new LatestLanding(); this.onState=(v)=>events.push(v); } ${methods} }`;
 vm.runInNewContext(ts.transpileModule(typed, { compilerOptions: { target: ts.ScriptTarget.ES2021,
   module: ts.ModuleKind.CommonJS } }).outputText, { module: mod, exports: mod.exports, LatestLanding, events: f.events,
   Date: class extends Date { static now() { return f.now; } }, PAIRED: 'PAIRED', PAIR_PENDING: 'PENDING_CONFIRM',
   SettingsStore: { getPairState: () => 'PAIRED' },
   unifiedPairing: () => ({ async advance(consent) { f.calls.push(consent); return f.work ? f.work() : f.next; } }),
   setTimeout(fn, ms) { f.timers.set(++f.id, { fn, ms }); return f.id; }, clearTimeout(id) { f.timers.delete(id); }
 });
 f.ui = new mod.exports.Status();
 f.drain = async () => { for (let i = 0; i < 20; i++) await Promise.resolve(); };
 f.fire = async () => { const [id, value] = [...f.timers][0]; f.timers.delete(id); value.fn(); await f.drain(); };
 return f;
}
function legacyFixture(method, cancelAt = '') {
 const raw = fs.readFileSync(path.join(root,'feature/src/main/ets/usecase/ProfileSettingsService.ets'),'utf8');
 const start = raw.indexOf('  static async ' + method + '('), open = raw.indexOf('{',start);
 let end = open, depth = 0;
 for (; end < raw.length; end++) { if (raw[end] === '{') depth++; else if (raw[end] === '}' && --depth === 0) { end++; break; } }
 const f = { pair: 'original', epoch: 0, states: [], agreed: 0, dropped: 0, proofDropped: 0, consent: '' };
 const cancel = at => { if (cancelAt === at) { f.epoch++; f.pair = ''; } };
 const session = { pairId: 'next-pair', status: method === 'createInvite' ? 'WAITING' : method === 'joinByCode' ? 'PENDING_CONFIRM' : 'ACTIVE',
   code: '123456', confirmToken: method === 'createInvite' ? 'p'.repeat(24) : '', peerPublicKey: 'public-key', peerUid: 'peer' };
 class Client {
   async createPairing() { cancel('cloud'); return session; }
   async joinPairing() { cancel('cloud'); return session; }
   async confirmPairing() { cancel('cloud'); return session; }
 }
 const mod = { exports: {} };
 const code = `export class ProfileSettingsService { static cloudBlocked(){return false;} static degradedMessage(){return 'failed';}
 static async releaseInviteProof(){} ${raw.slice(start,end)} }`;
 vm.runInNewContext(ts.transpileModule(code,{compilerOptions:{target:ts.ScriptTarget.ES2021,module:ts.ModuleKind.CommonJS}}).outputText, {
  module: mod, exports: mod.exports, ok: message => ({ok:true,message}), fail: message => ({ok:false,message}),
  TAG:'test', Logger:{warn(){}}, FeatureFlags:{cloudClosedMessage:'closed'}, AgcPairingClient:Client,
  SecureLifecycle:{anchor:()=>String(f.epoch)}, PAIR_WAITING:'WAITING', PAIR_PENDING:'PENDING_CONFIRM', PAIRED:'PAIRED',
  SettingsStore:{getPairId:()=>f.pair,getInviteProof:()=>'{}',getOrCreateUid:async()=>'uid',
   async savePairId(pair){f.pair=pair;},async setPairState(state){f.states.push(state);},
   async saveInviteProof(){}, async setUnifiedPairConsent(pair){f.consent=pair;}},
  PairKeyStore:{async ensureIdentity(){return 'public-key';},async openInviteProof(){return 'p'.repeat(24);},
   async sealInviteProof(){cancel('keys');return {};},async dropInviteProof(){f.proofDropped++;},
   async agreeKey(){f.agreed++;cancel('keys');},async dropPairKey(){f.dropped++;}},
  ScheduleUseCase:{async onScheduleChanged(){}}
 });
 f.run = () => mod.exports.ProfileSettingsService[method]('123456'); return f;
}
function fixture(uid = 'a', peer = 'b', shared = {}) {
  const f = { ctx: { pairId: 'schedule-pair', uid, peerUid: peer, epoch: '0' }, enabled: true,
    consent: false, paused: false, phase: 'EMPTY', creator: false, ready: false, calls: [], shared,
    code: 'OK', hook: null, anchor: '', offers: null };
  const reply = () => ({ code: f.code, phase: f.phase, inviteCode: f.creator ? '123456' : '',
    canConfirm: f.creator && shared.joined && !shared.active });
  async function call(name) { f.calls.push(name); if (f.hook) await f.hook(name); }
  const port = {
    enabled: () => f.enabled, context: async () => f.ctx,
    consented: () => f.consent, paused: () => f.paused,
    async consent() { await call('consent'); f.consent = true; f.paused = false; },
    async pause() { f.paused = true; },
    async state() { return { result: { ...reply(), code: 'OK' }, creator: f.creator, anchor: f.anchor }; },
    async ready() { return f.ready; },
    async create() { await call('create'); if (f.code !== 'OK') return reply();
      f.phase = 'WAITING'; f.creator = true; f.anchor = 'PAIRED|' + f.ctx.pairId; return reply(); },
    async publish() { await call('publish'); if (f.code === 'OK') { shared.offer = offer(); shared.sender = uid; } return reply(); },
    async discover() { await call('discover'); return { code: f.code, offers: f.offers ?? (shared.offer && shared.sender !== uid ? [shared.offer] : []) }; },
    async join(value) { await call('join'); assert.equal(value.pairId, securePair);
      if (f.code === 'OK') { shared.joined = true; f.phase = 'PENDING_CONFIRM'; } return reply(); },
    async resume() { await call('resume'); if (f.code === 'OK' && shared.active) { f.phase = 'ACTIVE'; f.ready = true; } return reply(); },
    async confirm() { await call('confirm'); if (f.code === 'OK') { shared.active = true; f.phase = 'ACTIVE'; f.ready = true; } return reply(); }
  };
  f.uc = new UnifiedPairingUseCase(port); f.port = port; return f;
}
let passed = 0;
async function test(name, run) { await run(); passed++; console.log('PASS ' + name); }
async function main() {
 await test('one consent per device completes both sides without another user-entered code', async () => {
  const shared = {}, a = fixture('a', 'b', shared), b = fixture('b', 'a', shared);
  assert.equal((await a.uc.advance(true)).phase, 'WAITING');
  assert.equal((await b.uc.advance(true)).phase, 'WAITING');
  assert.equal((await a.uc.advance()).phase, 'READY');
  assert.equal((await b.uc.advance()).phase, 'READY');
  assert.equal(a.calls.filter(v => v === 'create').length, 1);
  assert.equal(b.calls.filter(v => v === 'join').length, 1);
  assert.equal(a.calls.filter(v => v === 'confirm').length, 1);
 });
 await test('old schedule-only pair requires explicit completion; local is network-free', async () => {
  const f = fixture(); assert.equal((await f.uc.local()).phase, 'UPGRADE');
  assert.equal((await f.uc.advance()).phase, 'UPGRADE'); assert.deepEqual(f.calls, []);
 });
 await test('already ACTIVE plans are retained without creating, joining or re-confirming', async () => {
  const f = fixture(); f.ready = true; f.phase = 'ACTIVE';
  assert.equal((await f.uc.advance()).phase, 'READY'); assert.equal((await f.uc.local()).phase, 'READY');
  assert.deepEqual(f.calls, []);
 });
 await test('deterministic election waits for peer; discovery takes precedence for old creator', async () => {
  const f = fixture('z', 'a'); assert.equal((await f.uc.advance(true)).phase, 'WAITING');
  assert.ok(!f.calls.includes('create'));
  f.offers = [offer()]; await f.uc.advance(); assert.ok(f.calls.includes('join'));
 });
 await test('ambiguous discovery never selects one arbitrary connection', async () => {
  const f = fixture(); f.offers = [offer(), offer()];
  assert.equal((await f.uc.advance(true)).code, 'CODE_COLLISION');
  assert.ok(!f.calls.includes('join') && !f.calls.includes('create'));
 });
 await test('network failure pauses durably and foreground does not replay; explicit continuation resumes original intent', async () => {
  const f = fixture(); await f.uc.advance(true); f.code = 'RESULT_UNKNOWN';
  assert.equal((await f.uc.advance()).phase, 'FAILED'); assert.equal(f.paused, true);
  const count = f.calls.length; f.code = 'OK';
  assert.equal((await f.uc.advance()).code, 'RETRY_REQUIRED'); assert.equal(f.calls.length, count);
  await f.uc.advance(true); assert.equal(f.calls.filter(v => v === 'create').length, 1);
  assert.equal(f.calls.filter(v => v === 'resume').length, 2);
 });
 await test('changed schedule context discards a discovery and sends no join/create', async () => {
  const f = fixture(); f.hook = async name => { if (name === 'discover') f.ctx = { ...f.ctx, pairId: 'other' }; };
  assert.equal((await f.uc.advance(true)).code, 'SESSION_CHANGED'); assert.ok(!f.calls.includes('create'));
 });
 await test('clearing consent during cloud read prevents late setup continuation', async () => {
  const f = fixture(); f.hook = async name => { if (name === 'discover') f.consent = false; };
  assert.equal((await f.uc.advance(true)).code, 'SESSION_CHANGED'); assert.ok(!f.calls.includes('create'));
 });
 await test('double taps coalesce a single setup flight', async () => {
  const f = fixture(); let release;
  f.hook = name => name === 'discover' ? new Promise(r => { release = r; }) : Promise.resolve();
  const a = f.uc.advance(true), b = f.uc.advance(true); assert.equal(a, b);
  while (!release) await Promise.resolve(); release(); await a;
  assert.equal(f.calls.filter(v => v === 'create').length, 1);
 });
 await test('closed gate and absent schedule connection make no cloud request', async () => {
  const f = fixture(); f.enabled = false; assert.equal((await f.uc.advance(true)).code, 'FEATURE_DISABLED');
  assert.deepEqual(f.calls, []); f.enabled = true; f.ctx = null;
  assert.equal((await f.uc.advance(true)).phase, 'NOT_PAIRED'); assert.deepEqual(f.calls, []);
 });
 await test('revoked current secure session is not silently recreated', async () => {
  const f = fixture(); f.phase = 'REVOKED'; f.anchor = 'PAIRED|' + f.ctx.pairId;
  assert.equal((await f.uc.advance(true)).code, 'SESSION_REVOKED'); assert.ok(!f.calls.includes('create'));
 });
 await test('bridge encrypts handoff with fresh nonce and binds both partners and pair', async () => {
  const raw = await PlanPairingBridge.seal('pair', 'a', 'b', offer());
  const raw2 = await PlanPairingBridge.seal('pair', 'a', 'b', offer()); assert.notEqual(raw, raw2);
  assert.ok(!raw.includes('123456') && !raw.includes(securePair));
  assert.equal((await PlanPairingBridge.open('pair', 'a', 'b', raw)).pairId, securePair);
  for (const args of [['other','a','b'], ['pair','b','a'], ['pair','c','b']]) {
   assert.equal(await PlanPairingBridge.open(...args, raw), null);
  }
  const tampered = JSON.parse(raw); tampered.authTag = Buffer.alloc(16).toString('base64');
  assert.equal(await PlanPairingBridge.open('pair','a','b',JSON.stringify(tampered)), null);
 });
 await test('expired/malformed handoff cannot become an invitation', async () => {
  const stale = { ...offer(), expiresAt: Date.now() - 1 };
  await assert.rejects(() => PlanPairingBridge.seal('pair','a','b',stale));
  assert.equal(await PlanPairingBridge.open('pair','a','b','null'), null);
  assert.equal(await PlanPairingBridge.open('pair','a','b','x'.repeat(5000)), null);
 });
 await test('single UI flow uses visible foreground bounded checks and a landing fence', async () => {
  const me = fs.readFileSync(path.join(root,'entry/src/main/ets/view/MeView.ets'),'utf8');
  const status = fs.readFileSync(path.join(root,'entry/src/main/ets/component/UnifiedPairingStatus.ets'),'utf8');
  assert.ok(!me.includes('SecurePairingSetup()')); assert.ok(me.includes('UnifiedPairingStatus('));
  assert.ok(status.includes('crd_app_foreground') && status.includes('60000') && status.includes('3000'));
  assert.ok(status.includes('clearTimeout') && status.includes('landing.isCurrent') && status.includes('!this.active'));
  assert.ok(!status.includes('生成短码') && !status.includes('解除共同计划连接'));
 });
 await test('actual component cancels timers on hide/background and restarts one visible check', async () => {
  const f = uiFixture(); f.ui.aboutToAppear(); await f.drain();
  assert.equal(f.timers.size, 1); assert.equal([...f.timers.values()][0].ms, 3000);
  f.ui.foreground = false; f.ui.visibilityChanged(); assert.equal(f.timers.size, 0);
  f.ui.foreground = true; f.ui.visibilityChanged(); await f.drain(); assert.equal(f.timers.size, 1);
  f.ui.aboutToDisappear(); assert.equal(f.timers.size, 0);
 });
 await test('actual component stops automatic checks at 60 seconds and on failure', async () => {
  const f = uiFixture(); f.ui.aboutToAppear(); await f.drain(); f.now = 61000;
  await f.fire(); assert.equal(f.timers.size, 0); assert.equal(f.calls.length, 1);
  const failed = uiFixture(); failed.next = { code: 'RESULT_UNKNOWN', phase: 'FAILED' };
  failed.ui.aboutToAppear(); await failed.drain(); assert.equal(failed.timers.size, 0);
 });
 await test('actual component drops a late READY result after closure', async () => {
  const f = uiFixture(); let release; f.work = () => new Promise(r => { release = r; });
  f.ui.aboutToAppear(); await f.drain(); f.ui.active = false; f.ui.visibilityChanged();
  release({ code: 'OK', phase: 'READY' }); await f.drain();
  assert.ok(!f.events.includes('READY')); assert.equal(f.timers.size, 0); assert.equal(f.ui.busy, false);
 });
 await test('a foreground cancellation is not persisted as a network-failure pause', async () => {
  const f = fixture(); f.hook = async name => { if (name === 'discover') f.enabled = false; };
  assert.equal((await f.uc.advance(true)).code, 'SESSION_CHANGED'); assert.equal(f.paused, false);
 });
 await test('two legacy pending creators are reported as a conflict, never silently replaced', async () => {
  const f = fixture(); f.consent = true; f.creator = true; f.phase = 'WAITING'; f.offers = [offer()];
  assert.equal((await f.uc.advance()).code, 'CODE_COLLISION'); assert.ok(!f.calls.includes('create'));
  assert.ok(!f.calls.includes('join') && !f.calls.includes('publish'));
 });
 await test('actual schedule create/join/confirm discard cloud replies after cancellation', async () => {
  for (const method of ['createInvite','joinByCode','confirmPendingJoin']) {
   const f = legacyFixture(method,'cloud'); assert.equal((await f.run()).ok,false,method);
   assert.equal(f.states.length,0); assert.equal(f.agreed,0); assert.equal(f.consent,'');
  }
 });
 await test('actual schedule setup cleans a late key result without restoring cancelled state', async () => {
  for (const method of ['createInvite','joinByCode','confirmPendingJoin']) {
   const f = legacyFixture(method,'keys'); assert.equal((await f.run()).ok,false,method);
   assert.equal(f.states.length,0); assert.equal(f.consent,'');
   assert.equal(method === 'createInvite' ? f.proofDropped : f.dropped,1);
  }
 });
 await test('actual schedule setup positive controls preserve the normal single-confirmation path', async () => {
  for (const method of ['createInvite','joinByCode','confirmPendingJoin']) {
   const f = legacyFixture(method); assert.equal((await f.run()).ok,true,method); assert.equal(f.states.length,1);
   if (method !== 'createInvite') assert.ok(f.consent);
  }
 });
 console.log(`unified pairing: ${passed} passed, 0 failed (offline; no real-device proof)`);
}
main().catch(error => { console.error(error); process.exitCode = 1; });
