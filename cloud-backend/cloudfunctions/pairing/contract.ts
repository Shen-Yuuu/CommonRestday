/*
 * 两人份 · 云对象共用契约（协议 v1：docs/cloud/pairing-protocol-v1.md）。
 *
 * 这个文件在 cloudfunctions/pairing/ 与 cloudfunctions/snapshot/ 里是**同一份**：
 * 云对象的部署包只含自己那个目录，所以共享代码必须按目录复制。
 * 防漂移的核对命令见 cloud-backend/README.md §4。
 *
 * 四类口径收在这一处，两个云对象不许各写一份：
 * 1. 语义码与响应包络（协议 §3.2 / §3.4）；
 * 2. 存储区名、TTL、字段长度上限；
 * 3. 成员与会话状态的判定（谁是这个 pair 的成员、现在能不能读写）；
 * 4. 云数据库的读写口（行 → 普通对象一律走 getter，写一律走 upsert 全量覆盖）。
 */

import { cloud, Region } from '@hw-agconnect/cloud-server';
import * as crypto from 'crypto';

const { PairSession } = require('./PairSession');
const { PairSnapshot } = require('./PairSnapshot');

/** 存储区名：AGC 实测拒绝下划线形态（`invalid CloudDBZone name`），只能用大小写混合的名。 */
const ZONE = 'FortwoPair';
/** AGCClient 实例名：固定名才有 warm 复用，每次换一个名等于每次新建客户端。 */
const INSTANCE = 'fortwo-pair';
/** 本协议的 schemaVersion；不匹配一律 SCHEMA_UNSUPPORTED，禁止静默降级写入（协议 §3.4）。
 * `2`：响应里的邀请码字段从 `code` 改名为 `inviteCode`——`code` 是包络保留名（语义码），
 * 两者同名会互相覆盖，线上实测把 `create` 的成功判定整个打掉（协议 §3.2 / runbook §2.4 第 13 行）。 */
export const SCHEMA_VERSION = 2;
/** 配对码与待确认会话的存活时长：跨设备、跨聊天软件的一次配对，24 小时够得着又不至于长期敞开。 */
export const SESSION_TTL_MS = 24 * 60 * 60 * 1000;
/** 一次性确认凭据的字节数：32 个 base64url 字符 ≈192 bit，远高于端侧 22 字符下限。 */
const TOKEN_BYTES = 24;
/** String 字段在 Server SDK 里硬限 200 字符（DataModelHelper 的 MAX_STRING_LENGTH）；uid/公钥都够不到。 */
const MAX_ID_LEN = 128;
const MAX_PUBKEY_LEN = 200;
/** 密文按 2 MB 原始字节收口（协议 §4.7）；端侧真实量级是几十 KB，留的是格式余量不是业务余量。 */
const MAX_CIPHER_BYTES = 2 * 1000 * 1000;
/** 落库的是 base64，膨胀 4/3；比较时用字符数，避免为算字节长度再解一次码。 */
export const MAX_CIPHER_B64_LEN = Math.ceil(MAX_CIPHER_BYTES / 3) * 4;

/** 会话状态（协议 §8）。本机四态与这里的对应关系见 docs/cloud/pairing-protocol-v1.md §8。 */
export const ST_WAITING = 'WAITING';
export const ST_PENDING = 'PENDING_CONFIRM';
export const ST_ACTIVE = 'ACTIVE';
export const ST_EXPIRED = 'EXPIRED';
export const ST_REVOKED = 'REVOKED';

/** §3.4 的语义码：云侧只用这一组字符串，端侧原样消费。 */
export const OK = 'OK';
export const BAD_REQUEST = 'BAD_REQUEST';
export const UNAUTHORIZED = 'UNAUTHORIZED';
export const FORBIDDEN = 'FORBIDDEN';
export const NOT_FOUND = 'NOT_FOUND';
export const CODE_EXPIRED = 'CODE_EXPIRED';
export const CODE_TAKEN = 'CODE_TAKEN';
export const CONFLICT_VERSION = 'CONFLICT_VERSION';
export const SCHEMA_UNSUPPORTED = 'SCHEMA_UNSUPPORTED';
export const QUOTA_EXHAUSTED = 'QUOTA_EXHAUSTED';
export const INTERNAL = 'INTERNAL';

