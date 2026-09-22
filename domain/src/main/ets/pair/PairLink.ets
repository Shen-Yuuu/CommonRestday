/**
 * 配对链接与二维码的一次性 token 编解码（阶段 4 Task 4.1）。
 *
 * 为什么链接里不放 6 位配对码：门禁规定邀请码不得直接派生长期密钥，且长期密钥与邀请历史
 * 不得进二维码/分享链接（docs/validation/clouddev-api26-spike.md §4、
 * docs/cloud/pairing-protocol-v1.md §2）。二维码会被截图、转发、被第三方扫码器记进历史，
 * 所以它只能承载**服务端签发、一次一用、短期有效**的 token；短码走"说出来/输码"这条人路。
 *
 * 格式：`crdpair://join?t=<base64url>&exp=<epochSec>`
 * - `t` 必填，长度 ≥22（≈132 bit）保证不可穷举；
 * - `exp` 可选，缺省 0 表示"端上无法判断过期"，由服务端兜底；
 * - 其余参数一律忽略：解析器不接受任何端外传入的行为指令。
 */

/** 一次性配对凭据（token 本身即凭据，不含身份与密钥）。 */
export interface PairOffer {
  token: string;
  /** 过期时刻（epoch 秒）；0 = 链接未给，交由服务端判定。 */
  expiresAt: number;
}

/** 扫到/收到的字符串是什么。FOREIGN 与 MALFORMED 分开：前者不该弹确认页。 */
export enum PairLinkKind {
  /** 本应用的一次性配对链接，可以弹确认页。 */
  OFFER = 'OFFER',
  /** 已过期的一次性凭据：仍要让用户知道扫到过什么，但不进确认流程。 */
  EXPIRED = 'EXPIRED',
  /** 不是本应用的码（普通网址、支付码…）。 */
  FOREIGN = 'FOREIGN',
  /** 是本应用前缀但内容不合口径（含"看起来像短码"的 token）。 */
  MALFORMED = 'MALFORMED'
}

export interface PairLinkResult {
  kind: PairLinkKind;
  offer: PairOffer | null;
}

export const PAIR_LINK_SCHEME = 'crdpair';
const LINK_PREFIX = PAIR_LINK_SCHEME + '://join';
/** token 下限 22 个 base64 字符 ≈132 bit：6 位数字（10^6）远够不到，也就冒充不进来。 */
const TOKEN_MIN = 22;
const TOKEN_MAX = 128;

const B64URL = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_';

export class PairLink {
  /** 生成分享/二维码文本；token 不合口径就返回空串（调用方据此不渲染二维码）。 */
  static build(token: string, expiresAt: number): string {
    if (!PairLink.tokenValid(token)) {
      return '';
    }
    return expiresAt > 0 ? LINK_PREFIX + '?t=' + token + '&exp=' + expiresAt
      : LINK_PREFIX + '?t=' + token;
  }

  /**
   * 解析扫码结果或深链 want.uri。
   * 传入字符串来自进程外（相机、别的 App），所以这里只做"识别 + 拒绝"，不做任何执行。
   */
  static parse(text: string): PairLinkResult {
    const s = text.trim();
    if (s === '') {
      return result(PairLinkKind.FOREIGN, null);
    }
    if (!s.startsWith(PAIR_LINK_SCHEME + ':')) {
      return result(PairLinkKind.FOREIGN, null);
    }
    if (!s.startsWith(LINK_PREFIX)) {
      return result(PairLinkKind.MALFORMED, null);
    }
    const query = s.substring(s.indexOf('?') < 0 ? s.length : s.indexOf('?') + 1);
    const token = paramOf(query, 't');
    if (!PairLink.tokenValid(token)) {
      return result(PairLinkKind.MALFORMED, null);
    }
    const exp = Number.parseInt(paramOf(query, 'exp'), 10);
    const expiresAt = Number.isNaN(exp) || exp < 0 ? 0 : exp;
    const offer: PairOffer = { token: token, expiresAt: expiresAt };
    if (expiresAt > 0 && expiresAt <= nowSec()) {
      return result(PairLinkKind.EXPIRED, offer);
    }
    return result(PairLinkKind.OFFER, offer);
  }

  /** 一次性凭据格式：base64url 定长区间，字符集外一位都不放过。 */
  static tokenValid(token: string): boolean {
    if (token.length < TOKEN_MIN || token.length > TOKEN_MAX) {
      return false;
    }
    for (let i = 0; i < token.length; i++) {
      if (B64URL.indexOf(token.charAt(i)) < 0) {
        return false;
      }
    }
    return true;
  }

  /** 确认页展示用：只露首尾，中间打码。截图与读屏都不必把整条凭据说出去。 */
  static mask(token: string): string {
    if (token.length < 12) {
      return '****';
    }
    return token.substring(0, 6) + '…' + token.substring(token.length - 4);
  }
}

/** 过期判定读的是本机钟：链接里的 exp 只做"明显过期"的早退，服务端仍是最终裁判。 */
function nowSec(): number {
  return Math.floor(Date.now() / 1000);
}

/** 取查询参数：只认精确键名，值里不含第二个 '='（token 是 base64url，不需要反转义）。 */function paramOf(query: string, key: string): string {
  const parts: string[] = query.split('&');
  for (let i = 0; i < parts.length; i++) {
    const kv = parts[i];
    const eq = kv.indexOf('=');
    if (eq > 0 && kv.substring(0, eq) === key) {
      return kv.substring(eq + 1);
    }
  }
  return '';
}

function result(kind: PairLinkKind, offer: PairOffer | null): PairLinkResult {
  const r: PairLinkResult = { kind: kind, offer: offer };
  return r;
}
