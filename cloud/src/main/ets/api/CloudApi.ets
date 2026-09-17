import { cloudFunction } from '@kit.CloudFoundationKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { Interval, SnapshotCodec } from 'domain';
import { EncryptedPayload, SnapshotCrypto } from './SnapshotCrypto';

/**
 * 云层接口定义与 AGC 调用封装（US9 / FR-015）。
 * 云端只承载：配对会话 + AES-256-GCM 加密快照密文；云函数不可读内容。
 * AGC 未开通/未初始化时 cloudFunction.call 会抛 BusinessError，
 * 由 AgcPairingClient/AgcSnapshotSync 统一转为 CloudApiError，调用方据此降级
 * （提示 + 引导本机代录），不得影响本机功能与稳定性。
 * 云函数（pairing-xxx / snapshot-xxx）尚未部署到 AGC——AGC 就绪后生效，未就绪时全部走降级路径。
 */

/** 云端快照元数据。 */
export interface CloudSnapshot {
  pairId: string;
  ownerUid: string;
  version: number;
  shareLevel: number;
  /** 密文（hex，含拼接的 authTag）。 */
  ciphertext: string;
  /** 12 字节随机 IV（hex）。 */
  iv: string;
  updatedAt: number;
}

/** 配对会话。 */
export interface PairingSession {
  sessionId: string;
  code: string;
  creatorUid: string;
  status: string;
  expiresAt: number;
}

/** 快照同步接口（AgcSnapshotSync 为 AGC 实现）。 */
export interface SnapshotSync {
  pushSnapshot(pairId: string, version: number, shareLevel: number, payload: EncryptedPayload): Promise<void>;
  pullSnapshot(pairId: string, sinceVersion: number): Promise<CloudSnapshot | null>;
}

/** 配对接口：端侧实现类接入 Cloud Foundation Kit 云函数（AgcPairingClient）。 */
export interface PairingApi {
  createPairing(uid: string): Promise<PairingSession>;
  /** 输码加入：code 为对方分享的 6 位邀请码；成功返回配对会话（sessionId 即 pairId）。 */
  joinPairing(code: string, uid: string): Promise<PairingSession>;
  unpair(pairId: string, uid: string): Promise<void>;
}

/** 云端调用统一降级错误（调用方捕获后降级，不崩溃）。 */
export class CloudApiError extends Error {
  /** 1001 = AGC 未初始化/未开通；1002 = 网络失败/其他调用异常。 */
  readonly code: number;

  constructor(code: number, message: string) {
    super(message);
    this.name = 'CloudApiError';
    this.code = code;
  }
}

/**
 * 本地生成 6 位数字邀请码（体验版演示码，非安全凭据——正式配对由云端生成并校验）。
 * 使用 cryptoFramework 密码学安全随机，替代 Math.random 弱随机。
 */
export function generateInviteCode(): string {
  let v = SnapshotCrypto.randomInt(1000000);
  let code = '';
  for (let i = 0; i < 6; i++) {
    code = String.fromCharCode(48 + (v % 10)) + code;
    v = Math.floor(v / 10);
  }
  return code;
}

/**
 * AGC 云函数配对客户端（PairingApi 实现）：
 * - pairing-create / pairing-join / pairing-unpair 三个云函数封装；
 * - AGC 未配置时 call 抛错 → 统一抛 CloudApiError（1001/1002），由调用方降级；
 * - 依赖说明：@kit.CloudFoundationKit 为系统 kit，无需 ohpm 三方依赖；
 *   AGC 开通（agconnect-services.json + 云函数部署）前调用必然降级，属预期主路径。
 */
export class AgcPairingClient implements PairingApi {
  async createPairing(uid: string): Promise<PairingSession> {
    const payload: Record<string, Object> = { 'uid': uid, 'code': generateInviteCode() };
    const result = await AgcPairingClient.call('pairing-create', payload);
    return AgcPairingClient.parseSession(result);
  }

  async joinPairing(code: string, uid: string): Promise<PairingSession> {
    const payload: Record<string, Object> = { 'code': code, 'uid': uid };
    const result = await AgcPairingClient.call('pairing-join', payload);
    return AgcPairingClient.parseSession(result);
  }

  async unpair(pairId: string, uid: string): Promise<void> {
    const payload: Record<string, Object> = { 'pairId': pairId, 'uid': uid };
    await AgcPairingClient.call('pairing-unpair', payload);
  }

