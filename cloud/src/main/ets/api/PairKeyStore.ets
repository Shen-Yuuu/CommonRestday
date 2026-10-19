import { huks } from '@kit.UniversalKeystoreKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { Logger, PlanConnectionFailure } from 'commons';
import { EncryptedPayload, SnapshotCrypto } from './SnapshotCrypto';

/**
 * 配对长期密钥的 HUKS 托管容器（阶段 3 的唯一钥匙口）。
 *
 * 三条主张，全部来自 API 26 模拟器的设备实测（两台跨端互通，见
 * `docs/validation/clouddev-api26-spike.md` §2 实验 #5 与 CloudDevSpike 的状态记录）：
 *
 * 1. **密钥材料不出安全环境**：ECDH 协商出的共享密钥以
 *    `HUKS_TAG_DERIVED_AGREED_KEY_STORAGE_FLAG = HUKS_STORAGE_ONLY_USED_IN_HUKS` 收进别名，
 *    `updateSession`/`finishSession` 的 `outData` 全零、`sharedSecret` 为空。
 *    应用侧只能凭别名调用加解密，拿不到裸密钥——所以本文件**没有任何返回密钥的函数**。
 * 2. **GCM 参数是 NONCE / ASSOCIATED_DATA / AE_TAG**，不是 `HUKS_TAG_IV` / `HUKS_TAG_AAD`：
 *    后者加密会"成功"，但解密 `initSession` 报 `401: The parameter does not exist`。
 *    这是实测出来的参数组合，不能靠常量存在来推断运行语义。
 * 3. **HUKS 返回的 `outData` = 密文 ‖ 16 字节 tag**，切分与回填由本文件负责（协议 §5.1 才把
 *    它们拆成两个字段给云端存）。
 *
 * 别名生命周期（实测边界）：卸载重装、清数据、备份恢复后别名是否存在**尚未验证**。
 * 因此这里所有对外判断都走 `aliasExists()`：别名不在就是 `KEY_UNAVAILABLE`，
 * 由调用方引导重新配对，绝不静默新建别名（那会让双方密钥永久不一致）。
 */

const TAG = 'PairKeyStore';
/** 12000011 = key not found。删除不存在的别名不是错误，其他错误码必须冒出来。 */
const HUKS_KEY_NOT_FOUND = 12000011;
/** 别名槽位长度上限：pairId/uid 是云端或本机生成的 UUID 形态，截断只是防御性收口。 */
const ALIAS_SLOT_MAX = 48;

function param(tag: huks.HuksTag, value: boolean | number | bigint | Uint8Array): huks.HuksParam {
  return { tag: tag, value: value };
}

function options(properties: huks.HuksParam[]): huks.HuksOptions {
  return { properties: properties };
}

/**
 * 别名是否存在。只能用 `hasKeyItem`：`isKeyItemExist` 的 Promise 形态在"不存在"时不是返回
 * false，而是 reject 12000011 / `The entity does not exist.`（API 26 模拟器实测，协议 §11
 * 第 1 条的设备证据抓到的——首次配对必定在 `ensureIdentity` 第一步就降级成"服务暂不可用"）。
 */
async function aliasExists(alias: string): Promise<boolean> {
  return await huks.hasKeyItem(alias, options([]));
}

/** 本机静态身份密钥的生成参数：只做协商，purpose 里没有 export/derive，所以私钥导不出去。 */
function identityProperties(): huks.HuksParam[] {
  return [
    param(huks.HuksTag.HUKS_TAG_ALGORITHM, huks.HuksKeyAlg.HUKS_ALG_ECC),
    param(huks.HuksTag.HUKS_TAG_KEY_SIZE, huks.HuksKeySize.HUKS_ECC_KEY_SIZE_256),
    param(huks.HuksTag.HUKS_TAG_PURPOSE, huks.HuksKeyPurpose.HUKS_KEY_PURPOSE_AGREE),
    param(huks.HuksTag.HUKS_TAG_DIGEST, huks.HuksKeyDigest.HUKS_DIGEST_NONE),
    param(huks.HuksTag.HUKS_TAG_PADDING, huks.HuksKeyPadding.HUKS_PADDING_NONE),
    param(huks.HuksTag.HUKS_TAG_BLOCK_MODE, huks.HuksCipherMode.HUKS_MODE_CBC),
    param(huks.HuksTag.HUKS_TAG_DERIVED_AGREED_KEY_STORAGE_FLAG,
      huks.HuksKeyStorageType.HUKS_STORAGE_ONLY_USED_IN_HUKS)
  ];
}

