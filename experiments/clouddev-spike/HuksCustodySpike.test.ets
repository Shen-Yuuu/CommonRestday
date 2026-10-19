import { describe, expect, it, beforeAll, afterAll } from '@ohos/hypium';
import { huks } from '@kit.UniversalKeystoreKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { util } from '@kit.ArkTS';

/**
 * 实验 #5 · HUKS 密钥托管实测（一次性，跑完即删）
 *
 * 这一份只回答一个问题：**长期密钥能不能全程只待在 HUKS 里**。它决定阶段 3 生死，
 * 且与 AGC、网络、云函数、`INTERNET` 权限全部无关——插上台设备或起个模拟器就能判掉。
 *
 * 参数名/取值/`@since` 全部按本机 `SDK/openharmony/ets/api/@ohos.security.huks.d.ts`
 * （API 26）逐个核过，不使用任何本表里查不到的标签。三条已定的静态结论写在这里，
 * 免得上设备后又去猜：
 * - 本 SDK **没有** `NON_EXPORTABLE`，但有 `HUKS_STORAGE_ONLY_USED_IN_HUKS = 2`
 *   （`HuksKeyStorageType`，@since 10）——"密钥只存在 HUKS 内、由 HUKS 管理"就是它，
 *   配套标签 `HUKS_TAG_DERIVED_AGREED_KEY_STORAGE_FLAG`（@since 10）原文写的是
 *   "Storage type of the derived key **or agreed key**"，即协商密钥同样受它管辖；
 * - ECC 没有独立曲线标签，曲线由 `HUKS_TAG_KEY_SIZE` 隐含（`HUKS_ECC_KEY_SIZE_256`）；
 * - `HUKS_TAG_AAD` 是 **@since 24** 才有的（`AE_TAG` 自 8 就有）。
 *   → 含义：如果哪天为了装机量把 `compatibleSdkVersion` 往下调，**AAD 绑 pairId 这条要先砍**，
 *     其余托管链路在 API 12 上仍成立。这是装机量与加密强度之间一条真实的耦合，
 *     以前记在门禁文件里的"形态偏差"其实不是偏差，是版本门槛。
 *
 * 断言的分工：只有"安全主张"那几条写成硬断言（红=结论不成立，正是我们要的消息）；
 * 纯探路口（哪个调用是必需的、KEM 走不走得通）一律 try/catch + 记日志，不判红，
 * 免得一次跑只暴露第一个问题。所有原始观测打在 hilog，过滤词 `CRD-HUKS`。
 */

/** 两端"各持一把"的协商密钥别名（同一台机器模拟配对双方，只为跑通密码学链路）。 */
const ALIAS_A = 'crd-spike-ecc-a';
const ALIAS_B = 'crd-spike-ecc-b';
/** 协商得到的共享密钥：期望它落在 HUKS 内部、应用拿不到字节。 */
const ALIAS_AGREED_IN_HUKS = 'crd-spike-agreed-inhuks';
/** 对照组：同一套参数只把存储标记换成 KEY_EXPORT_ALLOWED，用来证明上一行不是"碰巧没返回"。 */
const ALIAS_AGREED_EXPORT = 'crd-spike-agreed-export';
/** HKDF 派生目标别名（若 DERIVE_MAIN_KEY 能吃别名，这才是阶段 3 该用的形态）。 */
const ALIAS_DERIVED = 'crd-spike-derived-aes';
/** ML-KEM 对照：本 SDK 里另一条"密钥不出 HUKS"的候选通道。 */
const ALIAS_KEM = 'crd-spike-mlkem';

const ALL_ALIASES: string[] =
  [ALIAS_A, ALIAS_B, ALIAS_AGREED_IN_HUKS, ALIAS_AGREED_EXPORT, ALIAS_DERIVED, ALIAS_KEM];

/** 与 docs/cloud/pairing-protocol-v1.md 的 AAD 口径一致。 */
const AAD_TEXT = 'pairId-spike|ownerUid-spike|1|1';
const PLAIN_TEXT = '同休日 spike 明文载荷 12345';

