/** Production controllers + isolated adapters. Not device HUKS/ArkUI/AGC evidence. */
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import { createRequire } from 'node:module';
const require = createRequire(import.meta.url);
const ts = require('D:/local/DevEcoStudio/tools/hvigor/hvigor/node_modules/typescript');
const root = path.resolve(import.meta.dirname, '../..');
const read = p => fs.readFileSync(path.join(root, p), 'utf8');
const compile = source => ts.transpileModule(source, { compilerOptions: {
  module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2020
} }).outputText;
const cache = new Map();
function load(file) {
  if (cache.has(file)) return cache.get(file);
  const exports = {}; cache.set(file, exports);
  new Function('exports', 'require', compile(read(file + '.ets')))(exports, request =>
    load(path.posix.normalize(path.posix.join(path.posix.dirname(file), request))));
  return exports;
}
const diagnostic = load('feature/src/main/ets/model/SharedPlanDiagnostic');
const presentation = load('feature/src/main/ets/model/SharedPlanPresentation');
const { SharedPlanUseCase } = load('feature/src/main/ets/usecase/SharedPlanUseCase');
const { initialSharedPlan, evaluateSharedPlanAction, SharedPlanAction } = load('feature/src/main/ets/model/SharedPlanFlow');
const { SecureSharedPlanGateway } = load('feature/src/main/ets/usecase/SecureSharedPlanGateway');
const uuid = '2313a05e-5c82-4fe2-ad76-024435c951b2';
const safe = diagnostic.sharedPlanDiagnostic('send.encrypt', 'RESULT_UNKNOWN',
  { diagnostic: { sdkCode: '12000003' }, message: 'secret-token', stack: 'private-content' }, uuid);
assert.equal(safe.sdkCode, '12000003');
assert.match(diagnostic.sharedPlanDiagnosticText(safe), /send.encrypt/);
assert.match(diagnostic.sharedPlanDiagnosticText(safe), /12000003/);
assert.match(diagnostic.sharedPlanDiagnosticText(safe), new RegExp(uuid));
assert.doesNotMatch(JSON.stringify(safe), /secret-token|private-content/);
const malicious = diagnostic.sharedPlanDiagnostic('secret-title', 'access-token', { code: 'secret' }, 'secret');
assert.doesNotMatch(JSON.stringify(malicious), /secret|access-token/);
assert.equal(diagnostic.sharedPlanDiagnosticText(null), '');
assert.equal(diagnostic.sharedPlanDiagnosticText(diagnostic.sharedPlanDiagnostic('send.rpc', 'OK')), '');
assert.equal(presentation.sharedPlanNeedsReview('LOCAL_CONFLICT'), false);
assert.equal(presentation.sharedPlanNeedsReview('RESULT_UNKNOWN'), true);
for (const code of ['BAD_COUNTER', 'STORAGE_NOT_READY']) {
  const remote = diagnostic.sharedPlanDiagnostic('send.decode', code, null, uuid);
  assert.equal(remote.code, code, 'preserve the actual storage verdict, not RESULT_UNKNOWN');
  assert.match(diagnostic.sharedPlanDiagnosticText(remote), new RegExp(code));
  assert.equal(presentation.sharedPlanNeedsReview(code), true, 'keep original durable request and freeze duplicate drafts');
  assert.match(presentation.sharedResultMessage(code), /云端计划存储/);
}