/** ECDH 会话的 init/update 共用同一份参数：算法从 ECC 切到 ECDH，且只带这四个标签。 */
function agreeProperties(): huks.HuksParam[] {
  return [
    param(huks.HuksTag.HUKS_TAG_ALGORITHM, huks.HuksKeyAlg.HUKS_ALG_ECDH),
    param(huks.HuksTag.HUKS_TAG_KEY_SIZE, huks.HuksKeySize.HUKS_ECC_KEY_SIZE_256),
    param(huks.HuksTag.HUKS_TAG_PURPOSE, huks.HuksKeyPurpose.HUKS_KEY_PURPOSE_AGREE),
    param(huks.HuksTag.HUKS_TAG_DERIVED_AGREED_KEY_STORAGE_FLAG,
      huks.HuksKeyStorageType.HUKS_STORAGE_ONLY_USED_IN_HUKS)
  ];
}

/** finish 这一步换成"派生密钥落库"的参数集：目标是 AES-256-GCM，落进 pairId 专属别名。 */
function finishProperties(pairAlias: string): huks.HuksParam[] {
  return [
    param(huks.HuksTag.HUKS_TAG_DERIVED_AGREED_KEY_STORAGE_FLAG,
      huks.HuksKeyStorageType.HUKS_STORAGE_ONLY_USED_IN_HUKS),
    param(huks.HuksTag.HUKS_TAG_IS_KEY_ALIAS, true),
    ...aesGcmKeyProperties(),
    param(huks.HuksTag.HUKS_TAG_KEY_ALIAS, SnapshotCrypto.encodeText(pairAlias))
  ];
}

/** GCM 会话参数。加解密只差在 purpose 与解密侧多带的 AE_TAG 上（实测过的形态）。 */
function gcmProperties(purpose: huks.HuksKeyPurpose, iv: Uint8Array, aad: string,
  authTag?: Uint8Array): huks.HuksParam[] {
  const properties: huks.HuksParam[] = [
    param(huks.HuksTag.HUKS_TAG_ALGORITHM, huks.HuksKeyAlg.HUKS_ALG_AES),
    param(huks.HuksTag.HUKS_TAG_KEY_SIZE, huks.HuksKeySize.HUKS_AES_KEY_SIZE_256),
    param(huks.HuksTag.HUKS_TAG_PURPOSE, purpose),
    param(huks.HuksTag.HUKS_TAG_BLOCK_MODE, huks.HuksCipherMode.HUKS_MODE_GCM),
    param(huks.HuksTag.HUKS_TAG_PADDING, huks.HuksKeyPadding.HUKS_PADDING_NONE),
    param(huks.HuksTag.HUKS_TAG_DIGEST, huks.HuksKeyDigest.HUKS_DIGEST_NONE),
    param(huks.HuksTag.HUKS_TAG_NONCE, iv),
    param(huks.HuksTag.HUKS_TAG_ASSOCIATED_DATA, SnapshotCrypto.encodeText(aad))
  ];
  if (authTag !== undefined) {
    properties.push(param(huks.HuksTag.HUKS_TAG_AE_TAG, authTag));
  }
  return properties;
}