  /**
   * 统一云函数调用封装：
   * - 1008210001 网络连接错误 → CloudApiError(1002)；
   * - 201 无 INTERNET 权限 / 1008210009 客户端内部错误 / 1008211001 服务端错误
   *   （AGC 未初始化/未开通的典型表现）→ CloudApiError(1001)；
   * - 其余异常一律 CloudApiError(1002)。
   */
  static async call(name: string, data: Record<string, Object>): Promise<string | Object> {
    try {
      const result = await cloudFunction.call({
        name: name,
        version: '$latest',
        data: data
      });
      return result.result;
    } catch (e) {
      const be = e as BusinessError;
      if (be.code === 201 || be.code === 1008210009 || be.code === 1008211001) {
        throw new CloudApiError(1001, 'AGC 云服务未初始化或未开通（' + be.code + '）');
      }
      throw new CloudApiError(1002, '云端网络调用失败（' + be.code + '）');
    }
  }

  /** 解析云函数返回的配对会话（string 或对象形态均兼容；解析失败按网络类降级错误处理）。 */
  static parseSession(result: string | Object): PairingSession {
    try {
      let text = '';
      if (typeof result === 'string') {
        text = result;
      } else {
        text = JSON.stringify(result);
      }
      const o = JSON.parse(text) as Record<string, Object>;
      const session: PairingSession = {
        sessionId: AgcPairingClient.strOf(o, 'sessionId'),
        code: AgcPairingClient.strOf(o, 'code'),
        creatorUid: AgcPairingClient.strOf(o, 'creatorUid'),
        status: AgcPairingClient.strOf(o, 'status'),
        expiresAt: AgcPairingClient.numOf(o, 'expiresAt')
      };
      return session;
    } catch (e) {
      throw new CloudApiError(1002, '配对会话响应解析失败');
    }
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

/**
 * AGC 云函数快照同步客户端（SnapshotSync 实现）：
 * - snapshot-push / snapshot-pull 两个云函数封装（AGC 就绪后生效）；
 * - pull 返回 null 表示"无比 sinceVersion 更新的快照"，调用方沿用本机代录/旧数据；
 * - 一切调用异常经 AgcPairingClient.call 统一转为 CloudApiError，调用方降级。
 */
export class AgcSnapshotSync implements SnapshotSync {
  async pushSnapshot(pairId: string, version: number, shareLevel: number,
    payload: EncryptedPayload): Promise<void> {
    const data: Record<string, Object> = {
      'pairId': pairId,
      'version': version,
      'shareLevel': shareLevel,
      'ciphertext': payload.ciphertext,
      'iv': payload.iv
    };
    await AgcPairingClient.call('snapshot-push', data);
  }

  async pullSnapshot(pairId: string, sinceVersion: number): Promise<CloudSnapshot | null> {
    const data: Record<string, Object> = { 'pairId': pairId, 'sinceVersion': sinceVersion };
    const result = await AgcPairingClient.call('snapshot-pull', data);
    return AgcSnapshotSync.parseSnapshot(result, pairId, sinceVersion);
  }

  /** 解析云函数返回的快照（string 或对象形态均兼容）；无更新/密文缺失返回 null。 */
  static parseSnapshot(result: string | Object, pairId: string, sinceVersion: number): CloudSnapshot | null {
    try {
      if (result == null || result === '') {
        return null;
      }
      let text = '';
      if (typeof result === 'string') {
        text = result;
      } else {
        text = JSON.stringify(result);
      }
      if (text === '') {
        return null;
      }
      const o = JSON.parse(text) as Record<string, Object>;
      const version = AgcPairingClient.numOf(o, 'version');
      if (version <= sinceVersion) {
        return null; // 乱序旧包丢弃
      }
      const ciphertext = AgcPairingClient.strOf(o, 'ciphertext');
      const iv = AgcPairingClient.strOf(o, 'iv');
      if (ciphertext === '' || iv === '') {
        return null;
      }
      const snap: CloudSnapshot = {
        pairId: pairId,
        ownerUid: AgcPairingClient.strOf(o, 'ownerUid'),
        version: version,
        shareLevel: AgcPairingClient.numOf(o, 'shareLevel'),
        ciphertext: ciphertext,
        iv: iv,
        updatedAt: AgcPairingClient.numOf(o, 'updatedAt')
      };
      return snap;
    } catch (e) {
      throw new CloudApiError(1002, '快照响应解析失败');
    }
  }
}

/**
 * 拉取到的加密快照 → 引擎可用的对方忙碌区间：
 * AES-256-GCM 解密 → SnapshotCodec 解码 → toIntervals。
 * 解密失败（密钥失配/tag 校验失败）或解码失败返回 null，调用方据此降级本机代录模式。
 * 注意：快照生成时已并入对方缓冲，接收侧不再二次加缓冲。
 */
export function partnerIntervalsFromSnapshot(snap: CloudSnapshot, keyHex: string): Interval[] | null {
  const payload: EncryptedPayload = { ciphertext: snap.ciphertext, iv: snap.iv };
  const plain = SnapshotCrypto.decryptWithKey(keyHex, payload);
  if (plain == null) {
    return null;
  }
  const data = SnapshotCodec.decode(plain);
  if (data == null) {
    return null;
  }
  return SnapshotCodec.toIntervals(data);
}
