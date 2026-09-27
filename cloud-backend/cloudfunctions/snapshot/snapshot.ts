/*
 * 两人份 · 快照云对象（协议 v1 §4.7–§4.8）。
 *
 * 这个云对象只做一件事：**搬运密文**。它不解密、不解析明文、不看日程内容，
 * 所以它被入侵也泄不出日程——能泄出的是元数据（uid / pairId / version / shareLevel / 时间戳）
 * 与配额。这条边界是协议 §5.2 允许明文列清单的全部理由。
 *
 * 参数顺序同样是线上契约（端侧 `cloud/src/main/ets/api/CloudApi.ets` 按位置传参）。
 *
 * 已知边界（协议 §6.1 记在案，不是本文件的实现缺陷）：uid 由端侧自证，而 pair 密钥是双方共有的，
 * 所以已配对的任一方都能往对方名下写一份版本更高的密文——能影响到的是对方界面显示的忙碌段，
 * 读不到对方的明文日程。要彻底堵住需要按方向拆密钥，但接收方必须持有发送方的解密钥，做不到分离。
 */

import {
  BAD_REQUEST, CONFLICT_VERSION, FORBIDDEN, MAX_CIPHER_B64_LEN, NOT_FOUND, SCHEMA_UNSUPPORTED,
  SCHEMA_VERSION, ST_ACTIVE, fail, guarded, isMember, isUid, loadSession, loadSnapshot,
  nowMs, num, ok, peerUidOf, roleOf, saveSnapshot, str
} from './contract';

/** 端侧 SnapshotBuilder 的档位：0 不共享，1 只同休日，2 忙碌/空闲，3 全量细节。 */
const MIN_SHARE_LEVEL = 0;
const MAX_SHARE_LEVEL = 3;
/** 与端侧 SnapshotCrypto.ALG_AES_256_GCM 对齐；云侧不实现第二种算法，也不准备"以后可能加"。 */
const ALG = 'AES-256-GCM';

function asInt(value: number): number {
  const n = Number(value);
  return Number.isNaN(n) ? -1 : Math.floor(n);
}

/*
 * 公开方法**不许碰 `this`**，这是线上实测出来的约束，不是风格偏好。
 *
 * 云对象框架按 `func.apply(?, data.params)` 派发（2026-09-27 探针：`params` 传字符串会得到 V8 的
 * `CreateListFromArrayLike called on non-object`，说明实参确实按位置展开），
 * 但被调起来的函数**不绑定在实例上**。写成 `guarded(() => this.doPut(...))` 时每一次调用都在读库前
 * 抛 `Cannot read properties of undefined (reading 'doPut')`，被 guarded 塌成
 * `{"code":"INTERNAL","message":"cloud error "}`（尾部没有 dbCode）。向导样本
 * `IdGenerator.randomUUID()` 一个 `this` 都不用，所以把这个坑掩盖到了第一次真调用。
 *
 * 所以下面只留一层薄壳：公开方法转调模块级函数，函数体里也没有 `this`。
 */
export class Snapshot {
  /**
   * §4.7 写入我的快照。
   *
   * `ownerUid` 就是这里的调用方身份（自证）：只有该 pair 的成员能往自己名下写，
   * 写别人名下会在这里被拒——"每人一行 + 主键含 ownerUid"是代录互相覆写那条缺陷在云侧的同类防线。
   */
  async put(pairId: string, ownerUid: string, version: number, shareLevel: number,
    envelope: Record<string, Object>, requestId: string): Promise<Record<string, Object>> {
    return guarded(() => doPut(pairId, ownerUid, version, shareLevel, envelope, requestId));
  }

  /**
   * §4.8 拉取对方的快照。
   * 没有更新 = `ok({})`（回包里没有 snapshot 字段），不是错误；端侧据此沿用最后一次有效数据。
   */
  async get(pairId: string, uid: string, sinceVersion: number): Promise<Record<string, Object>> {
    return guarded(() => doGet(pairId, uid, sinceVersion));
  }
}