/** 独立生成的 AES-GCM 密钥与 ECDH 派生密钥共用同一套算法规格。 */
function aesGcmKeyProperties(): huks.HuksParam[] {
  return [
    param(huks.HuksTag.HUKS_TAG_ALGORITHM, huks.HuksKeyAlg.HUKS_ALG_AES),
    param(huks.HuksTag.HUKS_TAG_KEY_SIZE, huks.HuksKeySize.HUKS_AES_KEY_SIZE_256),
    param(huks.HuksTag.HUKS_TAG_PURPOSE,
      huks.HuksKeyPurpose.HUKS_KEY_PURPOSE_ENCRYPT | huks.HuksKeyPurpose.HUKS_KEY_PURPOSE_DECRYPT),
    param(huks.HuksTag.HUKS_TAG_DIGEST, huks.HuksKeyDigest.HUKS_DIGEST_NONE),
    param(huks.HuksTag.HUKS_TAG_PADDING, huks.HuksKeyPadding.HUKS_PADDING_NONE),
    param(huks.HuksTag.HUKS_TAG_BLOCK_MODE, huks.HuksCipherMode.HUKS_MODE_GCM)
  ];
}

function publicKeyProperties(): huks.HuksParam[] {
  return [param(huks.HuksTag.HUKS_TAG_KEY_TYPE, huks.HuksImportKeyType.HUKS_KEY_TYPE_PUBLIC_KEY)];
}

export class PairKeyStore {
  private static planAlias(slot: string, identity: boolean): string {
    if (!/^[a-f0-9]{64}$/.test(slot)) throw new Error('Invalid plan key slot');
    return (identity ? 'ft-plan-id-' : 'ft-plan-pair-') + slot;
  }

  /** Independent namespace. Only public bytes leave HUKS; no legacy key is touched. */
  static async planPublicKey(slot: string, allowCreate: boolean): Promise<Uint8Array> {
    const alias = PairKeyStore.planAlias(slot, true);
    let exists: boolean;
    try { exists = await aliasExists(alias); }
    catch (error) { throw new PlanConnectionFailure('key.identity.lookup', error as Object, 'PLAN_IDENTITY_LOOKUP_FAILED'); }
    if (!exists) {
      if (!allowCreate) throw new Error('PLAN_IDENTITY_MISSING');
      try { await PairKeyStore.generateKey(alias, identityProperties()); }
      catch (error) { throw new PlanConnectionFailure('key.identity.generate', error as Object, 'PLAN_IDENTITY_GENERATION_FAILED'); }
    }
    try {
      const result = await huks.exportKeyItem(alias, options(publicKeyProperties()));
      if (result.outData === undefined) throw new Error('PLAN_PUBLIC_KEY_MISSING');
      return result.outData;
    } catch (error) {
      throw new PlanConnectionFailure('key.identity.export', error as Object, 'PLAN_PUBLIC_KEY_EXPORT_FAILED');
    }
  }

  static async agreePlanKey(identitySlot: string, pairSlot: string, peer: Uint8Array): Promise<void> {
    const identityAlias = PairKeyStore.planAlias(identitySlot, true);
    const pairAlias = PairKeyStore.planAlias(pairSlot, false);
    let handle: number | undefined;
    let stage = 'key.agree.lookup';
    try {
      if (!await aliasExists(identityAlias)) throw new Error('PLAN_IDENTITY_MISSING');
      // Existing secure bindings have immutable peer keys. Never delete a live derived key on refresh.
      if (await aliasExists(pairAlias)) return;
      stage = 'key.agree.init';
      const session = await huks.initSession(identityAlias, { properties: agreeProperties(), inData: new Uint8Array([]) });
      handle = session.handle;
      stage = 'key.agree.update';
      await huks.updateSession(handle, { properties: agreeProperties(), inData: peer });
      stage = 'key.agree.finish';
      await huks.finishSession(handle, options(finishProperties(pairAlias)));
      handle = undefined;
      stage = 'key.agree.available';
      if (!await aliasExists(pairAlias)) throw new Error('PLAN_KEY_UNAVAILABLE');
    } catch (error) {
      if (handle !== undefined) {
        try { await huks.abortSession(handle, options([])); } catch { /* Preserve the original failure. */ }
      }
      throw new PlanConnectionFailure(stage, error as Object, 'PLAN_AGREEMENT_FAILED');
    }
  }

