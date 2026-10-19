/*
 * 两人份 · 配对云对象（协议 v1 §4.1–§4.6）。
 *
 * 部署形态：CloudProgram/cloudfunctions/pairing，function-config.json 的 handler 指向本文件的类。
 * 端侧调用体固定是 `{ method, params }`（DevEco 生成的 ImportObject 代理就是这个形状，
 * 线上框架也确实按 `func.apply(?, data.params)` 派发），所以这里的**参数顺序与个数就是线上契约**，
 * 改动必须同步 `cloud/src/main/ets/api/CloudApi.ets`。
 *
 * 三条贯穿全部方法的口径：
 * 1. **调用方是谁由参数说，不由令牌说**：AGC 云对象给不出可验证的用户身份（spike 的匿名认证只覆盖
 *    Cloud DB 直连那条路），所以 uid 是端侧自证的。防线因此全压在"载荷端到端加密 + 一次性凭据"上，
 *    冒充一个 pairId 最多读到密文，读不到日程（协议 §6 的残余风险条目）。
 * 2. **状态只有云端一份**：端侧写本机配对态之前必须拿到云端的 status（协议 §8），
 *    所以本文件不返回"我以为成功"，只返回行里真实的状态。
 * 3. **任何失败都带包络**：`guarded` 把异常也翻成 §3.2 的形状，端侧永远能解析。
 */

import {
  BAD_REQUEST, CODE_EXPIRED, CODE_TAKEN, FORBIDDEN, INTERNAL, NOT_FOUND, SCHEMA_UNSUPPORTED,
  SCHEMA_VERSION, SESSION_TTL_MS, ST_ACTIVE, ST_EXPIRED, ST_PENDING, ST_REVOKED, ST_WAITING,
  deleteSessionRow, deleteSnapshots, expired, fail, findOpenByCreator,
  findSessionByCode, guarded, isCode, isPublicKey, isUid, listSnapshotRows, loadSession, newSessionRow,
  nowMs, ok, patchSession, roleOf, saveSession, sessionBody, str, tokenEquals
} from './contract';

/** 配对码掷码的冲突重试上限：6 位空间撞上概率极低，兜底只是不让它无限转。 */
const CODE_RETRY = 5;

/** 进程外传来的数字一律取整：小数与字符串形态都不该被当成新版本号写进会话。 */
function asInt(value: number): number {
  const n = Number(value);
  return Number.isNaN(n) ? -1 : Math.floor(n);
}

/*
 * 公开方法**不许碰 `this`**，这是 2026-09-27 首部署实测出来的约束，不是风格偏好。
 *
 * 框架把方法从实例上摘下来调（`params` 走 apply 按位置展开，但 `this` 不是实例）。
 * 原先写成 `guarded(() => this.doCreate(...))` 时，每一次调用都在读库之前抛
 * `Cannot read properties of undefined (reading 'doCreate')`，被 guarded 塌成
 * `{"code":"INTERNAL","message":"cloud error "}`（尾部没有 dbCode，所以一眼看出不是库的问题）。
 * 向导样本 `IdGenerator.randomUUID()` 一个 `this` 都不用，于是这个坑一直掩盖到第一次真调用。
 *
 * 所以下面只留一层薄壳：公开方法转调模块级函数，函数体里也没有 `this`。
 */
export class Pairing {
  /** §4.1 发起方生成配对码：只写会话行，不碰任何密钥材料。 */
  async create(uid: string, publicKey: string, schemaVersion: number): Promise<Record<string, Object>> {
    return guarded(() => doCreate(uid, publicKey, schemaVersion));
  }

  /** §4.2 加入方输码：只写 joiner，确认凭据仍由邀请方持有，状态停在 PENDING_CONFIRM。 */
  async join(code: string, uid: string, publicKey: string,
    schemaVersion: number): Promise<Record<string, Object>> {
    return guarded(() => doJoin(code, uid, publicKey, schemaVersion));
  }

  /** §4.3 发起方交回凭据后确认：只有这里能把会话推到 ACTIVE。 */
  async confirm(pairId: string, uid: string, token: string): Promise<Record<string, Object>> {
    return guarded(() => doConfirm(pairId, uid, token));
  }

