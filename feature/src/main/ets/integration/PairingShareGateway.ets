import { scanBarcode, scanCore } from '@kit.ScanKit';
import { systemShare } from '@kit.ShareKit';
import { uniformTypeDescriptor } from '@kit.ArkData';
import { common } from '@kit.AbilityKit';
import { BusinessError, pasteboard } from '@kit.BasicServicesKit';
import { Logger } from 'commons';
import { PairLink, PairLinkKind, PairOffer } from 'domain';
import { FeatureFlags } from '../config/FeatureFlags';

/**
 * 扫码 / 二维码 / 系统分享的设备侧门面（阶段 4 Task 4.1）。
 *
 * 三条口径写在这里，页面不再各自判断：
 * 1. **先检测能力再摆入口**：`canIUse` 决定扫码/分享入口是否出现，没有扫码能力时短码就是主路径；
 * 2. **只认一次性 token**：二维码与分享链接的内容一律由 `PairLink` 生成/校验（6 位配对码不进链接）；
 * 3. **不自动绑定**：这个门面对扫到/收到的请求只做"收下 + 广播"，是否配对由用户在确认页点头，
 *    而门禁（Task 0.4 = `CLOUD_BLOCKED`）未解除时「接受」也只到此为止——不写配对标记、不写密钥。
 * 与 CalendarGateway 同一 doctrine：任何设备异常都归一成结果码，绝不向页面抛出去。
 */

const TAG = 'PairingShareGateway';
/** 系统能力键写错不会报错、只会恒为 false，所以逐字对照 SDK 的 @syscap 注释。 */
const SYSCAP_SCAN = 'SystemCapability.Multimedia.Scan.ScanBarcode';
const SYSCAP_SHARE = 'SystemCapability.Collaboration.SystemShare';
/** 跨页广播：新配对请求到达 → 壳层切到「我的」→ 页面弹确认。与 recomputeCount 同一套机制。 */
export const PAIR_OFFER_KEY = 'pairOfferCount';
/** Scan Kit 口径：1000500002 是用户主动取消（不是失败）；1000500001 内部错误在模拟器上最常见。 */
const SCAN_CANCELLED = 1000500002;
const SCAN_INTERNAL = 1000500001;
/** 云端未开通的统一说法（与验收清单 §9.1 一致）。 */
export const PAIR_CLOUD_CLOSED = '云端配对暂未开放（需开通 AGC 云服务），可先用本机代录';

/** 入口该怎么摆：emphasizeCode 为真时把 6 位短码抬成主路径。 */
export interface PairChannels {
  /** 扫码入口是否出现：能力具备 且 scanPairing 开关打开（真机验证前保持关闭）。 */
  scan: boolean;
  /** 系统分享面板是否可用。 */
  share: boolean;
  /** 无扫码能力：短码要用大字展示并说明怎么用它。 */
  emphasizeCode: boolean;
}

export enum ScanOutcome {
  /** 扫到合法的一次性配对请求。 */
  OFFER = 'OFFER',
  /** 扫到过期的凭据。 */
  EXPIRED = 'EXPIRED',
  /** 扫到的不是本应用的码。 */
  FOREIGN = 'FOREIGN',
  /** 用户自己退出了扫码。 */
  CANCELED = 'CANCELED',
  /** 能力不可用或模拟器跑不通：需真机复验，不判失败。 */
  UNSUPPORTED = 'UNSUPPORTED',
  /** 其他设备侧失败。 */
  FAILED = 'FAILED'
}

export interface ScanResult {
  outcome: ScanOutcome;
  offer: PairOffer | null;
  message: string;
}

export interface PairOpResult {
  ok: boolean;
  message: string;
}

export class PairingShareGateway {
  private static context: common.UIAbilityContext | null = null;
  /**
   * 待确认的配对请求只放在进程内存：一次性凭据不落 Preferences、不进日志（门禁 §4 第 3 条）。
   * 页面还没挂载时冷启动深链先到这里，页面 aboutToAppear 再取走，请求不会因为晚挂载而丢。
   */
  private static offered: PairOffer | null = null;