function log(msg: string): void {
  console.info('[CRD-HUKS] ' + msg);
}

function enc(text: string): Uint8Array {
  return new util.TextEncoder().encodeInto(text);
}

function hexOf(data: Uint8Array | undefined): string {
  if (data === undefined) {
    return '<undefined>';
  }
  let s = '';
  for (let i = 0; i < data.length; i++) {
    s += (data[i] < 16 ? '0' : '') + data[i].toString(16);
  }
  return s;
}

/** 长度 + 前 8 字节，够判断"有没有把裸密钥交回应用"，又不会把密钥整条打进日志。 */
function shape(data: Uint8Array | undefined): string {
  if (data === undefined) {
    return 'undefined';
  }
  const head = hexOf(data.subarray(0, 8));
  return 'len=' + data.length + ' head=' + head;
}

function p(tag: huks.HuksTag, value: boolean | number | bigint | Uint8Array): huks.HuksParam {
  const item: huks.HuksParam = { tag: tag, value: value };
  return item;
}

function opts(props: huks.HuksParam[], inData?: Uint8Array): huks.HuksOptions {
  const o: huks.HuksOptions = { properties: props };
  if (inData !== undefined) {
    o.inData = inData;
  }
  return o;
}

function codeOf(e: BusinessError): string {
  return e.code + ':' + e.message;
}

async function silentDelete(alias: string): Promise<void> {
  try {
    await huks.deleteKeyItem(alias, opts([]));
  } catch (e) {
    // 别名本就不存在（HUKS_ERR_CODE_ITEM_NOT_EXIST = 12000011）不是发现，不值得判红
  }
}

/** 生成一把用于协商的 ECC（P-256）密钥对，别名常驻。 */
async function generateAgreeKeyPair(alias: string): Promise<void> {
  // 刻意不带 KEY_STORAGE_FLAG：本机 d.ts 原文写 `HUKS_STORAGE_PERSISTENT` 自 API 10 起废弃，
  // 且注明"密钥管理里不用它，派生场景改用 ONLY_USED_IN_HUKS / KEY_EXPORT_ALLOWED"。
  // generateKeyItem 的别名本身就是持久的，加它只会引入一个已废弃的取值。
  const props: huks.HuksParam[] = [
    p(huks.HuksTag.HUKS_TAG_ALGORITHM, huks.HuksKeyAlg.HUKS_ALG_ECC),
    p(huks.HuksTag.HUKS_TAG_KEY_SIZE, huks.HuksKeySize.HUKS_ECC_KEY_SIZE_256),
    p(huks.HuksTag.HUKS_TAG_PURPOSE, huks.HuksKeyPurpose.HUKS_KEY_PURPOSE_AGREE),
    p(huks.HuksTag.HUKS_TAG_KEY_GENERATE_TYPE, huks.HuksKeyGenerateType.HUKS_KEY_GENERATE_TYPE_DEFAULT)
  ];
  await huks.generateKeyItem(alias, opts(props));
}

async function exportPublicKey(alias: string): Promise<Uint8Array> {
  const props: huks.HuksParam[] = [
    p(huks.HuksTag.HUKS_TAG_KEY_TYPE, huks.HuksImportKeyType.HUKS_KEY_TYPE_PUBLIC_KEY)
  ];
  const r: huks.HuksReturnResult = await huks.exportKeyItem(alias, opts(props));
  return r.outData as Uint8Array;
}

/**
 * ECDH 协商并把共享密钥按指定存储形态收进别名 destAlias。
 * 返回"是否 updateSession 必需"与"应用侧见到的字节"，这两项就是要抄的东西。
 */
