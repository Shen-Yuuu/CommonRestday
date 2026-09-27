import { cloudFunction } from '@kit.CloudFoundationKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { util } from '@kit.ArkTS';
import { Interval, SnapshotCodec } from 'domain';
import { EncryptedPayload, SnapshotCrypto, SNAPSHOT_SCHEMA_VERSION } from './SnapshotCrypto';
import { PairKeyStore } from './PairKeyStore';

/**
 * 云层接口与 AGC 调用封装（协议 v1：docs/cloud/pairing-protocol-v1.md）。
 *
 * 三件在这里收敛的事，页面与 usecase 不再各自处理：
 *
 * 1. **传输形态**：端云之间只有两个**云对象**——`pairing`（create/join/confirm/status/unpair/heartbeat）
 *    与 `snapshot`（put/get）。云对象的调用体固定是 `{ method, params }`（API 26 模拟器实测过的形态），
 *    不是把字段平铺进 data；平铺只有云函数形态才收得到。
 * 2. **超时**：显式 `timeout: 30000`。`FunctionParams.timeout` 的 SDK 默认是 70s，
 *    而云函数同步调用侧上限 55s——不传就会在慢请求上撞墙（spike §1）。
 *    两个云对象在控制台已设 **20s**（runbook §2.4 第 3 行），所以这里 30s 一定是外层：
 *    先断的是服务端，端侧收到的是回包而不是自己那侧的超时。
 * 3. **失败语义**：服务端返回 §3.4 的语义码，传输层异常归一成 `NETWORK`/`LOCAL`/`INTERNAL`；
 *    两者都抛 `CloudApiError`，带 `retryable`。云端任何失败都不得阻断本机（门禁 §4 第 4 条）。
 *
 * `calls` 计数器是"关闭态 0 次云调用"这条断言的落点（验收报告 B1），不要删。
 */

/** 云对象名（部署形态见 cloud-backend/README.md）。 */
export const OBJ_PAIRING = 'pairing';
export const OBJ_SNAPSHOT = 'snapshot';
/** 端侧统一超时；服务端同步调用上限 55s。 */
export const CLOUD_TIMEOUT_MS = 30000;

/** 语义码：传输层特有的三种（服务端的码见协议 §3.4，原样透传）。 */
export const CLOUD_LOCAL = 'LOCAL';
export const CLOUD_NETWORK = 'NETWORK';
export const CLOUD_MALFORMED = 'INTERNAL';

/** 快照信封（云侧存储单元，协议 §5.1）。字节字段一律 base64，authTag 独立成字段。 */
export interface CloudSnapshot {
  pairId: string;
  ownerUid: string;
  version: number;
  shareLevel: number;
  schemaVersion: number;
  algorithm: string;
  iv: string;
  authTag: string;
  ciphertext: string;
  updatedAt: number;
}

/** 配对会话投影：八个端点里凡返回会话状态的地方都用它，缺字段就是空串/0。 */
export interface PairSession {
  pairId: string;
  status: string;
  /** 一次性邀请码，仅 create 返回；不进链接、不进日志。 */
  code: string;
  peerUid: string;
  /** 对端 HUKS 公钥（base64，不透明字节）。 */
  peerPublicKey: string;
  /** 加入方拿到、由加入方经安全信道交回发起方的一次性确认凭据。 */
  confirmToken: string;
  expiresAt: number;
  serverTime: number;
}

/** 配对端点集合（协议 §4.1–§4.6）。 */
export interface PairingApi {
  createPairing(uid: string, publicKey: string): Promise<PairSession>;
  joinPairing(code: string, uid: string, publicKey: string): Promise<PairSession>;
  confirmPairing(pairId: string, uid: string, confirmToken: string): Promise<PairSession>;
  pairStatus(pairId: string, uid: string): Promise<PairSession>;
  /** 返回云侧被级联删除的快照条数。 */
  unpair(pairId: string, uid: string, requestId: string): Promise<number>;
  /** 防闲置回收的存活信号，不带任何业务载荷。 */
  heartbeat(uid: string, pairId: string): Promise<number>;
}