/** 语义码 → 端侧是否值得退避重试（协议 §3.4 表）。 */
const RETRYABLE: Record<string, boolean> = {
  QUOTA_EXHAUSTED: true, TIMEOUT: true, INTERNAL: true
};

/**
 * 下面三个接口只声明本文件真正用到的那几下，不把 SDK 的类型透出去。
 *
 * 原因是 DevEco 的云对象接口生成器会顺着 handler 的 `.d.ts` 找依赖，见到第三方 import 就
 * `Dependency Error! Can not have third-party dependencies!` 并 `process.exit(100)`。
 * 对外签名只留原生类型与本地结构，这条检查才不会被触发（spike 的 `spikeDb.ts` 同理）。
 */
interface QueryLike {
  equalTo(field: string, value: string | number): QueryLike;
  get(): Promise<Object[]>;
}

interface CollectionLike {
  query(): QueryLike;
  upsert(row: Record<string, Object>): Promise<number>;
  delete(rows: Object[]): Promise<number>;
}

interface ZoneLike {
  collection(model: Object): CollectionLike;
}

/** 每次调用新建：`createInstance` 建的是本地句子，真正的连接与鉴权在请求里，跨调用缓存省不下什么。 */
function zone(): ZoneLike {
  return (cloud.createInstance(undefined, INSTANCE, Region.REGION_CN)
    .database({ zoneName: ZONE }) as unknown) as ZoneLike;
}

/** 数据库行是带 getter 的模型实例（spike 实测读法就是 `getId()`），所以映射只认 getter。 */
interface SessionRow {
  getPairId(): string;
  getStatus(): string;
  getCode(): string;
  getCreatorUid(): string;
  getCreatorPublicKey(): string;
  getJoinerUid(): string;
  getJoinerPublicKey(): string;
  getConfirmToken(): string;
  getSchemaVersion(): number;
  getCreatedAt(): number;
  getUpdatedAt(): number;
  getExpiresAt(): number;
}

interface SnapshotRow {
  getPairId(): string;
  getOwnerUid(): string;
  getPeerUid(): string;
  getVersion(): number;
  getShareLevel(): number;
  getSchemaVersion(): number;
  getAlgorithm(): string;
  getIv(): string;
  getAuthTag(): string;
  getCiphertext(): string;
  getUpdatedAt(): number;
}

export function nowMs(): number {
  return Date.now();
}

function uuid(): string {
  return crypto.randomUUID();
}
/** 6 位数字配对码：只用于 pairing-join，有 TTL，用过即废（协议 §2）。 */
function inviteCode(): string {
  return String(crypto.randomInt(0, 1000000)).padStart(6, '0');
}

/**
 * 一次性确认凭据：必须是 base64url 且**不带 `=` 填充**。
 * 端侧 PairLink.tokenValid 只接受 A–Za–z0–9-_，长度 22–128，多一个字符整条链接就判 MALFORMED。
 */
export function confirmToken(): string {
  return crypto.randomBytes(TOKEN_BYTES).toString('base64url');
}

/** 新会话行：`code` 的占用检查与写入之间没有事务，所以调用方要自己带上冲突重试。 */
export function newSessionRow(uid: string, publicKey: string): Record<string, Object> {
  const at = nowMs();
  return {
    'pairId': uuid(),
    'status': ST_WAITING,
    'code': inviteCode(),
    'creatorUid': uid,
    'creatorPublicKey': publicKey,
    'joinerUid': '',
    'joinerPublicKey': '',
    'confirmToken': '',
    'schemaVersion': SCHEMA_VERSION,
    'createdAt': at,
    'updatedAt': at,
    'expiresAt': at + SESSION_TTL_MS
  };
}