  static async hasPlanKey(slot: string): Promise<boolean> { return aliasExists(PairKeyStore.planAlias(slot, false)); }
  static async sealPlan(slot: string, aad: string, plain: string): Promise<EncryptedPayload> {
    return PairKeyStore.sealWithAlias(PairKeyStore.planAlias(slot, false), aad, plain);
  }
  static async openPlan(slot: string, aad: string, payload: EncryptedPayload): Promise<string | null> {
    return PairKeyStore.openWithAlias(PairKeyStore.planAlias(slot, false), aad, payload);
  }
  private static planProofAlias(slot: string): string {
    if (!/^[a-f0-9]{64}$/.test(slot)) throw new Error('Invalid plan proof slot');
    return 'ft-plan-proof-' + slot;
  }
  static async sealPlanProof(slot: string, aad: string, secret: string): Promise<EncryptedPayload> {
    const alias = PairKeyStore.planProofAlias(slot);
    if (!await aliasExists(alias)) await PairKeyStore.generateKey(alias, aesGcmKeyProperties());
    return PairKeyStore.sealWithAlias(alias, aad, secret);
  }
  static async openPlanProof(slot: string, aad: string, payload: EncryptedPayload): Promise<string | null> {
    const alias = PairKeyStore.planProofAlias(slot);
    if (!await aliasExists(alias)) return null;
    return PairKeyStore.openWithAlias(alias, aad, payload);
  }
  static async dropPlanProof(slot: string): Promise<void> {
    await PairKeyStore.deleteAlias(PairKeyStore.planProofAlias(slot));
  }
  static async dropPlanKey(slot: string): Promise<void> {
    await PairKeyStore.deleteAlias(PairKeyStore.planAlias(slot, false));
  }