for (const fault of ['send.wire.read', 'send.encrypt', 'send.wire.save', 'send.rpc', 'send.decode', 'resolve.rpc']) {
  const member = 'm-' + 'a'.repeat(64), peer = 'm-' + 'b'.repeat(64);
  const session = { pairId: 'pair', actorId: member, generation: 'g' };
  const command = { requestId: 'request', planId: 'plan', action: 'PROPOSE', expectedVersion: 0,
    nextContent: { title: 'private-title', kind: 'meal', start: 600, end: 660 } };
  let wire = '', mutations = 0;
  const sdkFailure = { code: 1008210001, message: 'secret-token' };
  const channel = new SecureSharedPlanGateway({ async credential() { return { uid: 'uid', accessToken: 'secret-token' }; },
    async currentUid() { return 'uid'; } }, { async invoke(method) {
      if (method === 'capabilities') return JSON.stringify({ code: 'OK', status: 'ACTIVE', pairId: 'pair',
        myUid: member, peerUid: peer, peerPublicKey: 'public', protocolVersion: 1, projectionVersion: 1, sharedPlanReady: true });
      if (method === 'mutate') { mutations++; if (fault === 'send.rpc') throw sdkFailure; }
      if (method === 'requestStatus' && fault === 'resolve.rpc') throw sdkFailure;
      return '{"code":"OK","plan":{}}';
    } }, { async available() { return true; }, async seal() {
      if (fault === 'send.encrypt') throw sdkFailure; return 'opaque-encrypted';
    }, async open() { return null; } }, { async session() { return session; }, async current() { return true; },
      async wire() { if (fault === 'send.wire.read') throw sdkFailure; return wire; },
      async saveWire(_ctx, _request, _draft, value) { if (fault === 'send.wire.save') throw sdkFailure; wire = value; return wire; }
    }, () => true);
  const context = await channel.context(); assert.ok(context);
  if (fault === 'resolve.rpc') {
    wire = JSON.stringify({ pairId: 'pair', ...command, envelope: 'opaque-encrypted' });
    assert.equal((await channel.resolve(context, command)).code, 'RESULT_UNKNOWN');
  } else {
    const result = await channel.send(context, command);
    assert.equal(result.code, fault === 'send.decode' ? 'BAD_RECORD' : 'RESULT_UNKNOWN');
  }
  const info = channel.diagnostic(); assert.equal(info.stage, fault);
  if (fault !== 'send.decode') assert.equal(info.sdkCode, '1008210001');
  assert.doesNotMatch(JSON.stringify(info), /private-title|secret-token|opaque-encrypted/);
  if (['send.wire.read', 'send.encrypt', 'send.wire.save'].includes(fault)) assert.equal(mutations, 0);
  else assert.notEqual(wire, '', 'uncertain RPC/decode retains the durable original wire');
}

