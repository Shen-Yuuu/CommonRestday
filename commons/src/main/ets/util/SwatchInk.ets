/**
 * 色块前景判定（批次 AD·D-54）。
 *
 * 要修的事实：班次颜色是用户拿取色器（`HdsColorPicker` 的光谱/滑块两档）随便挑的，存进库就是一个
 * 十六进制串；而画它的那几处都把前景写死成暖白。浅色档下白字压在近白底色上对比度只有 1.2–1.8:1，
 * 等于看不见。原先那条"八色按 WCAG 核过 ≥2.99:1"的前提（`ScheduleEditor` 调色板注释）只在
 * 用户真从八色里挑时成立，取色器一开就不成立了。
 *
 * 为什么不能改用 `$r('app.color.text_secondary')` 这类资源对：资源随深浅色模式翻面，而**用户选的底色不翻**。
 * 深色档里 text_secondary 是浅紫，压在同一块浅灰休息色上实测 1.11:1——比不翻面还糟。
 * 所以这一族要的是"由底色自己决定"的两个固定墨色，与模式无关。
 *
 * 公式按 WCAG 2.1 原文实现，不靠"看着够不够深"：
 *   L = 0.2126·R + 0.7152·G + 0.0722·B，通道先做 sRGB 线性化（c/255 ≤ 0.04045 走 /12.92，否则幂）
 *   contrast = (L_亮 + 0.05) / (L_暗 + 0.05)
 * 两个候选前景取对比度更高的那个；相等时留暖白（改之前就是这个，不制造无谓的翻面）。
 */

/** 亮底那一侧的墨：与 `app.color.swatch_fg` 同值。资源里的字面量与本处必须一致，改一处要改两处。 */
const INK: string = '#5C4750';
/** 暗底那一侧的墨：与 `app.color.hero_fg` 同值，两档模式下都是纯白。 */
const WARM_WHITE: string = '#FFFFFF';
/** 允许的十六进制位（大小写都收，取色器两种都给过）。 */
const HEX_DIGITS: string = '0123456789abcdefABCDEF';

/** 解析出来的三个通道，取值 0–1。 */
interface Rgb {
  r: number;
  g: number;
  b: number;
}

/** sRGB 单通道线性化（WCAG 的那条分段函数）。 */
function linearize(channel: number): number {
  return channel <= 0.04045 ? channel / 12.92 : Math.pow((channel + 0.055) / 1.055, 2.4);
}

/** 相对亮度 L。 */
function luminanceOf(rgb: Rgb): number {
  return 0.2126 * linearize(rgb.r) + 0.7152 * linearize(rgb.g) + 0.0722 * linearize(rgb.b);
}

/** 两个亮度之间的对比度。 */
function contrastOf(l1: number, l2: number): number {
  const hi = l1 > l2 ? l1 : l2;
  const lo = l1 > l2 ? l2 : l1;
  return (hi + 0.05) / (lo + 0.05);
}

/**
 * 认 `#RGB`／`#RRGGBB`／`#AARRGGBB`。ArkUI 的带 alpha 写法是 **AARRGGBB**（alpha 在最前），
 * 所以长度为 8 时丢掉前两位而不是后两位。alpha 不参与判定：班次色按不透明画，判"浅不浅"看色相明度本身。
 * 逐字符核十六进制位：`parseInt('12ab34', 16)` 会在第一个非法字符处停下并返回 0x12ab，
 * 不核就会把"坏串"读成一个真实在的颜色。
 */
function parseRgb(color: string): Rgb | null {
  if (color.length === 0 || color.charAt(0) !== '#') {
    return null;
  }
  let body: string = color.substring(1);
  if (body.length === 3) {
    body = body.charAt(0) + body.charAt(0) + body.charAt(1) + body.charAt(1) + body.charAt(2) + body.charAt(2);
  } else if (body.length === 8) {
    body = body.substring(2);
  }
  if (body.length !== 6) {
    return null;
  }
  for (let i = 0; i < body.length; i++) {
    if (HEX_DIGITS.indexOf(body.charAt(i)) < 0) {
      return null;
    }
  }
  const value: number = Number.parseInt(body, 16);
  const rgb: Rgb = {
    r: ((value >> 16) & 255) / 255,
    g: ((value >> 8) & 255) / 255,
    b: (value & 255) / 255
  };
  return rgb;
}

/** 内部用的亮度取值：解析失败按最暗（0）算。 */
function luminanceOr(color: string): number {
  const rgb: Rgb | null = parseRgb(color);
  return rgb === null ? 0 : luminanceOf(rgb);
}

/**
 * 两个固定前景的相对亮度：常量，模块加载期算一次，不必在每个节点上重算。
 * 这两串是本文件写的字面量，解析必定成功；真要留个兜底就取 0（最暗），于是 prefersInk 选暖白——
 * 与"认不出来就维持改之前的样子"同一口径。
 */
const INK_L: number = luminanceOr(INK);
const WHITE_L: number = luminanceOr(WARM_WHITE);

export class SwatchInk {
  /**
   * 底色认不出来时返回 null，让调用方保留改之前的暖白——判不了就不改，也就不会把已经能看的字改坏。
   * 名字里的"亮度"是 WCAG 的 relative luminance，不是 HSL 的 L，两者不等价（黄色 HSL 很亮、相对亮度更低）。
   */
  static luminance(color: string): number | null {
    const rgb: Rgb | null = parseRgb(color);
    return rgb === null ? null : luminanceOf(rgb);
  }

  /** 这块色与某个前景之间的对比度；任一侧解析失败返回 0（于是永远选不上它）。 */
  static contrast(color: string, foreground: string): number {
    const l1: number | null = SwatchInk.luminance(color);
    const l2: number | null = SwatchInk.luminance(foreground);
    return (l1 === null || l2 === null) ? 0 : contrastOf(l1, l2);
  }

  /** 该用深墨（亮底）还是暖白（暗底）。相等留暖白。 */
  static prefersInk(color: string): boolean {
    const l: number | null = SwatchInk.luminance(color);
    if (l === null) {
      return false;
    }
    return contrastOf(l, INK_L) > contrastOf(l, WHITE_L);
  }

  static inkHex(): string {
    return INK;
  }

  static warmWhiteHex(): string {
    return WARM_WHITE;
  }
}
