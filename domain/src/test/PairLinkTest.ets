import { describe, it, expect } from '@ohos/hypium';
import { PairLink, PairLinkKind } from '../main/ets/pair/PairLink';

/** 24 个 base64url 字符，够到一次性凭据的熵下限（≥22 位 ≈132 bit）。 */
const TOKEN = 'Zm9yLW9uZS11c2Utb25seS0x';
const LONG_TOKEN = 'aAbBcCdDeEfFgGhHiIjJkKlLmMnNoOpPqQrRsStT';

function nowSec(): number {
  return Math.floor(Date.now() / 1000);
}

export default function pairLinkTest() {
  describe('pairLink', () => {
    it('link_carries_only_the_single_use_token', 0, () => {
      expect(PairLink.build(LONG_TOKEN, 0)).assertEqual('crdpair://join?t=' + LONG_TOKEN);
      expect(PairLink.build(LONG_TOKEN, 1893456000))
        .assertEqual('crdpair://join?t=' + LONG_TOKEN + '&exp=1893456000');
    });

    it('round_trip_offer', 0, () => {
      const r = PairLink.parse(PairLink.build(LONG_TOKEN, nowSec() + 600));
      expect(r.kind).assertEqual(PairLinkKind.OFFER);
      expect(r.offer !== null).assertTrue();
      if (r.offer !== null) {
        expect(r.offer.token).assertEqual(LONG_TOKEN);
        expect(r.offer.expiresAt > nowSec()).assertTrue();
      }
    });

    it('short_code_is_not_a_valid_credential', 0, () => {
      // 门禁：6 位配对码不进二维码/链接。够不到熵下限，就构造不出合法链接、也解析不出请求
      expect(PairLink.tokenValid('123456')).assertFalse();
      expect(PairLink.build('123456', 0)).assertEqual('');
      expect(PairLink.parse('crdpair://join?t=123456').kind).assertEqual(PairLinkKind.MALFORMED);
    });

    it('token_charset_is_b64url_only', 0, () => {
      expect(PairLink.tokenValid(TOKEN)).assertTrue();
      expect(PairLink.tokenValid('abcdefghijkl+mnopqrstu')).assertFalse();
      expect(PairLink.tokenValid('abcdefghijkl%mnopqrstu')).assertFalse();
      expect(PairLink.tokenValid('abcdefghijkl-mnopqrstu')).assertTrue();
      // 字符集外的 token 若被拼进链接，解析时必然落不进 OFFER
      expect(PairLink.parse('crdpair://join?t=abcdefghijkl+mnopqrstu').kind)
        .assertEqual(PairLinkKind.MALFORMED);
    });

    it('expired_offer_is_reported_not_offered', 0, () => {
      const r = PairLink.parse('crdpair://join?t=' + LONG_TOKEN + '&exp=' + (nowSec() - 60));
      expect(r.kind).assertEqual(PairLinkKind.EXPIRED);
      // 过期也要说清是哪一次请求，但调用方不能带着它进确认流程
      expect(r.offer !== null).assertTrue();
    });

    it('foreign_text_never_reaches_confirm', 0, () => {
      expect(PairLink.parse('').kind).assertEqual(PairLinkKind.FOREIGN);
      expect(PairLink.parse('   ').kind).assertEqual(PairLinkKind.FOREIGN);
      expect(PairLink.parse('https://example.com/').kind).assertEqual(PairLinkKind.FOREIGN);
      // 我们的 scheme 但路径不对：判不合口径，不当成配对请求
      expect(PairLink.parse('crdpair://other?t=' + LONG_TOKEN).kind).assertEqual(PairLinkKind.MALFORMED);
    });

    it('unknown_params_are_ignored', 0, () => {
      // 进程外字符串不许带行为指令：多塞的键一律不参与判定
      const r = PairLink.parse('crdpair://join?t=' + LONG_TOKEN + '&auto=1&x=y');
      expect(r.kind).assertEqual(PairLinkKind.OFFER);
      if (r.offer !== null) {
        expect(r.offer.token).assertEqual(LONG_TOKEN);
        expect(r.offer.expiresAt).assertEqual(0);
      }
    });

    it('mask_hides_the_middle', 0, () => {
      const m = PairLink.mask(LONG_TOKEN);
      expect(m).assertEqual('aAbBcC…sStT');
      expect(m.indexOf(LONG_TOKEN) < 0).assertTrue();
      expect(PairLink.mask('short')).assertEqual('****');
    });
  });
}