  /** 分享面板与扫码默认视图都要宿主上下文；拿不到时两条通道都按不可用处理。 */
  static init(context: common.UIAbilityContext): void {
    PairingShareGateway.context = context;
  }

  /** 上下文没就绪时不抛错，按能力不可用处理。 */
  private static host(): common.UIAbilityContext | null {
    return PairingShareGateway.context;
  }

  /** 能力探测：一次读出来，页面只管摆或不摆。 */
  static channels(): PairChannels {
    const scanCap = canIUse(SYSCAP_SCAN);
    const out: PairChannels = {
      scan: scanCap && FeatureFlags.scanPairing,
      share: canIUse(SYSCAP_SHARE),
      emphasizeCode: !scanCap
    };
    return out;
  }

  /**
   * 拉起 Scan Kit 默认扫码视图（免 CAMERA 权限：`@permission ohos.permission.CAMERA` 只出现在 customScan）。
   * 结果只解析、不执行：合法请求交给调用方去弹确认页。
   */
  static async offerFromScan(): Promise<ScanResult> {
    const ctx = PairingShareGateway.host();
    if (ctx == null || !canIUse(SYSCAP_SCAN)) {
      return scanFail(ScanOutcome.UNSUPPORTED, '本机不支持扫码，请用 6 位配对码');
    }
    const types: scanCore.ScanType[] = [scanCore.ScanType.QR_CODE];
    const options: scanBarcode.ScanOptions = { scanTypes: types, enableMultiMode: false, enableAlbum: false };
    try {
      const res: scanBarcode.ScanResult = await scanBarcode.startScanForResult(ctx, options);
      return classify(res.originalValue);
    } catch (e) {
      const code = (e as BusinessError).code;
      if (code === SCAN_CANCELLED) {
        return scanFail(ScanOutcome.CANCELED, '');
      }
      // 模拟器缺 Scan Kit 后端时报的就是内部错误：按"未验证"处理，不能据此判扫码不可用
      if (code === SCAN_INTERNAL) {
        return scanFail(ScanOutcome.UNSUPPORTED, '扫码结果需真机复验（模拟器不具备完整扫码能力）');
      }
      Logger.warn(TAG, 'scan failed: ' + code);
      return scanFail(ScanOutcome.FAILED, '扫码失败，请重试或改用 6 位配对码');
    }
  }

  /**
   * 分享一次性配对链接。
   * link 为空（服务端还没签发 token）时直接拒绝：没有合规内容可分享，就不该打开分享面板。
   */
  static async shareLink(link: string): Promise<PairOpResult> {
    if (link === '') {
      return fail('没有可分享的配对链接：链接只承载服务端签发的一次性凭据，请把 6 位配对码告诉 TA');
    }
    if (PairLink.parse(link).kind !== PairLinkKind.OFFER) {
      return fail('配对链接已失效，请重新生成');
    }
    const ctx = PairingShareGateway.host();
    if (ctx == null || !canIUse(SYSCAP_SHARE)) {
      return PairingShareGateway.copyText(link);
    }
    try {
      const record: systemShare.SharedRecord = {
        utd: uniformTypeDescriptor.UniformDataType.PLAIN_TEXT, content: link
      };
      const data = new systemShare.SharedData(record);
      const options: systemShare.ShareControllerOptions = {
        selectionMode: systemShare.SelectionMode.SINGLE,
        previewMode: systemShare.SharePreviewMode.DEFAULT
      };
      await new systemShare.ShareController(data).show(ctx, options);
      Logger.info(TAG, 'pair link handed to system share');
      return ok('已打开系统分享');
    } catch (e) {
      Logger.warn(TAG, 'share failed: ' + (e as BusinessError).code);
      return PairingShareGateway.copyText(link);
    }
  }