  /** 别名里只留稳定字符，别的（含分隔符）一律折成下划线：别名可读，也不会撞出奇怪字符。 */
  private static slot(raw: string): string {
    let out = '';
    for (let i = 0; i < raw.length && out.length < ALIAS_SLOT_MAX; i++) {
      const c = raw.charAt(i);
      const ok = (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9');
      out += ok ? c : '_';
    }
    return out;
  }

  static identityAliasOf(uid: string): string {
    return 'crd-id-' + PairKeyStore.slot(uid);
  }

  static pairAliasOf(pairId: string): string {
    return 'crd-pair-' + PairKeyStore.slot(pairId);
  }

  static inviteProofAliasOf(pairId: string): string {
    return 'crd-invite-' + PairKeyStore.slot(pairId);
  }

  /** 只有创建邀请的设备会调用；Preferences 只能拿到这个密文信封，拿不到确认凭据。 */
  static async sealInviteProof(pairId: string, token: string): Promise<EncryptedPayload> {
    if (pairId === '' || token.length < 22) {
      throw new Error('invite proof malformed');
    }
    const alias = PairKeyStore.inviteProofAliasOf(pairId);
    if (!await aliasExists(alias)) {
      await PairKeyStore.generateKey(alias, aesGcmKeyProperties());
    }
    return PairKeyStore.sealWithAlias(alias, 'crd-invite-proof-v1|' + pairId, token);
  }

  /** 仅在邀请方按下确认时打开；损坏/缺失时失败关闭，绝不退化成用六码确认。 */
  static async openInviteProof(pairId: string, payload: EncryptedPayload): Promise<string | null> {
    if (pairId === '' || payload.algorithm !== 'AES-256-GCM' || !SnapshotCrypto.isWellFormed(payload)) {
      return null;
    }
    const alias = PairKeyStore.inviteProofAliasOf(pairId);
    if (!await aliasExists(alias)) {
      return null;
    }
    return PairKeyStore.openWithAlias(alias, 'crd-invite-proof-v1|' + pairId, payload);
  }

  static async dropInviteProof(pairId: string): Promise<void> {
    if (pairId !== '') {
      await PairKeyStore.deleteAlias(PairKeyStore.inviteProofAliasOf(pairId));
    }
  }

  /**
   * 确保本机静态身份密钥就绪，返回可上传云端的公钥（base64）。
   * 已存在就只导出，不重新生成——换一次配对码不该换掉本机身份。
   */
  static async ensureIdentity(uid: string): Promise<string> {
    const alias = PairKeyStore.identityAliasOf(uid);
    if (!await aliasExists(alias)) {
      await PairKeyStore.generateKey(alias, identityProperties());
      Logger.info(TAG, 'identity key created');
    }
    const exported = await huks.exportKeyItem(alias, options(publicKeyProperties()));
    const publicKey = exported.outData;
    if (publicKey === undefined || publicKey.length === 0) {
      throw new Error('identity public key is empty');
    }
    return SnapshotCrypto.toB64(publicKey);
  }

  /**
   * 用对端公钥完成协商，把共享密钥收进 `crd-pair-<pairId>` 别名。
   *
   * 三步的 inData 形态是实测出来的，不能统一处理：init 传**空字节数组**、update 传对端公钥、
   * finish 只传 options。第一步的别名是**本机私钥**别名，不是目标别名（写成目标别名会报
   * 12000011 / 12000003）。
   */
  static async agreeKey(uid: string, pairId: string, peerPublicKeyB64: string): Promise<void> {
    const identityAlias = PairKeyStore.identityAliasOf(uid);
    const pairAlias = PairKeyStore.pairAliasOf(pairId);
    if (!await aliasExists(identityAlias)) {
      throw new Error('identity key missing before agreement');
    }
    const peerPublic = SnapshotCrypto.fromB64(peerPublicKeyB64);
    if (peerPublic.length === 0 || peerPublic.length > 512) {
      throw new Error('peer public key size out of range');
    }
    // 重协商必须从头派生：旧别名在的话 finish 会撞已存在的密钥。
    await PairKeyStore.deleteAlias(pairAlias);
    let stage = 'init';
    try {
      const session = await huks.initSession(identityAlias, {
        properties: agreeProperties(), inData: new Uint8Array([])
      });
      stage = 'update';
      await huks.updateSession(session.handle, { properties: agreeProperties(), inData: peerPublic });
      stage = 'finish';
      await huks.finishSession(session.handle, options(finishProperties(pairAlias)));
    } catch (e) {
      const be = e as BusinessError;
      throw new Error('ECDH ' + stage + ' failed, code=' + be.code);
    }
    if (!await aliasExists(pairAlias)) {
      throw new Error('agreed key alias not created');
    }
    Logger.info(TAG, 'pair key agreed');
  }

  /** 钥匙是否还在。false 的含义是"需要重新配对"，不是"重试一下就好"。 */
  static async hasPairKey(pairId: string): Promise<boolean> {
    if (pairId === '') {
      return false;
    }
    try {
      return await aliasExists(PairKeyStore.pairAliasOf(pairId));
    } catch (e) {
      Logger.warn(TAG, 'hasPairKey degraded: ' + (e as Error).message);
      return false;
    }
  }

  /** 解除配对：删协商别名即密钥消失。本机身份别名保留（它不绑定任何人的数据）。 */
  static async dropPairKey(pairId: string): Promise<void> {
    await PairKeyStore.deleteAlias(PairKeyStore.pairAliasOf(pairId));
  }

  /** 加密快照。nonce 每次新生成，tag 从 HUKS 返回值尾部切出来单独成字段。 */
  static async seal(pairId: string, aad: string, plain: string): Promise<EncryptedPayload> {
    return PairKeyStore.sealWithAlias(PairKeyStore.pairAliasOf(pairId), aad, plain);
  }

  /** 日程快照与邀请确认凭据只共享 GCM 机械过程，不共享 HUKS 别名或 AAD。 */
  private static async sealWithAlias(alias: string, aad: string, plain: string): Promise<EncryptedPayload> {
    const iv = SnapshotCrypto.randomIv();
    const properties = gcmProperties(huks.HuksKeyPurpose.HUKS_KEY_PURPOSE_ENCRYPT, iv, aad);
    let handle: number | undefined;
    let stage = 'key.seal.init';
    let output: Uint8Array | undefined;
    try {
      const session = await huks.initSession(alias, options(properties));
      handle = session.handle;
      stage = 'key.seal.finish';
      const result = await huks.finishSession(handle, {
        properties: properties, inData: SnapshotCrypto.encodeText(plain)
      });
      handle = undefined;
      output = result.outData;
    } catch (error) {
      if (handle !== undefined) {
        try { await huks.abortSession(handle, options([])); } catch { /* Preserve original diagnostic. */ }
      }
      throw new PlanConnectionFailure(stage, error as Object, 'HUKS_ENCRYPT_FAILED');
    }
    const tagLen = SnapshotCrypto.tagLen();
    if (output === undefined || output.length <= tagLen) {
      throw new Error('HUKS GCM produced no ciphertext');
    }
    const payload: EncryptedPayload = {
      iv: SnapshotCrypto.toB64(iv),
      authTag: SnapshotCrypto.toB64(output.subarray(output.length - tagLen)),
      ciphertext: SnapshotCrypto.toB64(output.subarray(0, output.length - tagLen)),
      algorithm: 'AES-256-GCM'
    };
    return payload;
  }

  /** 解密快照。密钥失配 / tag 或 AAD 被改 / 格式非法一律返回 null，由调用方降级。 */
  static async open(pairId: string, aad: string, payload: EncryptedPayload): Promise<string | null> {
    return PairKeyStore.openWithAlias(PairKeyStore.pairAliasOf(pairId), aad, payload);
  }

  private static async openWithAlias(alias: string, aad: string, payload: EncryptedPayload): Promise<string | null> {
    try {
      if (payload.algorithm !== 'AES-256-GCM' || !SnapshotCrypto.isWellFormed(payload)) {
        return null;
      }
      const iv = SnapshotCrypto.fromB64(payload.iv);
      const authTag = SnapshotCrypto.fromB64(payload.authTag);
      const ciphertext = SnapshotCrypto.fromB64(payload.ciphertext);
      const properties = gcmProperties(huks.HuksKeyPurpose.HUKS_KEY_PURPOSE_DECRYPT, iv, aad, authTag);
      const session = await huks.initSession(alias, {
        properties: properties, inData: ciphertext
      });
      let plain: Uint8Array | undefined;
      try {
        const result = await huks.finishSession(session.handle, { properties: properties, inData: ciphertext });
        plain = result.outData;
      } catch (e) {
        // 校验失败时会话还挂着，不 abort 会漏 handle
        await huks.abortSession(session.handle, options([]));
        Logger.info(TAG, 'snapshot rejected, code=' + (e as BusinessError).code);
        return null;
      }
      if (plain === undefined) {
        return null;
      }
      return SnapshotCrypto.decodeText(plain);
    } catch (e) {
      Logger.warn(TAG, 'open degraded: ' + (e as Error).message);
      return null;
    }
  }

  private static async generateKey(alias: string, properties: huks.HuksParam[]): Promise<void> {
    await huks.generateKeyItem(alias, options(properties));
  }

  private static async deleteAlias(alias: string): Promise<void> {
    try {
      await huks.deleteKeyItem(alias, options([]));
    } catch (e) {
      const be = e as BusinessError;
      if (be.code !== HUKS_KEY_NOT_FOUND) {
        throw new Error('deleteKeyItem failed, code=' + be.code);
      }
    }
  }
}
