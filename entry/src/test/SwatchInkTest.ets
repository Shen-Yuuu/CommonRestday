import { describe, it, expect } from '@ohos/hypium';
import { SwatchInk } from 'commons';

/**
 * 色块前景判定（批次 AD·D-54）。
 *
 * 这一族断言钉的是"取对比度更高的那个前景"这条判据本身，不是某个颜色此刻好不好看：
 * 班次底色来自取色器（任意十六进制串），所以只有判据能被复算，色值不能。
 * 数值全部按 WCAG 的相对亮度现算，注释里的比值是实测值，改动公式或两个固定墨色时这里会先红。
 */

/** 与 ScheduleEditor 的 COLORS 同一组字面值（存库的是字面量，所以这里也写字面量）。 */
const PALETTE: string[] =
  ['#EF6F42', '#4E97DB', '#9A6BDC', '#F0568C', '#5B6ACF', '#3A9E6E', '#C08A2A', '#8E8397'];

const INK: string = SwatchInk.inkHex();
const WHITE: string = SwatchInk.warmWhiteHex();

/**
 * 判据的下限（闭式解，不靠采样）：两条对比度曲线相交时"较高的那个"取到最小，
 * 值为 sqrt(1.05 / (L(ink) + 0.05)) = 2.9145。写死暖白没有这条下限——白字压在近白的分隔底色上只有 1.29:1。
 */
const FLOOR: number = 2.914;

/** 任选其一后的对比度。 */
function pickedContrast(color: string): number {
  return SwatchInk.prefersInk(color) ? SwatchInk.contrast(color, INK) : SwatchInk.contrast(color, WHITE);
}

export default function swatchInkTest() {
  describe('swatchInk', () => {

    it('palette_eight_still_choose_warm_white', 0, () => {
      // 改之前八色就是白字，新判据对它们不改判——这条是"本批不制造视觉 delta"的证据
      for (let i = 0; i < PALETTE.length; i++) {
        const c: string = PALETTE[i];
        expect(SwatchInk.prefersInk(c)).assertFalse();
        expect(SwatchInk.contrast(c, WHITE) >= 2.9).assertTrue();
      }
    });

    it('light_neutrals_choose_ink', 0, () => {
      // 休息灰与"班次 id 认不出"灰：白字压上去只有 1.78 / 1.61:1，改之前是真看不见
      expect(SwatchInk.prefersInk('#B8C4CE')).assertTrue();
      expect(SwatchInk.contrast('#B8C4CE', INK) >= 4.7).assertTrue();
      expect(SwatchInk.prefersInk('#CCCCCC')).assertTrue();
      expect(SwatchInk.contrast('#CCCCCC', INK) >= 5.2).assertTrue();
      // 取色器挑得到的两端
      expect(SwatchInk.prefersInk('#FFFFFF')).assertTrue();
      expect(SwatchInk.contrast('#FFFFFF', INK) >= 8.4).assertTrue();
      expect(SwatchInk.prefersInk('#F5DCE6')).assertTrue();
      expect(SwatchInk.prefersInk('#000000')).assertFalse();
      expect(SwatchInk.contrast('#000000', WHITE) >= 20.9).assertTrue();
      expect(SwatchInk.prefersInk('#463860')).assertFalse();
    });

    it('threshold_is_the_higher_contrast_side_not_a_hue_guess', 0, () => {
      // 纯灰上两条曲线交叉的那一格：#979797 仍是白略高（2.921 vs 2.908），#989898 起换成墨（2.885 vs 2.945）。
      // 钉这一对相邻值，是为了证明判据是"谁对比度高选谁"，而不是"看着深不深"或某个阈值。
      expect(SwatchInk.prefersInk('#979797')).assertFalse();
      expect(SwatchInk.prefersInk('#989898')).assertTrue();
    });

    it('chosen_foreground_never_drops_below_the_floor', 0, () => {
      const probe: string[] = ['#979797', '#989898', '#FFFFFF', '#000000', '#B8C4CE', '#CCCCCC',
        '#F5DCE6', '#463860', '#FFFF00', '#00FFFF', '#FF00FF', '#EF6F42', '#C08A2A'];
      for (let i = 0; i < probe.length; i++) {
        expect(pickedContrast(probe[i]) >= FLOOR).assertTrue();
      }
    });

    it('parse_accepts_short_and_alpha_forms', 0, () => {
      // #RGB 展开成 #RRGGBB
      expect(SwatchInk.contrast('#FFF', INK) >= 8.4).assertTrue();
      expect(SwatchInk.contrast('#fff', INK) >= 8.4).assertTrue();
      // ArkUI 的带 alpha 写法是 AARRGGBB（alpha 在最前），丢前两位而不是后两位：
      // #80FF0000 是半透明红，判定要与不透明红 #FF0000 同一条前景
      expect(SwatchInk.prefersInk('#80FF0000')).assertFalse();
      expect(SwatchInk.prefersInk('#FF0000')).assertFalse();
      expect(SwatchInk.prefersInk('#ffffffff')).assertTrue();
    });

    it('unparsable_leaves_the_previous_warm_white', 0, () => {
      // 判不了就不改：留暖白是改之前的样子，不会因为一个读不懂的串把已经能看的字改坏
      expect(SwatchInk.luminance('red') === null).assertTrue();
      expect(SwatchInk.luminance('123456') === null).assertTrue();
      expect(SwatchInk.luminance('') === null).assertTrue();
      expect(SwatchInk.luminance('#12345') === null).assertTrue();
      expect(SwatchInk.luminance('#1234567') === null).assertTrue();
      expect(SwatchInk.prefersInk('')).assertFalse();
      // 截断陷阱：Number.parseInt('12ab34', 16) 返回 0x12ab 而不是 NaN，
      // 不逐字符核十六进制位就会把"坏串"读成一个真在的颜色。
      expect(SwatchInk.luminance('#12ab34zz') === null).assertTrue();
      expect(SwatchInk.luminance('#GGHHII') === null).assertTrue();
      expect(SwatchInk.contrast('red', WHITE)).assertEqual(0);
      expect(SwatchInk.contrast('#FFFFFF', 'nope')).assertEqual(0);
    });

    it('the_two_inks_are_the_literals_the_resources_use', 0, () => {
      // app.color.swatch_fg（base 与 dark 同值）与 app.color.hero_fg 必须与这两个串一致；
      // 串改了而资源没改，判出来的前景就压不中那块底——一致性由 contrast-audit 的 C2 逐档核。
      expect(INK).assertEqual('#5C4750');
      expect(WHITE).assertEqual('#FFFFFF');
    });
  });
}