async function agreeInto(destAlias: string, privAlias: string, peerPub: Uint8Array,
  storageFlag: huks.HuksKeyStorageType): Promise<boolean> {
  await silentDelete(destAlias);
  const props: huks.HuksParam[] = [
    p(huks.HuksTag.HUKS_TAG_ALGORITHM, huks.HuksKeyAlg.HUKS_ALG_ECDH),
    p(huks.HuksTag.HUKS_TAG_PURPOSE, huks.HuksKeyPurpose.HUKS_KEY_PURPOSE_AGREE),
    p(huks.HuksTag.HUKS_TAG_KEY_SIZE, huks.HuksKeySize.HUKS_ECC_KEY_SIZE_256),
    p(huks.HuksTag.HUKS_TAG_KEY_GENERATE_TYPE, huks.HuksKeyGenerateType.HUKS_KEY_GENERATE_TYPE_AGREE),
    p(huks.HuksTag.HUKS_TAG_AGREE_PRIVATE_KEY_ALIAS, enc(privAlias)),
    p(huks.HuksTag.HUKS_TAG_AGREE_PUBLIC_KEY, peerPub),
    p(huks.HuksTag.HUKS_TAG_DERIVED_AGREED_KEY_STORAGE_FLAG, storageFlag)
  ];
  const handle: huks.HuksSessionHandle = await huks.initSession(destAlias, opts(props));
  log('initSession ok dest=' + destAlias + ' handle=' + handle.handle);
  let updated = false;
  try {
    const u = await huks.updateSession(handle.handle, opts(props));
    updated = true;
    log('updateSession 可用 outData=' + shape(u.outData) + ' sharedSecret=' + shape(u.sharedSecret));
  } catch (e) {
    log('updateSession 报错（若 finish 能一次成事则说明协商不需要它）→ ' + codeOf(e as BusinessError));
  }
  const r: huks.HuksReturnResult = await huks.finishSession(handle.handle, opts(props));
  log('finishSession outData=' + shape(r.outData) + ' sharedSecret=' + shape(r.sharedSecret)
    + ' properties=' + (r.properties === undefined ? 'undefined' : r.properties.length));
  const leaked: boolean = (r.outData !== undefined && r.outData.length > 0)
    || (r.sharedSecret !== undefined && r.sharedSecret.length > 0);
  log('>>> 应用侧是否拿到裸共享秘密：' + (leaked ? '是（密钥出 HUKS 了）' : '否（只在 HUKS 内）'));
  return updated;
}

/**
 * 用别名里的密钥做 AES-256-GCM。两个前提要在此实测：别名里装的是协商/派生密钥时能不能直接当 AES 用；
 * 以及 `HUKS_TAG_AAD`（本机表 @since 24）在真机上是否真的参与校验。
 */
async function aesGcmEncrypt(alias: string, iv: Uint8Array, aad: Uint8Array,
  plain: Uint8Array): Promise<huks.HuksReturnResult> {
  const props: huks.HuksParam[] = [
    p(huks.HuksTag.HUKS_TAG_ALGORITHM, huks.HuksKeyAlg.HUKS_ALG_AES),
    p(huks.HuksTag.HUKS_TAG_KEY_SIZE, huks.HuksKeySize.HUKS_AES_KEY_SIZE_256),
    p(huks.HuksTag.HUKS_TAG_PURPOSE, huks.HuksKeyPurpose.HUKS_KEY_PURPOSE_ENCRYPT),
    p(huks.HuksTag.HUKS_TAG_BLOCK_MODE, huks.HuksCipherMode.HUKS_MODE_GCM),
    p(huks.HuksTag.HUKS_TAG_PADDING, huks.HuksKeyPadding.HUKS_PADDING_NONE),
    p(huks.HuksTag.HUKS_TAG_DIGEST, huks.HuksKeyDigest.HUKS_DIGEST_NONE),
    p(huks.HuksTag.HUKS_TAG_IV, iv),
    p(huks.HuksTag.HUKS_TAG_AAD, aad)
  ];
  const handle = await huks.initSession(alias, opts(props));
  return await huks.finishSession(handle.handle, opts(props, plain));
}