/** 成功包络：字段由调用方追加（协议 §3.2）。 */
export function ok(extra: Record<string, Object>): Record<string, Object> {
  // 包络四键最后钉，业务字段不许顶掉它们——同名字段的两种坏法里，"语义码被顶掉"会让
  // 端侧把每一次成功调用都当失败（线上实测过一次），所以这里宁可丢业务字段并把它写进探针断言。
  const body: Record<string, Object> = {};
  for (const key of Object.keys(extra)) {
    body[key] = extra[key];
  }
  body['code'] = OK;
  body['message'] = '';
  body['retryable'] = false;
  body['serverTime'] = nowMs();
  return body;
}

/**
 * 失败包络：message 是**面向日志的英文短语**，端侧不会把它念给用户（协议 §3.2）。
 * 所以这里可以写清楚是哪一步炸的，帮助在 AGC 日志里定位，而不必担心泄露用户内容。
 */
export function fail(code: string, message: string): Record<string, Object> {
  return {
    'code': code, 'message': message,
    'retryable': code in RETRYABLE ? RETRYABLE[code] : false,
    'serverTime': nowMs()
  };
}

/**
 * Server SDK 的错误码（`CloudDBErrorCode`，字符串形态）→ §3.4 语义码。
 *
 * 只列本产品真的会撞到的那几条：配额与限流必须翻成 QUOTA_EXHAUSTED（端侧据此今天收手），
 * `2001015` 出现在云函数内部意味着**权限配置错了**（运维手册 §4.3），
 * 其余一律 INTERNAL，不猜语义、不把 SDK 原文透给端侧。
 */
const DB_CODE_MAP: Record<string, string> = {
  '3007014': QUOTA_EXHAUSTED,
  '3007009': QUOTA_EXHAUSTED,
  '2001015': FORBIDDEN,
  '3007004': UNAUTHORIZED,
  '2016': UNAUTHORIZED,
  '2048': UNAUTHORIZED,
  '2060': BAD_REQUEST,
  '2003': BAD_REQUEST,
  '2001020': BAD_REQUEST,
  '3037006': BAD_REQUEST
};

/**
 * 云对象方法的统一外壳：任何异常都收敛成 §3.2 的失败包络。
 * 端侧的 `unwrap` 要求回包一定是带 `code` 的 JSON，抛出未捕获异常等于把语义码换成传输层错误。
 */
export async function guarded(run: () => Promise<Record<string, Object>>): Promise<Record<string, Object>> {
  try {
    return await run();
  } catch (e) {
    const err = e as { code?: Object; message?: Object };
    const raw = err.code === undefined ? '' : String(err.code);
    const semantic = raw in DB_CODE_MAP ? DB_CODE_MAP[raw] : INTERNAL;
    // 日志只留码与英文短语：载荷、密钥、配对码一律不打（运维手册 §6）
    console.error('cloud-object ' + semantic + ' dbCode=' + raw
      + ' msg=' + (err.message === undefined ? '' : String(err.message)));
    return fail(semantic, 'cloud error ' + raw);
  }
}

/** 行内改字段：CloudDB 没有列级更新，读—改—整行覆盖是这里唯一的写法。 */
export function patchSession(session: Record<string, Object>,
  patch: Record<string, Object>): Record<string, Object> {
  const next: Record<string, Object> = {};
  for (const key of Object.keys(session)) {
    next[key] = session[key];
  }
  for (const key of Object.keys(patch)) {
    next[key] = patch[key];
  }
  next['updatedAt'] = nowMs();
  return next;
}

/**
 * 一次性凭据比较：定长随机串，用 `timingSafeEqual` 是为了不给"逐字节试探"留时间侧信道。
 * 长度不等直接 false——长度不是秘密（格式固定 32 字符），所以这里不构成信息泄露。
 */