  /** §4.4 对账：给状态与对端公钥，**不给** code 与 confirmToken。 */
  async status(pairId: string, uid: string): Promise<Record<string, Object>> {
    return guarded(() => doStatus(pairId, uid));
  }

  /** §4.5 解除配对：级联删快照，再删会话。 */
  async unpair(pairId: string, uid: string, requestId: string): Promise<Record<string, Object>> {
    return guarded(() => doUnpair(pairId, uid, requestId));
  }

  /** §4.6 存活信号：不查库也不写库，防的是项目级闲置回收。 */
  async heartbeat(uid: string, pairId: string): Promise<Record<string, Object>> {
    return guarded(() => doHeartbeat(uid, pairId));
  }
}

/** §4.1 发起方生成配对码：只写会话行，不碰任何密钥材料。 */
async function doCreate(uid: string, publicKey: string,
  schemaVersion: number): Promise<Record<string, Object>> {
  if (!isUid(uid)) {
    return fail(BAD_REQUEST, 'uid malformed');
  }
  if (!isPublicKey(publicKey)) {
    return fail(BAD_REQUEST, 'publicKey malformed');
  }
  if (asInt(schemaVersion) !== SCHEMA_VERSION) {
    return fail(SCHEMA_UNSUPPORTED, 'create schemaVersion ' + schemaVersion);
  }
  // 上一张没走完的码当场作废：端侧 pairId 一旦换新的，旧会话就再也确认不上了，留着只会误导
  const open = await findOpenByCreator(uid);
  for (const stale of open) {
    await saveSession(patchSession(stale, { 'status': ST_REVOKED, 'confirmToken': '', 'code': '' }));
  }
  let row = newSessionRow(uid, publicKey);
  let free = false;
  for (let i = 0; i < CODE_RETRY; i++) {
    if (await findSessionByCode(str(row, 'code')) === null) {
      free = true;
      break;
    }
    row = newSessionRow(uid, publicKey);
  }
  if (!free) {
    return fail(INTERNAL, 'invite code space busy');
  }
  await saveSession(row);
  return ok(sessionBody(row, uid, true, true));
}

/** §4.2 加入方输码：只写 joiner，确认凭据仍由邀请方持有，状态停在 PENDING_CONFIRM。 */
async function doJoin(code: string, uid: string, publicKey: string,
  schemaVersion: number): Promise<Record<string, Object>> {
  if (!isCode(code)) {
    return fail(BAD_REQUEST, 'code must be 6 digits');
  }
  if (!isUid(uid) || !isPublicKey(publicKey)) {
    return fail(BAD_REQUEST, 'uid or publicKey malformed');
  }
  if (asInt(schemaVersion) !== SCHEMA_VERSION) {
    return fail(SCHEMA_UNSUPPORTED, 'join schemaVersion ' + schemaVersion);
  }
  const session = await findSessionByCode(code);
  if (session === null) {
    // 码不落库留存（协议 §2），过期会话也不回查：查不到就是失效，端侧统一引导重新生成
    return fail(CODE_EXPIRED, 'no open session for this code');
  }
  const at = nowMs();
  if (expired(session, at)) {
    await saveSession(patchSession(session, { 'status': ST_EXPIRED, 'confirmToken': '' }));
    return fail(CODE_EXPIRED, 'session expired');
  }
  if (str(session, 'creatorUid') === uid) {
    return fail(BAD_REQUEST, 'cannot join own invite');
  }
  if (str(session, 'status') !== ST_WAITING) {
    if (str(session, 'joinerUid') === uid) {
      // 重试仍只回会话状态；确认凭据从创建时起只属于邀请方。
      return ok(sessionBody(session, uid, false, false));
    }
    return fail(CODE_TAKEN, 'code already used');
  }
  const next = patchSession(session, {
    'status': ST_PENDING,
    'joinerUid': uid,
    'joinerPublicKey': publicKey,
    // 确认这一步也要时间窗：从加入方输码起再给一个 TTL，而不是沿用到期日的半截窗口
    'expiresAt': at + SESSION_TTL_MS
  });
  await saveSession(next);
  return ok(sessionBody(next, uid, false, false));
}