const ctx = { pairId: 'pair', actorId: 'me', peerId: 'peer', generation: 'g', protocolVersion: 1, projectionVersion: 1 };
const content = { title: '吃饭', kind: 'meal', start: 600, end: 660 };
// Receipt recovery precedes time checks; closing never discards an uncertain write locally.
for (const committed of [false, true]) {
  const command = { requestId: 'req', planId: 'p1', action: 'PROPOSE', expectedVersion: 0, nextContent: content };
  const row = initialSharedPlan('pair', 'p1', 'me', 'peer', content);
  let pending = [command], applied = 0, sends = 0;
  const use = new SharedPlanUseCase({ async context() { return ctx; }, async current() { return true; },
    async resolve() { return { code: committed ? 'OK' : 'REQUEST_NOT_COMMITTED', records: committed ? [row] : [] }; },
    async close() { return { code: committed ? 'OK' : 'REQUEST_CLOSED', records: committed ? [row] : [] }; },
    async send() { sends++; throw Error('expired request must not resend'); } }, {
    async current() { return true; }, async list() { return []; }, async pending() { return pending; },
    async finish() { pending = []; }, async apply() { applied++; return true; }
  }, { nowMin: () => 700, async canArrange() { throw Error('past start is not a schedule conflict'); } });
  assert.equal(await use.retry(), committed ? 'OK' : 'RETRY_TIME_PASSED');
  if (!committed) assert.equal(pending.length, 1);
  assert.equal(await use.closePending('req'), committed ? 'NOTHING_TO_RETRY' : 'REQUEST_CLOSED');
  assert.equal(pending.length, 0); assert.equal(applied, committed ? 1 : 0); assert.equal(sends, 0);
}
for (const verdict of ['RESULT_UNKNOWN', 'FORBIDDEN', 'BAD_RECORD']) {
  let finished = false;
  const use = new SharedPlanUseCase({ async context() { return ctx; }, async current() { return true; },
    async close() { return { code: verdict, records: [] }; } }, {
    async current() { return true; }, async pending() { return [{ requestId: 'req' }]; },
    async finish() { finished = true; }
  }, {});
  assert.equal(await use.closePending('req'), verdict); assert.equal(finished, false);
  assert.equal(await use.closePending('stale-request'), 'REQUEST_CHANGED');
}
{
  let finished = false, applied = false;
  const command = { requestId: 'req', planId: 'p1', action: 'PROPOSE', expectedVersion: 0, nextContent: content };
  const row = initialSharedPlan('pair', 'p1', 'me', 'peer', content);
  const use = new SharedPlanUseCase({ async context() { return ctx; }, async current() { return true; },
    async close() { return { code: 'OK', records: [row] }; } }, {
    async current() { return true; }, async list() { return []; }, async pending() { return [command]; },
    async finish() { finished = true; }, async apply() { applied = true; return true; }
  }, {});
  assert.equal(await use.closePending('req'), 'REQUEST_ALREADY_COMMITTED');
  assert.equal(finished, true); assert.equal(applied, true);
}
for (const committed of [true, false]) {
  let pending = [], ids = 0, sends = 0;
  const row = initialSharedPlan('pair', 'p1', 'me', 'peer', content);
  const gateway = { async context() { return ctx; }, async current() { return true; },
    async send(_ctx, command) { sends++; assert.equal(command.requestId, 'req'); return { code: sends === 1 ? 'RESULT_UNKNOWN' : 'OK', records: [row] }; },
    async resolve(_ctx, command) { assert.equal(command.requestId, 'req'); return { code: committed ? 'OK' : 'REQUEST_NOT_COMMITTED', records: committed ? [row] : [] }; } };
  const storage = { async current() { return true; }, async list() { return []; }, async apply() { return true; },
    async enqueue(_ctx, cmd) { pending = [cmd]; }, async pending() { return pending; }, async finish() { pending = []; } };
  const use = new SharedPlanUseCase(gateway, storage, { nowMin: () => 500, newId: () => ++ids === 1 ? 'p1' : 'req',
    async canArrange() { return true; }, async recompute() {} });
  assert.equal(await use.propose(content), 'RESULT_UNKNOWN');
  assert.equal(pending.length, 1);
  assert.equal(await use.retry(), 'OK');
  assert.equal(use.lastCreatedId(), 'shared:pair:p1');
  assert.equal(ids, 2, 'retry cannot generate a new plan/request ID');
  assert.equal(sends, committed ? 1 : 2);
  assert.equal(pending.length, 0);
}
// A storage error must retain the original request until a post-fix receipt check/retry succeeds.
for (const code of ['BAD_COUNTER', 'STORAGE_NOT_READY']) {
  let pending = [], newIds = 0, sent = 0;
  const row = initialSharedPlan('pair', 'p1', 'me', 'peer', content);
  const use = new SharedPlanUseCase({ async context() { return ctx; }, async current() { return true; },
    async send(_ctx, cmd) { sent++; assert.equal(cmd.requestId, 'req'); return { code: sent === 1 ? code : 'OK', records: [row] }; },
    async resolve() { return { code: 'REQUEST_NOT_COMMITTED', records: [] }; } }, {
    async current() { return true; }, async enqueue(_ctx, cmd) { pending = [cmd]; },
    async pending() { return pending; }, async finish() { pending = []; }, async list() { return []; }, async apply() { return true; }
  }, { nowMin: () => 500, newId: () => ++newIds === 1 ? 'p1' : 'req', async canArrange() { return true; }, async recompute() {} });
  assert.equal(await use.propose(content), code); assert.equal(pending.length, 1);
  assert.equal(await use.retry(), 'OK'); assert.equal(newIds, 2); assert.equal(pending.length, 0);
}