/** 快照端点集合（协议 §4.7–§4.8）。 */
export interface SnapshotSync {
  putSnapshot(pairId: string, ownerUid: string, version: number, shareLevel: number,
    payload: EncryptedPayload, requestId: string): Promise<number>;
  /**
   * 拉取对方的快照；返回 null = 没有比 sinceVersion 更新的快照（常态，不是错误）。
   *
   * `uid` 必须在参数里：一个 pair 下有两行快照（每人一行），服务端只有拿到调用方是谁
   * 才知道"对方"是哪一行，也才谈得上成员校验。少了它就只能要么全给、要么放弃鉴权。
   */
  getSnapshot(pairId: string, uid: string, sinceVersion: number): Promise<CloudSnapshot | null>;
}

/** 云端调用的统一失败形态：调用方按 semantic + retryable 决定提示与重试。 */
export class CloudApiError extends Error {
  readonly semantic: string;
  readonly retryable: boolean;

  constructor(semantic: string, retryable: boolean, message: string) {
    super(message);
    this.name = 'CloudApiError';
    this.semantic = semantic;
    this.retryable = retryable;
  }
}

/** 新幂等键：写类端点以 pairId + ownerUid + version + requestId 幂等（协议 §3.3）。 */
export function newRequestId(): string {
  return util.generateRandomUUID();
}

export class CloudGateway {
  /** 进程内云调用计数：只做计数、不做业务，读它不需要权限。 */
  static calls: number = 0;

  /**
   * 调一个云对象方法并剥开响应包络。
   * 传输异常与语义码失败都抛 CloudApiError；解包失败按 INTERNAL（不重试，先记缺陷）。
   */
  static async call(objectName: string, method: string, params: Object[]): Promise<Record<string, Object>> {
    CloudGateway.calls = CloudGateway.calls + 1;
    const data: Record<string, Object> = { 'method': method, 'params': params };
    let raw: string | Object;
    try {
      const value = await cloudFunction.call({
        name: objectName,
        version: '$latest',
        data: data,
        timeout: CLOUD_TIMEOUT_MS
      });
      raw = value.result;
    } catch (e) {
      throw CloudGateway.transportError(e as BusinessError);
    }
    return CloudGateway.unwrap(raw);
  }

  /**
   * 传输层错误归类。三条实测口径写在这里而不是散在调用点：
   * 201 是缺 INTERNET 权限、1008210009/1008211001 是 AGC 未初始化/未开通或签名与凭据不匹配，
   * 1008210001 是网络类。带 401/403 字样的服务端拒绝要还原成鉴权语义，否则用户看到的是"网络不好"。
   */
  private static transportError(be: BusinessError): CloudApiError {
    const text = (be.message === undefined ? '' : be.message).toLowerCase();
    const denied = text.indexOf('401') >= 0 || text.indexOf('403') >= 0
      || text.indexOf('permission') >= 0 || text.indexOf('forbidden') >= 0;
    if (denied) {
      return new CloudApiError('UNAUTHORIZED', false, '云端拒绝了这次调用');
    }
    if (be.code === 201 || be.code === 1008210009) {
      return new CloudApiError(CLOUD_LOCAL, false, 'AGC 云服务未初始化或未开通（' + be.code + '）');
    }
    if (be.code === 1008210001) {
      return new CloudApiError(CLOUD_NETWORK, true, '云端网络不可达（' + be.code + '）');
    }
    return new CloudApiError(CLOUD_MALFORMED, true, '云端调用失败（' + be.code + '）');
  }

  /** 包络解析：string / object 两种回包形态都兼容（云侧返回体不保证已是对象）。 */
  private static unwrap(raw: string | Object): Record<string, Object> {
    let o: Record<string, Object>;
    try {
      const text = typeof raw === 'string' ? raw : JSON.stringify(raw);
      o = JSON.parse(text === '' ? '{}' : text) as Record<string, Object>;
    } catch (e) {
      throw new CloudApiError(CLOUD_MALFORMED, false, '云端回包无法解析');
    }
    const code = CloudGateway.strOf(o, 'code');
    if (code === 'OK') {
      return o;
    }
    const semantic = code === '' ? CLOUD_MALFORMED : code;
    const retryable = semantic === 'QUOTA_EXHAUSTED' || semantic === 'TIMEOUT' || semantic === CLOUD_MALFORMED;
    throw new CloudApiError(semantic, retryable, CloudGateway.strOf(o, 'message'));
  }

