import { cryptoFramework } from '@kit.CryptoArchitectureKit';
import { buffer } from '@kit.ArkTS';

/**
 * AES-256-GCM 快照加解密（cloud 层职责；domain 保持零 Kit 依赖）。
 *
 * 传输格式约定：
 * - ciphertext = hex(密文 + 16 字节 authTag 拼接)；
 * - iv = hex(12 字节随机 IV)；
 * - 密钥为 64 位 hex（32 字节），由配对双方以同一口径派生（deriveKeyHex）。
 */

/** 加密产物（hex 字符串）。 */
export interface EncryptedPayload {
  ciphertext: string;
  iv: string;
}

const AAD_TEXT = 'crd-v1';
const TAG_LEN = 16;
const IV_LEN = 12;
const KEY_HEX_LEN = 64;

export class SnapshotCrypto {
  /**
   * 加密明文。密钥 hex 非法时抛异常，调用方捕获后降级。
   * GCM 特性：update 返回密文，doFinal(null) 返回 authTag。
   */
  static encryptWithKey(keyHex: string, plain: string): EncryptedPayload {
    const key = SnapshotCrypto.keyOf(keyHex);
    const ivBytes = cryptoFramework.createRandom().generateRandomSync(IV_LEN).data;
    const ivBlob: cryptoFramework.DataBlob = { data: ivBytes };
    const aadBlob: cryptoFramework.DataBlob = { data: SnapshotCrypto.bytesOf(AAD_TEXT) };
    const gcmParams: cryptoFramework.GcmParamsSpec = {
      iv: ivBlob,
      aad: aadBlob,
      authTag: { data: new Uint8Array(TAG_LEN) },
      algName: 'GcmParamsSpec'
    };
    const cipher = cryptoFramework.createCipher('AES256|GCM');
    cipher.initSync(cryptoFramework.CryptoMode.ENCRYPT_MODE, key, gcmParams);
    const plainBlob: cryptoFramework.DataBlob = { data: SnapshotCrypto.bytesOf(plain) };
    const cipherOut = cipher.updateSync(plainBlob);
    const tagOut = cipher.doFinalSync(null);
    if (cipherOut == null || tagOut == null) {
      throw new Error('GCM encrypt produced empty output');
    }
    const merged = new Uint8Array(cipherOut.data.length + tagOut.data.length);
    merged.set(cipherOut.data, 0);
    merged.set(tagOut.data, cipherOut.data.length);
    const payload: EncryptedPayload = {
      ciphertext: SnapshotCrypto.toHex(merged),
      iv: SnapshotCrypto.toHex(ivBytes)
    };
    return payload;
  }

  /** 解密；密钥失配/authTag 校验失败/格式非法一律返回 null（调用方据此降级本机代录）。 */
  static decryptWithKey(keyHex: string, payload: EncryptedPayload): string | null {
    try {
      const cipherBytes = SnapshotCrypto.fromHex(payload.ciphertext);
      const ivBytes = SnapshotCrypto.fromHex(payload.iv);
      if (cipherBytes.length < TAG_LEN || ivBytes.length !== IV_LEN) {
        return null;
      }
      const bodyBytes = cipherBytes.subarray(0, cipherBytes.length - TAG_LEN);
      const tagBytes = new Uint8Array(cipherBytes.subarray(cipherBytes.length - TAG_LEN));
      const key = SnapshotCrypto.keyOf(keyHex);
      const gcmParams: cryptoFramework.GcmParamsSpec = {
        iv: { data: ivBytes },
        aad: { data: SnapshotCrypto.bytesOf(AAD_TEXT) },
        authTag: { data: tagBytes },
        algName: 'GcmParamsSpec'
      };
      const decoder = cryptoFramework.createCipher('AES256|GCM');
      decoder.initSync(cryptoFramework.CryptoMode.DECRYPT_MODE, key, gcmParams);
      const bodyBlob: cryptoFramework.DataBlob = { data: bodyBytes };
      const plainOut = decoder.updateSync(bodyBlob);
      // GCM 特性：doFinal(null) 校验 init 时传入的 authTag，失败抛异常
      decoder.doFinalSync(null);
      if (plainOut == null) {
        return null;
      }
      return buffer.from(plainOut.data).toString('utf-8');
    } catch (e) {
      return null;
    }
  }

  /**
   * 从 6 位邀请码派生 64 位 hex 密钥（SHA-256）。
   * 配对双方均知晓邀请码，故可推导同一 KEK；
   * 体验版折中——正式版应由云端下发高熵密钥（KMS 封装），此处仅保证"同码同钥"。
   */
  static deriveKeyHex(code: string): string {
    const md = cryptoFramework.createMd('SHA256');
    const blob: cryptoFramework.DataBlob = { data: SnapshotCrypto.bytesOf('crd-v1:' + code) };
    md.updateSync(blob);
    const digest = md.digestSync();
    return SnapshotCrypto.toHex(digest.data);
  }

  /** 密码学安全随机整数 [0, max)；crypto 随机源异常时退化为 Math.random（仅用于演示邀请码，不用于密钥/IV）。 */
  static randomInt(max: number): number {
    try {
      const rand = cryptoFramework.createRandom().generateRandomSync(4);
      let v = 0;
      for (let i = 0; i < rand.data.length; i++) {
        v = (v * 256 + rand.data[i]) % max;
      }
      return v;
    } catch (e) {
      return Math.floor(Math.random() * max);
    }
  }

  private static keyOf(keyHex: string): cryptoFramework.SymKey {
    if (keyHex.length !== KEY_HEX_LEN) {
      throw new Error('AES-256 key hex must be 64 chars');
    }
    const keyBytes = SnapshotCrypto.fromHex(keyHex);
    const blob: cryptoFramework.DataBlob = { data: keyBytes };
    const generator = cryptoFramework.createSymKeyGenerator('AES256');
    return generator.convertKeySync(blob);
  }

  private static bytesOf(text: string): Uint8Array {
    return new Uint8Array(buffer.from(text, 'utf-8').buffer);
  }

  private static toHex(bytes: Uint8Array): string {
    let out = '';
    for (let i = 0; i < bytes.length; i++) {
      const v = bytes[i];
      out += SnapshotCrypto.hexChar(v >> 4);
      out += SnapshotCrypto.hexChar(v & 0x0F);
    }
    return out;
  }

  private static fromHex(hex: string): Uint8Array {
    const out = new Uint8Array(Math.floor(hex.length / 2));
    for (let i = 0; i + 1 < hex.length; i += 2) {
      const hi = SnapshotCrypto.hexVal(hex.charAt(i));
      const lo = SnapshotCrypto.hexVal(hex.charAt(i + 1));
      if (hi < 0 || lo < 0) {
        throw new Error('invalid hex string');
      }
      out[Math.floor(i / 2)] = hi * 16 + lo;
    }
    return out;
  }

  private static hexChar(v: number): string {
    if (v < 10) {
      return String.fromCharCode(48 + v);
    }
    return String.fromCharCode(87 + v);
  }

  private static hexVal(c: string): number {
    const code = c.charCodeAt(0);
    if (code >= 48 && code <= 57) {
      return code - 48;
    }
    if (code >= 97 && code <= 102) {
      return code - 87;
    }
    if (code >= 65 && code <= 70) {
      return code - 55;
    }
    return -1;
  }
}