export function tokenEquals(left: string, right: string): boolean {
  if (left === '' || right === '' || left.length !== right.length) {
    return false;
  }
  return crypto.timingSafeEqual(Buffer.from(left, 'utf8'), Buffer.from(right, 'utf8'));
}

export function str(o: Record<string, Object>, key: string): string {
  const v = o[key];
  return v == null ? '' : String(v);
}

export function num(o: Record<string, Object>, key: string): number {
  const v = o[key];
  if (v == null) {
    return 0;
  }
  const n = Number(v);
  return Number.isNaN(n) ? 0 : n;
}

/** 入参守卫：端侧传来的都是进程外输入，长度与字符集不合规就 BAD_REQUEST，不带进数据库。 */
export function isUid(text: string): boolean {
  return text.length >= 8 && text.length <= MAX_ID_LEN && /^[0-9a-fA-F-]+$/.test(text);
}

export function isPublicKey(text: string): boolean {
  return text.length > 0 && text.length <= MAX_PUBKEY_LEN && /^[A-Za-z0-9+/=]+$/.test(text);
}

export function isCode(text: string): boolean {
  return /^\d{6}$/.test(text);
}

/** 会话是否已经过期（过期是**读出来才发现**的，所以调用方拿到 true 时要顺手落一次 EXPIRED）。 */
export function expired(session: Record<string, Object>, at: number): boolean {
  const status = str(session, 'status');
  if (status !== ST_WAITING && status !== ST_PENDING) {
    return false;
  }
  return num(session, 'expiresAt') <= at;
}

/** 双人语义下的"对端"：调用方是发起方就给加入方，反之亦然；不是成员就返回空串。 */
export function roleOf(session: Record<string, Object>, uid: string): string {
  if (str(session, 'creatorUid') === uid) {
    return 'creator';
  }
  if (str(session, 'joinerUid') === uid) {
    return 'joiner';
  }
  return '';
}

export function isMember(session: Record<string, Object>, uid: string): boolean {
  return roleOf(session, uid) !== '';
}

export function peerUidOf(session: Record<string, Object>, uid: string): string {
  return roleOf(session, uid) === 'creator'
    ? str(session, 'joinerUid') : str(session, 'creatorUid');
}

export function peerKeyOf(session: Record<string, Object>, uid: string): string {
  return roleOf(session, uid) === 'creator'
    ? str(session, 'joinerPublicKey') : str(session, 'creatorPublicKey');
}

/**
 * 会话投影：只挑端侧要用的字段。
 *
 * `inviteCode` 与 `confirmToken` 由调用方**按端点决定是否附上**——
 * §4.4 的 status 绝不能带 confirmToken，否则加入方查一次状态就能自确认，§4.3 的门槛塌掉。
 *
 * 邀请码在**库里那列叫 `code`**，但在回包里必须叫 `inviteCode`：包络的语义码占用了 `code`
 * （协议 §3.2），同名会让 `ok()` 把成功判定顶掉。端侧 `PairSession.code` 读的是 `inviteCode`。
 */
export function sessionBody(session: Record<string, Object>, uid: string,
  withCode: boolean, withToken: boolean): Record<string, Object> {
  const body: Record<string, Object> = {
    'pairId': str(session, 'pairId'),
    'status': str(session, 'status'),
    'peerUid': peerUidOf(session, uid),
    'peerPublicKey': peerKeyOf(session, uid),
    'expiresAt': num(session, 'expiresAt')
  };
  if (withCode) {
    body['inviteCode'] = str(session, 'code');
  }
  if (withToken) {
    body['confirmToken'] = str(session, 'confirmToken');
  }
  return body;
}