  static strOf(o: Record<string, Object>, key: string): string {
    const v = o[key];
    return v == null ? '' : String(v);
  }

  static numOf(o: Record<string, Object>, key: string): number {
    const v = o[key];
    if (v == null) {
      return 0;
    }
    const n = Number(v);
    return Number.isNaN(n) ? 0 : n;
  }
}

/** 会话投影：服务端没给的字段留空串/0，调用方按 status 判断而不是按字段是否为空判断。 */
function sessionOf(o: Record<string, Object>): PairSession {
  const session: PairSession = {
    pairId: CloudGateway.strOf(o, 'pairId'),
    status: CloudGateway.strOf(o, 'status'),
    // 线上字段名是 inviteCode 不是 code：`code` 被包络的语义码占用，同名会互相顶掉（协议 §3.2）
    code: CloudGateway.strOf(o, 'inviteCode'),
    peerUid: CloudGateway.strOf(o, 'peerUid'),
    peerPublicKey: CloudGateway.strOf(o, 'peerPublicKey'),
    confirmToken: CloudGateway.strOf(o, 'confirmToken'),
    expiresAt: CloudGateway.numOf(o, 'expiresAt'),
    serverTime: CloudGateway.numOf(o, 'serverTime')
  };
  return session;
}

/** AGC 云对象配对客户端（PairingApi 实现）。AGC 未就绪时每个方法都抛 CloudApiError，由调用方降级。 */
export class AgcPairingClient implements PairingApi {
  async createPairing(uid: string, publicKey: string): Promise<PairSession> {
    const o = await CloudGateway.call(OBJ_PAIRING, 'create', [uid, publicKey, SNAPSHOT_SCHEMA_VERSION]);
    return sessionOf(o);
  }

  async joinPairing(code: string, uid: string, publicKey: string): Promise<PairSession> {
    const o = await CloudGateway.call(OBJ_PAIRING, 'join', [code, uid, publicKey, SNAPSHOT_SCHEMA_VERSION]);
    return sessionOf(o);
  }

  async confirmPairing(pairId: string, uid: string, confirmToken: string): Promise<PairSession> {
    const o = await CloudGateway.call(OBJ_PAIRING, 'confirm', [pairId, uid, confirmToken]);
    return sessionOf(o);
  }

  async pairStatus(pairId: string, uid: string): Promise<PairSession> {
    const o = await CloudGateway.call(OBJ_PAIRING, 'status', [pairId, uid]);
    return sessionOf(o);
  }

  async unpair(pairId: string, uid: string, requestId: string): Promise<number> {
    const o = await CloudGateway.call(OBJ_PAIRING, 'unpair', [pairId, uid, requestId]);
    return CloudGateway.numOf(o, 'deletedVersions');
  }

  async heartbeat(uid: string, pairId: string): Promise<number> {
    const o = await CloudGateway.call(OBJ_PAIRING, 'heartbeat', [uid, pairId]);
    return CloudGateway.numOf(o, 'serverTime');
  }
}

/**
 * AGC 云对象快照客户端（SnapshotSync 实现）。
 * get 返回 null 表示"无更新"，调用方沿用最后一次有效快照或本机代录。
 */
export class AgcSnapshotSync implements SnapshotSync {
  async putSnapshot(pairId: string, ownerUid: string, version: number, shareLevel: number,
    payload: EncryptedPayload, requestId: string): Promise<number> {
    const envelope: Record<string, Object> = {
      'schemaVersion': SNAPSHOT_SCHEMA_VERSION,
      'algorithm': payload.algorithm,
      'iv': payload.iv,
      'authTag': payload.authTag,
      'ciphertext': payload.ciphertext
    };
    const o = await CloudGateway.call(OBJ_SNAPSHOT, 'put',
      [pairId, ownerUid, version, shareLevel, envelope, requestId]);
    return CloudGateway.numOf(o, 'storedVersion');
  }

