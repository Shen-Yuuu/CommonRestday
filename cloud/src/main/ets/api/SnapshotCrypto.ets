import { cryptoFramework } from '@kit.CryptoArchitectureKit';
import { util } from '@kit.ArkTS';

/**
 * 快照信封与字节编码（cloud 层职责；domain 保持零 Kit 依赖）。
 *
 * 协议 v1 §5.1 的存储单元：`iv` / `authTag` / `ciphertext` 各自独立成字段、统一 base64。
 * 旧原型把 16 字节 authTag 拼在密文尾部、整体转 hex，靠"末 16 字节"的隐式约定切分——
 * 那种形态一旦有一侧记错约定就解出乱码而不是明确失败，所以这里显式拆开。
 *
 * 本模块**不做加解密**：密钥材料从阶段 3 起只活在 HUKS 里（`PairKeyStore`），
 * 应用侧拿不到密钥，因此也不存在 `encryptWithKey(keyHex, …)` 这种入口。
 */

/** 加密产物（base64）。`iv` 是 12 字节 GCM nonce。 */
export interface EncryptedPayload {
  iv: string;
  authTag: string;
  ciphertext: string;
  algorithm: string;
}

export const ALG_AES_256_GCM = 'AES-256-GCM';
/** 信封与 AAD 里的协议版本；改协议必须同步升它（docs/cloud/pairing-protocol-v1.md §5.1）。 */
export const SNAPSHOT_SCHEMA_VERSION = 1;
const IV_LEN = 12;
const TAG_LEN = 16;

const B64 = new util.Base64Helper();

export class SnapshotCrypto {
  /**
   * AAD = `pairId|ownerUid|version|schemaVersion`（UTF-8）。
   *
   * 把上下文绑进 AAD 之后，"把 A 的密文搬到 B 名下"或"拿旧版本冒充新版本"都会直接解密失败；
   * 固定常量 `'crd-v1'` 那种写法给不出这个保证。设备实测依据见 `PairKeyStore` 顶部注释。
   */
  static aadOf(pairId: string, ownerUid: string, version: number, schemaVersion: number): string {
    return pairId + '|' + ownerUid + '|' + version + '|' + schemaVersion;
  }

  /** 每次操作新生成的 12 字节随机 nonce（GCM 下 nonce 重用等于失去机密性）。 */
  static randomIv(): Uint8Array {
    return cryptoFramework.createRandom().generateRandomSync(IV_LEN).data;
  }

  static toB64(bytes: Uint8Array): string {
    return B64.encodeToStringSync(bytes);
  }

  /** 非法 base64 抛异常：调用方都在 try 里，"格式坏了"必须表现为失败而不是解出垃圾。 */
  static fromB64(text: string): Uint8Array {
    return B64.decodeSync(text);
  }

  static encodeText(text: string): Uint8Array {
    return new util.TextEncoder().encodeInto(text);
  }

  static decodeText(bytes: Uint8Array): string {
    return util.TextDecoder.create('utf-8').decodeToString(bytes);
  }

  /** 信封字段形态自检：长度不对就直接判失败，不进密码学调用。 */
  static isWellFormed(payload: EncryptedPayload): boolean {
    try {
      return SnapshotCrypto.fromB64(payload.iv).length === IV_LEN
        && SnapshotCrypto.fromB64(payload.authTag).length === TAG_LEN
        && SnapshotCrypto.fromB64(payload.ciphertext).length > 0;
    } catch (e) {
      return false;
    }
  }

  /** 供 PairKeyStore 切分 HUKS 返回值用：密文 ‖ tag，tag 占末尾 16 字节。 */
  static tagLen(): number {
    return TAG_LEN;
  }
}