// A status-read authorization rejection is not proof that the earlier mutation failed.
{
  const command = { requestId: 'req', planId: 'p1', action: 'PROPOSE', expectedVersion: 0, nextContent: content };
  let finished = false;
  const use = new SharedPlanUseCase({ async context() { return ctx; }, async current() { return true; },
    async resolve() { return { code: 'FORBIDDEN', records: [] }; } }, {
    async current() { return true; }, async pending() { return [command]; }, async finish() { finished = true; }
  }, { nowMin: () => 500 });
  assert.equal(await use.retry(), 'FORBIDDEN'); assert.equal(finished, false);
}
{
  const pending = initialSharedPlan('pair', 'p1', 'me', 'peer', content);
  const accepted = evaluateSharedPlanAction(pending, { action: SharedPlanAction.ACCEPT, actorUid: 'peer',
    expectedVersion: 1, nextContent: null, nowMin: 500 }).record;
  const use = new SharedPlanUseCase({ async context() { return ctx; }, async current() { return true; },
    async resolve() { return { code: 'OK', records: [accepted] }; } }, {
    async current() { return true; }, async pending() { return [{ action: 'ACCEPT', planId: 'p1', requestId: 'req' }]; },
    async list() { return [pending]; }, async apply() { return true; }, async finish() {}
  }, { nowMin: () => 500, async recompute() {} });
  use.createdId = 'stale-previous-invitation';
  assert.equal(await use.retry(), 'OK'); assert.equal(use.lastCreatedId(), '');
}

const source = read('entry/src/main/ets/component/WindowDetailSheet.ets');
const controller = source.slice(0, source.indexOf('  build() {'))
  .replace(/^import\b[\s\S]*?;\s*/gm, '').replace(/@\w+(?:\([^)]*\))?\s*/g, '')
  .replace('export struct WindowDetailSheet', 'export class WindowDetailSheet') + '\n}';
let proposed = 0, retried = 0, validated = 0, notices = [], published = [];
let verdict = 'RESULT_UNKNOWN';
let createdId = 'shared:pair:p1';
const fakeUse = { async propose() { proposed++; return verdict; }, async retry() { retried++; return verdict; },
  diagnostic: () => safe, lastCreatedId: () => createdId };
const bindings = { ...diagnostic, ...presentation, DRAFT_GRID_MIN: 15,
  PLAN_KINDS: [{ key: 'meal', label: '吃饭' }], planDraftError: () => { validated++; return ''; },
  secureSharedPlans: () => fakeUse, appToast: msg => notices.push(msg), publishPlanSaved: id => published.push(id),
  Logger: { warn() {} } };
const component = {};
new Function('exports', ...Object.keys(bindings), compile(controller))(component, ...Object.values(bindings));
const sheet = new component.WindowDetailSheet(); sheet.mounted = true; sheet.cloudPlan = true;
sheet.title = '吃饭'; sheet.planStart = 600; sheet.planEnd = 660; sheet.holdSuccess = () => {};
await sheet.submitPlan();
assert.equal(sheet.saving, false); assert.equal(sheet.reviewOriginal, true);
assert.match(sheet.submitFeedback, /send.encrypt/); assert.match(sheet.submitFeedback, /12000003/);
sheet.shiftStart(15); sheet.onTitleChange('changed');
assert.equal(sheet.planStart, 600); assert.equal(sheet.title, '吃饭', 'uncertain draft is frozen');
verdict = 'OK'; await sheet.submitPlan();
assert.equal(proposed, 1); assert.equal(retried, 1); assert.equal(validated, 1);
assert.equal(sheet.created, true); assert.deepEqual(published, ['shared:pair:p1']);
// Definite local validation failures do not lock the form behind a needless retry step.
const conflict = new component.WindowDetailSheet(); conflict.mounted = true; conflict.cloudPlan = true;
verdict = 'LOCAL_CONFLICT'; await conflict.submitPlan();
assert.equal(conflict.reviewOriginal, false); assert.equal(conflict.saving, false);
const unrelated = new component.WindowDetailSheet(); unrelated.mounted = true; unrelated.cloudPlan = true;
unrelated.reviewOriginal = true; createdId = ''; verdict = 'OK'; await unrelated.submitPlan();
assert.equal(unrelated.created, false); assert.equal(unrelated.reviewOriginal, false);
assert.equal(unrelated.saving, false); assert.deepEqual(published, ['shared:pair:p1']);
assert.match(unrelated.submitFeedback, /原请求已核实/);