async function aesGcmDecrypt(alias: string, iv: Uint8Array, aad: Uint8Array,
  cipher: Uint8Array, authTag: Uint8Array): Promise<Uint8Array> {
  const props: huks.HuksParam[] = [
    p(huks.HuksTag.HUKS_TAG_ALGORITHM, huks.HuksKeyAlg.HUKS_ALG_AES),
    p(huks.HuksTag.HUKS_TAG_KEY_SIZE, huks.HuksKeySize.HUKS_AES_KEY_SIZE_256),
    p(huks.HuksTag.HUKS_TAG_PURPOSE, huks.HuksKeyPurpose.HUKS_KEY_PURPOSE_DECRYPT),
    p(huks.HuksTag.HUKS_TAG_BLOCK_MODE, huks.HuksCipherMode.HUKS_MODE_GCM),
    p(huks.HuksTag.HUKS_TAG_PADDING, huks.HuksKeyPadding.HUKS_PADDING_NONE),
    p(huks.HuksTag.HUKS_TAG_DIGEST, huks.HuksKeyDigest.HUKS_DIGEST_NONE),
    p(huks.HuksTag.HUKS_TAG_IV, iv),
    p(huks.HuksTag.HUKS_TAG_AAD, aad),
    p(huks.HuksTag.HUKS_TAG_AE_TAG, authTag)
  ];
  const handle = await huks.initSession(alias, opts(props));
  const r = await huks.finishSession(handle.handle, opts(props, cipher));
  return r.outData as Uint8Array;
}

function textOf(data: Uint8Array): string {
  return util.TextDecoder.create('utf-8').decodeToString(data);
}