async function doPut(pairId: string, ownerUid: string, version: number, shareLevel: number,
  envelope: Record<string, Object>, requestId: string): Promise<Record<string, Object>> {
  if (!isUid(ownerUid)) {
    return fail(BAD_REQUEST, 'ownerUid malformed');
  }
  const session = await loadSession(pairId);
  if (session === null) {
    return fail(NOT_FOUND, 'no such session');
  }
  if (!isMember(session, ownerUid)) {
    // 只有该 pair 的成员能往自己名下写：这一条挡住"外人往 pair 里塞密文"——
    // 接收侧的 AAD（含 ownerUid）还会再挡一次，两道都不依赖云侧可信
    return fail(FORBIDDEN, 'owner is not a member');
  }
  if (str(session, 'status') !== ST_ACTIVE) {
    return fail(BAD_REQUEST, 'pair is not active yet');
  }
  const env = envelope == null ? {} : envelope;
  const schemaVersion = asInt(num(env, 'schemaVersion'));
  if (schemaVersion !== SCHEMA_VERSION) {
    return fail(SCHEMA_UNSUPPORTED, 'snapshot schemaVersion ' + schemaVersion);
  }
  const algorithm = str(env, 'algorithm');
  const iv = str(env, 'iv');
  const authTag = str(env, 'authTag');
  const ciphertext = str(env, 'ciphertext');
  if (algorithm !== ALG) {
    return fail(BAD_REQUEST, 'unsupported algorithm');
  }
  // iv/authTag 的长度由端侧 SnapshotCrypto 固定（12B/16B → base64 16/24 字符），这里只保证不落空
  if (iv === '' || authTag === '' || ciphertext === '') {
    return fail(BAD_REQUEST, 'envelope incomplete');
  }
  if (ciphertext.length > MAX_CIPHER_B64_LEN) {
    return fail(BAD_REQUEST, 'payload exceeds 2MB');
  }
  const v = asInt(version);
  if (v <= 0) {
    return fail(BAD_REQUEST, 'version must be positive');
  }
  const level = asInt(shareLevel);
  if (level < MIN_SHARE_LEVEL || level > MAX_SHARE_LEVEL) {
    return fail(BAD_REQUEST, 'shareLevel out of range');
  }
  const stored = await loadSnapshot(pairId, ownerUid);
  if (stored !== null) {
    const cur = num(stored, 'version');
    if (v < cur) {
      // 落后版本（协议 §9：旧包晚到）：端侧丢弃本地待发、改为拉取；本机游标只会向前，所以自愈
      return fail(CONFLICT_VERSION, 'version behind stored');
    }
    if (v === cur) {
      if (str(stored, 'ciphertext') === ciphertext && str(stored, 'iv') === iv) {
        // 同一份重放（响应丢在路上的重试）：幂等成功，不再写一次
        return ok({ 'storedVersion': v, 'requestId': requestId });
      }
      return fail(CONFLICT_VERSION, 'same version different payload');
    }
  }
  await saveSnapshot({
    'pairId': pairId,
    'ownerUid': ownerUid,
    'peerUid': peerUidOf(session, ownerUid),
    'version': v,
    'shareLevel': level,
    'schemaVersion': schemaVersion,
    'algorithm': algorithm,
    'iv': iv,
    'authTag': authTag,
    'ciphertext': ciphertext,
    'updatedAt': nowMs()
  });
  return ok({ 'storedVersion': v, 'requestId': requestId });
}

/**
 * §4.8 拉取对方的快照。
 * 没有更新 = `ok({})`（回包里没有 snapshot 字段），不是错误；端侧据此沿用最后一次有效数据。
 */
async function doGet(pairId: string, uid: string,
  sinceVersion: number): Promise<Record<string, Object>> {
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
  const peer = peerUidOf(session, uid);
  if (peer === '') {
    // 对方还没加入：没有可给的东西，也不该因此报错（端侧走本机代录）
    return ok({});
  }
  const snapshot = await loadSnapshot(pairId, peer);
  if (snapshot === null || num(snapshot, 'version') <= asInt(sinceVersion)) {
    return ok({});
  }
  return ok({ 'snapshot': snapshot });
}