  async getSnapshot(pairId: string, uid: string, sinceVersion: number): Promise<CloudSnapshot | null> {
    const o = await CloudGateway.call(OBJ_SNAPSHOT, 'get', [pairId, uid, sinceVersion]);
    const snap = o['snapshot'];
    if (snap == null) {
      return null;
    }
    return AgcSnapshotSync.parseSnapshot(snap, pairId, sinceVersion);
  }

  /** 服务端已按成员表与 version 过滤，这里只做一次乱序兜底与字段完整性检查。 */
  static parseSnapshot(raw: Object, pairId: string, sinceVersion: number): CloudSnapshot | null {
    let o: Record<string, Object>;
    try {
      const text = typeof raw === 'string' ? raw : JSON.stringify(raw);
      o = JSON.parse(text === '' ? '{}' : text) as Record<string, Object>;
    } catch (e) {
      throw new CloudApiError(CLOUD_MALFORMED, false, '快照回包无法解析');
    }
    const version = CloudGateway.numOf(o, 'version');
    if (version <= sinceVersion) {
      return null;
    }
    const ciphertext = CloudGateway.strOf(o, 'ciphertext');
    const iv = CloudGateway.strOf(o, 'iv');
    const authTag = CloudGateway.strOf(o, 'authTag');
    if (ciphertext === '' || iv === '' || authTag === '') {
      return null;
    }
    const snap: CloudSnapshot = {
      pairId: CloudGateway.strOf(o, 'pairId') === '' ? pairId : CloudGateway.strOf(o, 'pairId'),
      ownerUid: CloudGateway.strOf(o, 'ownerUid'),
      version: version,
      shareLevel: CloudGateway.numOf(o, 'shareLevel'),
      schemaVersion: CloudGateway.numOf(o, 'schemaVersion'),
      algorithm: CloudGateway.strOf(o, 'algorithm'),
      iv: iv,
      authTag: authTag,
      ciphertext: ciphertext,
      updatedAt: CloudGateway.numOf(o, 'updatedAt')
    };
    return snap;
  }
}

/**
 * 拉到的加密快照 → 引擎可用的对方忙碌区间。
 *
 * 密钥由 `PairKeyStore` 按 pairId 别名在 HUKS 内解密，本函数拿不到也不需要拿到密钥材料；
 * AAD 用快照自带的明文元数据重算，所以"把 A 的密文搬到 B 名下"在这里就是 null。
 * 解密或解码失败一律 null，调用方据此降级本机代录（不删对方数据、不进半同步态）。
 * 快照产出时已并入对方缓冲，接收侧不再二次加缓冲。
 */
export async function partnerIntervalsFromSnapshot(snap: CloudSnapshot, pairId: string): Promise<Interval[] | null> {
  const payload: EncryptedPayload = {
    iv: snap.iv,
    authTag: snap.authTag,
    ciphertext: snap.ciphertext,
    algorithm: snap.algorithm
  };
  const plain = await PairKeyStore.open(pairId, aadOfSnapshot(snap), payload);
  if (plain === null) {
    return null;
  }
  const data = SnapshotCodec.decode(plain);
  if (data === null) {
    return null;
  }
  return SnapshotCodec.toIntervals(data);
}

/**
 * 快照 AAD 的唯一构造口径（协议 §5.1：`pairId|ownerUid|version|schemaVersion`）。
 * 写侧在 ScheduleUseCase 里按自己的 pairId/uid/version 组同一串，读侧从信封明文元数据重组，
 * 所以这个函数必须是导出的——两侧各写一份就会漂，一漂就是"永远解密失败"。
 */
export function aadOfSnapshot(snap: CloudSnapshot): string {
  return SnapshotCrypto.aadOf(snap.pairId, snap.ownerUid, snap.version, snap.schemaVersion);
}

export function aadOf(pairId: string, ownerUid: string, version: number,
  schemaVersion: number = SNAPSHOT_SCHEMA_VERSION): string {
  return SnapshotCrypto.aadOf(pairId, ownerUid, version, schemaVersion);
}