/** §4.3 发起方交回凭据后确认：只有这里能把会话推到 ACTIVE。 */
async function doConfirm(pairId: string, uid: string,
  token: string): Promise<Record<string, Object>> {
  if (!isUid(uid)) {
    return fail(BAD_REQUEST, 'uid malformed');
  }
  const session = await loadSession(pairId);
  if (session === null) {
    return fail(NOT_FOUND, 'no such session');
  }
  if (roleOf(session, uid) !== 'creator') {
    // 加入方确认等于绕过 §4.3——确认凭据本来就是交给发起方的，谁都能确认就是没有门槛
    return fail(FORBIDDEN, 'only the creator confirms');
  }
  if (str(session, 'status') === ST_ACTIVE) {
    // 幂等重放：云端已确认但响应丢在路上的发起方，第二次点确认要看到成功，而不是"状态不对"
    return ok(sessionBody(session, uid, false, false));
  }
  if (expired(session, nowMs())) {
    const next = patchSession(session, { 'status': ST_EXPIRED, 'confirmToken': '' });
    await saveSession(next);
    return fail(CODE_EXPIRED, 'session expired');
  }
  if (str(session, 'status') !== ST_PENDING) {
    // WAITING = 对方还没输码；REVOKED = 这轮已经被新的配对码顶掉
    return fail(BAD_REQUEST, 'peer has not joined yet');
  }
  if (!tokenEquals(str(session, 'confirmToken'), token)) {
    return fail(FORBIDDEN, 'confirm token rejected');
  }
  // 一次一用：转 ACTIVE 的同时把凭据抹掉，重放同一份链接不会再有副作用
  const next = patchSession(session, { 'status': ST_ACTIVE, 'confirmToken': '' });
  await saveSession(next);
  return ok(sessionBody(next, uid, false, false));
}

/** §4.4 对账：给状态与对端公钥，**不给** code 与 confirmToken。 */
async function doStatus(pairId: string, uid: string): Promise<Record<string, Object>> {
  if (!isUid(uid)) {
    return fail(BAD_REQUEST, 'uid malformed');
  }
  const session = await loadSession(pairId);
  if (session === null) {
    return fail(NOT_FOUND, 'no such session');
  }
  if (roleOf(session, uid) === '') {
    return fail(FORBIDDEN, 'caller is not a member');
  }
  if (expired(session, nowMs())) {
    const next = patchSession(session, { 'status': ST_EXPIRED, 'confirmToken': '' });
    await saveSession(next);
    return ok(sessionBody(next, uid, false, false));
  }
  return ok(sessionBody(session, uid, false, false));
}

/** §4.5 解除配对：级联删快照，再删会话。 */
async function doUnpair(pairId: string, uid: string,
  requestId: string): Promise<Record<string, Object>> {
  if (!isUid(uid)) {
    return fail(BAD_REQUEST, 'uid malformed');
  }
  const session = await loadSession(pairId);
  if (session === null) {
    // 会话行已经不在了 = 已经解除过：删除是收敛操作，重放必须报成功而不是 NOT_FOUND
    return ok({ 'deletedVersions': 0, 'requestId': requestId });
  }
  if (roleOf(session, uid) === '') {
    return fail(FORBIDDEN, 'caller is not a member');
  }
  // 先删快照再删会话：反过来一旦中途失败，就成了"没有成员可验证、又查得到密文"的孤儿行
  const rows = await listSnapshotRows(pairId);
  const deleted = await deleteSnapshots(rows);
  await deleteSessionRow(pairId);
  return ok({ 'deletedVersions': deleted, 'requestId': requestId });
}

/** §4.6 存活信号：不查库也不写库，防的是项目级闲置回收。 */
async function doHeartbeat(uid: string, pairId: string): Promise<Record<string, Object>> {
  if (!isUid(uid)) {
    return fail(BAD_REQUEST, 'uid malformed');
  }
  // 不查库：这条调用的频率由"项目快被回收了"决定，不由业务决定，任何一次读都是白付的配额。
  // pairId 只用来让日志能对上号；未配对时端侧传空串也是合法的存活信号。
  return ok({ 'paired': pairId !== '' });
}