// Dynamic px -> vp inset, correct subscription identity, stale-window callback is harmless.
const insetSource = read('entry/src/main/ets/util/BottomSafeArea.ets').replace(/^import.*;\s*/m, '');
const inset = {}, values = new Map();
const win = { AvoidAreaType: { TYPE_SYSTEM: 0, TYPE_NAVIGATION_INDICATOR: 1 } };
new Function('exports', 'window', 'AppStorage', compile(insetSource))(inset, win,
  { setOrCreate: (key, value) => values.set(key, value) });
let listener, removed, sizeListener, removedSize;
const host = { getWindowAvoidArea: type => ({ bottomRect: { height: type === 1 ? 72 : 0 } }),
  getWindowProperties: () => ({ windowRect: { height: 2400 } }),
  getUIContext: () => ({ px2vp: px => px / 3 }),
  on: (event, callback) => { if(event === 'avoidAreaChange') listener = callback; else sizeListener = callback; },
  off: (event, callback) => { if(event === 'avoidAreaChange') removed = callback; else removedSize = callback; } };
inset.BottomSafeArea.attach(host); assert.equal(values.get('crd_bottom_safe_vp'), 24);
assert.equal(values.get('crd_window_height_vp'), 800);
host.getWindowProperties = () => ({ windowRect: { height: 1200 } });
sizeListener(); assert.equal(values.get('crd_window_height_vp'), 400);
host.getWindowAvoidArea = () => ({ bottomRect: { height: 96 } });
listener({ type: 1 }); assert.equal(values.get('crd_bottom_safe_vp'), 32);
inset.BottomSafeArea.detach(); assert.equal(removed, listener);
assert.equal(removedSize, sizeListener);
listener({ type: 1 }); assert.equal(values.get('crd_bottom_safe_vp'), 32);
const day = read('entry/src/main/ets/component/DayShiftSheet.ets');
assert.match(day, /bottom:Math\.max\(12,this\.bottomSafe\+12\)/);
assert.match(day, /this\.safeFooter\(\)/); assert.match(day, /flexShrink\(0\)/);
assert.match(day, /Scroll\(\)\{this\.shiftSelection\(\)\}\.width\('100%'\)\.layoutWeight\(1\)/);
assert.match(day, /height\(this\.editorHeight\(\)\)/, 'FIT_CONTENT needs an intrinsic height independent of its own scroll measure');
const co = read('entry/src/main/ets/view/CoTimeView.ets');
const header = co.slice(co.indexOf('  header()'), co.indexOf('  segmentControl()'));
assert.match(header, /alignItems\(VerticalAlign\.Bottom\)/);
assert.match(header, /Text\('共同休时'\)[\s\S]*Text\(this\.subtitle\(\)\)[\s\S]*offset\(\{ y: 3 \}\)[\s\S]*CompanionsDuo/,
  'title/subtitle share the left group and align its bottom with the duo after the requested header refinement');
console.log('real-device-feedback-regression: PASS (production diagnostics/retry/inset/controllers; device validation pending)');