function toSession(row: Object): Record<string, Object> {
  const r = row as SessionRow;
  return {
    'pairId': r.getPairId(),
    'status': r.getStatus(),
    'code': r.getCode(),
    'creatorUid': r.getCreatorUid(),
    'creatorPublicKey': r.getCreatorPublicKey(),
    'joinerUid': r.getJoinerUid(),
    'joinerPublicKey': r.getJoinerPublicKey(),
    'confirmToken': r.getConfirmToken(),
    'schemaVersion': r.getSchemaVersion(),
    'createdAt': r.getCreatedAt(),
    'updatedAt': r.getUpdatedAt(),
    'expiresAt': r.getExpiresAt()
  };
}

function toSnapshot(row: Object): Record<string, Object> {
  const r = row as SnapshotRow;
  return {
    'pairId': r.getPairId(),
    'ownerUid': r.getOwnerUid(),
    'peerUid': r.getPeerUid(),
    'version': r.getVersion(),
    'shareLevel': r.getShareLevel(),
    'schemaVersion': r.getSchemaVersion(),
    'algorithm': r.getAlgorithm(),
    'iv': r.getIv(),
    'authTag': r.getAuthTag(),
    'ciphertext': r.getCiphertext(),
    'updatedAt': r.getUpdatedAt()
  };
}

/** 会话读取：pairId 是主键，命中 0 行就是没有这个会话（调用方回 NOT_FOUND）。 */
export async function loadSession(pairId: string): Promise<Record<string, Object> | null> {
  const rows = await zone().collection(PairSession).query().equalTo('pairId', pairId).get();
  return rows.length === 0 ? null : toSession(rows[0]);
}

/** 配对码反查（加入方只有码，没有 pairId）。 */
export async function findSessionByCode(code: string): Promise<Record<string, Object> | null> {
  const rows = await zone().collection(PairSession).query().equalTo('code', code).get();
  return rows.length === 0 ? null : toSession(rows[0]);
}

/**
 * 发起方手上还没走完的会话（WAITING / PENDING_CONFIRM）：重新生成配对码时要把上一张作废掉。
 *
 * ACTIVE 不在其列——已经配好的两个人不该因为谁多点了一次按钮就被拆开，
 * 而 PENDING 也要作废，是因为发起方一旦换了 pairId，旧会话的确认路径就再也接不上了。
 * 一个用户名下的未完成会话按产品形态就是个位数，所以状态在内存里筛，不加第二条索引。
 */
export async function findOpenByCreator(uid: string): Promise<Record<string, Object>[]> {
  const rows = await zone().collection(PairSession).query().equalTo('creatorUid', uid).get();
  const open: Record<string, Object>[] = [];
  for (const row of rows) {
    const session = toSession(row);
    const status = str(session, 'status');
    if (status === ST_WAITING || status === ST_PENDING) {
      open.push(session);
    }
  }
  return open;
}


export async function loadSnapshot(pairId: string, ownerUid: string): Promise<Record<string, Object> | null> {
  const rows = await zone().collection(PairSnapshot).query()
    .equalTo('pairId', pairId).equalTo('ownerUid', ownerUid).get();
  return rows.length === 0 ? null : toSnapshot(rows[0]);
}

/** 一个 pair 的全部快照（解除配对时级联删）；每人一行，最多两行。 */
export async function listSnapshotRows(pairId: string): Promise<Object[]> {
  return await zone().collection(PairSnapshot).query().equalTo('pairId', pairId).get();
}

export async function saveSession(row: Record<string, Object>): Promise<void> {
  await zone().collection(PairSession).upsert(row);
}

export async function saveSnapshot(row: Record<string, Object>): Promise<void> {
  await zone().collection(PairSnapshot).upsert(row);
}

/** 级联删除：把查到的行原样交给 delete，主键由行自己带，不需要二次拼装。 */
export async function deleteSnapshots(rows: Object[]): Promise<number> {
  if (rows.length === 0) {
    return 0;
  }
  return await zone().collection(PairSnapshot).delete(rows);
}

export async function deleteSessionRow(pairId: string): Promise<number> {
  return await zone().collection(PairSession).delete([{ 'pairId': pairId }]);
}