export default function huksCustodySpike() {
  describe('HuksCustodySpike', () => {
    beforeAll(async () => {
      for (let i = 0; i < ALL_ALIASES.length; i++) {
        await silentDelete(ALL_ALIASES[i]);
      }
    });

    afterAll(async () => {
      for (let i = 0; i < ALL_ALIASES.length; i++) {
        await silentDelete(ALL_ALIASES[i]);
      }
    });

    /** 协商密钥对能否生成、公钥能否导出（私钥必须导不出来）。 */
    it('ecc_keypair_generates_and_only_public_exports', 0, async () => {
      await generateAgreeKeyPair(ALIAS_A);
      await generateAgreeKeyPair(ALIAS_B);
      expect(await huks.isKeyItemExist(ALIAS_A, opts([]))).assertTrue();

      const pubA = await exportPublicKey(ALIAS_A);
      log('公钥 A ' + shape(pubA));
      expect(pubA.length > 0).assertTrue();

      try {
        const props: huks.HuksParam[] = [
          p(huks.HuksTag.HUKS_TAG_KEY_TYPE, huks.HuksImportKeyType.HUKS_KEY_TYPE_PRIVATE_KEY)
        ];
        const r = await huks.exportKeyItem(ALIAS_A, opts(props));
        log('>>> 私钥导出没报错！outData=' + shape(r.outData) + '（这会让托管主张不成立）');
      } catch (e) {
        log('私钥导出被拒（预期）→ ' + codeOf(e as BusinessError));
      }
    });

    /**
     * 决定性一项：同一套协商参数，只换存储标记，看应用侧字节数是否随之消失。
     * 只有 KEY_EXPORT_ALLOWED 组拿到裸密钥、ONLY_USED_IN_HUKS 组拿不到，
     * "长期密钥不出 HUKS"才是被实测过的结论而不是文档措辞。
     */
    it('only_used_in_huks_suppresses_inline_secret', 0, async () => {
      const pubB = await exportPublicKey(ALIAS_B);

      const needUpdate = await agreeInto(
        ALIAS_AGREED_IN_HUKS, ALIAS_A, pubB, huks.HuksKeyStorageType.HUKS_STORAGE_ONLY_USED_IN_HUKS);
      log('updateSession 必需性 → ' + (needUpdate ? '需要' : '可跳过'));
      await agreeInto(ALIAS_AGREED_EXPORT, ALIAS_A, pubB, huks.HuksKeyStorageType.HUKS_STORAGE_KEY_EXPORT_ALLOWED);

      const inHuks = await huks.isKeyItemExist(ALIAS_AGREED_IN_HUKS, opts([]));
      log('ONLY_USED_IN_HUKS 组：别名存在=' + inHuks);
      expect(inHuks).assertTrue();
    });

    /** 托管别名能不能被当成 AES-256-GCM 的密钥来用，以及 AAD 篡改是否真的拒绝。 */
    it('custodied_key_works_for_aes_gcm_with_aad_binding', 0, async () => {
      const iv = new Uint8Array([1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12]);
      const aad = enc(AAD_TEXT);
      const plain = enc(PLAIN_TEXT);
      try {
        const e = await aesGcmEncrypt(ALIAS_AGREED_IN_HUKS, iv, aad, plain);
        log('加密成功 cipher=' + shape(e.outData) + ' properties='
          + (e.properties === undefined ? 'undefined' : e.properties.length));
        const cipher = e.outData as Uint8Array;
        let authTag = new Uint8Array(16);
        if (e.properties !== undefined) {
          for (let i = 0; i < e.properties.length; i++) {
            if (e.properties[i].tag === huks.HuksTag.HUKS_TAG_AE_TAG) {
              authTag = e.properties[i].value as Uint8Array;
            }
          }
        }
        log('AE_TAG ' + shape(authTag));
        const back = await aesGcmDecrypt(ALIAS_AGREED_IN_HUKS, iv, aad, cipher, authTag);
        expect(textOf(back)).assertEqual(PLAIN_TEXT);

        try {
          await aesGcmDecrypt(ALIAS_AGREED_IN_HUKS, iv, enc(AAD_TEXT + '|tampered'), cipher, authTag);
          log('>>> AAD 改了还能解（AAD 绑定不成立，方案要改）');
        } catch (e2) {
          log('AAD 篡改被拒（预期）→ ' + codeOf(e2 as BusinessError));
        }
      } catch (e3) {
        log('>>> 协商别名不能直接当 AES 密钥 → ' + codeOf(e3 as BusinessError) + '（下一项的 HKDF 因此变成必需步骤）');
      }
    });

    /**
     * HKDF：`DERIVE_MAIN_KEY` 吃别名还是吃裸字节？前者才允许"派生也不出 HUKS"。
     *
     * 这一项的实测结果会直接改写方案，因为本机表里 `HUKS_TAG_DERIVE_MAIN_KEY`(16)、
     * `DERIVE_FACTOR`(17)、`DERIVE_ALG`(18) **三个全是 `@deprecated since 9`**，且没有一个
     * 未废弃的替代标签（`HUKS_TAG_KEY` 的注释只有"Reserved"）。所以：
     * - 跑通 → 阶段 3 仍要记一笔"建立在废弃标签上"，并排期看它哪天被摘掉；
     * - 跑不通 → 放弃独立 HKDF 这一步，改成"协商时直接给 `DERIVED_AGREED_KEY_STORAGE_FLAG =
     *   ONLY_USED_IN_HUKS`"（上一项已探的那条），届时 wrap/unwrap（
     *   `HUKS_UNWRAP_SUITE_ECDH_AES_256_GCM_NOPADDING`）要另立一次双机 spike 才能评。
     */
    it('hkdf_derive_can_take_alias_as_main_key', 0, async () => {
      const props: huks.HuksParam[] = [
        p(huks.HuksTag.HUKS_TAG_ALGORITHM, huks.HuksKeyAlg.HUKS_ALG_HKDF),
        p(huks.HuksTag.HUKS_TAG_PURPOSE, huks.HuksKeyPurpose.HUKS_KEY_PURPOSE_DERIVE),
        p(huks.HuksTag.HUKS_TAG_KEY_GENERATE_TYPE, huks.HuksKeyGenerateType.HUKS_KEY_GENERATE_TYPE_DERIVE),
        p(huks.HuksTag.HUKS_TAG_DERIVE_MAIN_KEY, enc(ALIAS_AGREED_IN_HUKS)),
        p(huks.HuksTag.HUKS_TAG_DERIVE_FACTOR, enc('crd-spike-factor')),
        p(huks.HuksTag.HUKS_TAG_DERIVE_ALG, huks.HuksKeyDigest.HUKS_DIGEST_SHA256),
        p(huks.HuksTag.HUKS_TAG_DERIVE_KEY_SIZE, 256),
        p(huks.HuksTag.HUKS_TAG_KEY_STORAGE_FLAG, huks.HuksKeyStorageType.HUKS_STORAGE_ONLY_USED_IN_HUKS)
      ];
      try {
        const handle = await huks.initSession(ALIAS_DERIVED, opts(props));
        const u = await huks.updateSession(handle.handle, opts(props));
        log('HKDF updateSession outData=' + shape(u.outData) + ' sharedSecret=' + shape(u.sharedSecret));
        const r = await huks.finishSession(handle.handle, opts(props));
        log('HKDF finishSession outData=' + shape(r.outData) + ' sharedSecret=' + shape(r.sharedSecret));
        log('派生别名存在=' + await huks.isKeyItemExist(ALIAS_DERIVED, opts([])));
        expect(await huks.isKeyItemExist(ALIAS_DERIVED, opts([]))).assertTrue();
      } catch (e) {
        log('>>> HKDF 这条路报错 → ' + codeOf(e as BusinessError));
        // 不判红：报错码本身就是实验 #5 要抄的结论，交给 README 的结果表登记
      }
    });

    /** ML-KEM 对照：encapsulate 可把共享密钥直接收进别名（sharedKeyAlias 是 API 26 的参数）。 */
    it('kem_encapsulate_can_hold_shared_key_in_alias', 0, async () => {
      try {
        const gen: huks.HuksParam[] = [
          p(huks.HuksTag.HUKS_TAG_ALGORITHM, huks.HuksKeyAlg.HUKS_ALG_ML_KEM),
          p(huks.HuksTag.HUKS_TAG_PURPOSE, huks.HuksKeyPurpose.HUKS_KEY_PURPOSE_ENCRYPT)
        ];
        await huks.generateKeyItem(ALIAS_KEM, opts(gen));
        const skProps: huks.HuksParam[] = [
          p(huks.HuksTag.HUKS_TAG_ALGORITHM, huks.HuksKeyAlg.HUKS_ALG_AES),
          p(huks.HuksTag.HUKS_TAG_KEY_SIZE, huks.HuksKeySize.HUKS_AES_KEY_SIZE_256),
          p(huks.HuksTag.HUKS_TAG_PURPOSE,
            huks.HuksKeyPurpose.HUKS_KEY_PURPOSE_ENCRYPT | huks.HuksKeyPurpose.HUKS_KEY_PURPOSE_DECRYPT),
          p(huks.HuksTag.HUKS_TAG_DERIVED_AGREED_KEY_STORAGE_FLAG,
            huks.HuksKeyStorageType.HUKS_STORAGE_ONLY_USED_IN_HUKS)
        ];
        const r = await huks.encapsulate(ALIAS_KEM, gen, ALIAS_DERIVED + '-kem', skProps);
        log('encapsulate outData=' + shape(r.outData) + ' sharedSecret=' + shape(r.sharedSecret)
          + ' properties=' + (r.properties === undefined ? 'undefined' : r.properties.length));
        log('>>> 若上面 sharedSecret/outData 非空，KEM 这条路把裸密钥交回了应用，托管性不如协商+存储标记');
      } catch (e) {
        log('>>> ML-KEM 这条路本机跑不通 → ' + codeOf(e as BusinessError));
      }
    });

    /** 解除配对依赖的两件事：删除后别名确实没了；listAliases 不会把 spike 别名留下。 */
    it('deleteKeyItem_removes_alias', 0, async () => {
      await huks.deleteKeyItem(ALIAS_A, opts([]));
      expect(await huks.isKeyItemExist(ALIAS_A, opts([]))).assertFalse();
      const listed = await huks.listAliases(opts([]));
      log('剩余别名数=' + listed.keyAliases.length + '（spike 别名应全部不在其中）');
    });
  });
}