  /** 退路：复制到剪贴板。配对码与链接都走这里，不打印内容。 */
  static async copyText(text: string): Promise<PairOpResult> {
    if (text === '') {
      return fail('没有可复制的内容');
    }
    try {
      const data = pasteboard.createData(pasteboard.MIMETYPE_TEXT_PLAIN, text);
      await pasteboard.getSystemPasteboard().setData(data);
      return ok('已复制到剪贴板');
    } catch (e) {
      Logger.warn(TAG, 'clipboard copy failed: ' + (e as BusinessError).code);
      return fail('复制失败，请手动记下');
    }
  }

  /**
   * 收下外部来的配对意图（want.uri）。
   * 非 OFFER 一律不留痕：外来的普通网址/别的 App 的码不该在本机产生任何待确认状态。
   */
  static offerIncoming(rawUri: string): boolean {
    const res = PairLink.parse(rawUri);
    if (res.kind !== PairLinkKind.OFFER || res.offer === null) {
      return false;
    }
    PairingShareGateway.offered = res.offer;
    bumpOffer();
    Logger.info(TAG, 'pair offer received');
    return true;
  }

  /** 页面挂载后补取：深链比页面早到时（冷启动）靠这个不丢请求。 */
  static peekOffer(): PairOffer | null {
    return PairingShareGateway.offered;
  }

  /** 取走并清空：一次性凭据不重复消费。 */
  static takeOffer(): PairOffer | null {
    const o = PairingShareGateway.offered;
    PairingShareGateway.offered = null;
    return o;
  }

  /**
   * 用户在确认页点「接受」后的唯一入口。
   * Task 0.4 的结论是 CLOUD_BLOCKED：开关关着就到此为止，不写 pairId、不写密钥、不改配对状态。
   * 门禁解除后这里接 pairing-confirm（见 docs/cloud/pairing-protocol-v1.md §4），仍由页面在用户点头后调用。
   */
  static async acceptOffer(): Promise<PairOpResult> {
    PairingShareGateway.takeOffer();
    if (!FeatureFlags.cloudPairing) {
      return fail(PAIR_CLOUD_CLOSED);
    }
    return fail('云端配对尚未接通：等待服务端确认（pairing-confirm 未部署）');
  }

  /** 用户忽略这次请求：清干净即可，不提示成功。 */
  static ignoreOffer(): void {
    PairingShareGateway.takeOffer();
    Logger.info(TAG, 'pair offer ignored');
  }
}

/** 扫码结果按一次性凭据口径分类：认不出的一律不进确认流程。 */
function classify(text: string): ScanResult {
  const res = PairLink.parse(text);
  if (res.kind === PairLinkKind.OFFER) {
    Logger.info(TAG, 'pair link scanned');
    return scanOffer(res.offer);
  }
  if (res.kind === PairLinkKind.EXPIRED) {
    return scanFail(ScanOutcome.EXPIRED, '这个配对链接已过期，请对方重新生成');
  }
  if (res.kind === PairLinkKind.MALFORMED) {
    return scanFail(ScanOutcome.FAILED, '二维码内容不是有效的配对链接');
  }
  return scanFail(ScanOutcome.FOREIGN, '这不是同休日的配对码');
}

function scanOffer(offer: PairOffer | null): ScanResult {
  const r: ScanResult = { outcome: ScanOutcome.OFFER, offer: offer, message: '' };
  return r;
}

function scanFail(outcome: ScanOutcome, message: string): ScanResult {
  const r: ScanResult = { outcome: outcome, offer: null, message: message };
  return r;
}

function bumpOffer(): void {
  const cur: number = AppStorage.get<number>(PAIR_OFFER_KEY) ?? 0;
  AppStorage.setOrCreate<number>(PAIR_OFFER_KEY, cur + 1);
}

function ok(message: string): PairOpResult {
  const r: PairOpResult = { ok: true, message: message };
  return r;
}

function fail(message: string): PairOpResult {
  const r: PairOpResult = { ok: false, message: message };
  return r;
}
