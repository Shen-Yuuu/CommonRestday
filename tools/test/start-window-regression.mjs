/** 原生启动页配置检查，不代替设备冷启动截图验收。 */
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { inflateSync } from 'node:zlib';

const repo = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '../..');
const read = (p) => fs.readFileSync(path.join(repo, p), 'utf8');
const res = 'entry/src/main/resources/';
const config = JSON.parse(read(res + 'base/profile/start_window.json'));
assert.deepEqual(config, {
  startWindowType: 'REQUIRED_SHOW',
  startWindowColorModeType: 'FOLLOW_SYSTEM',
  startWindowAppIcon: '$media:start_icon_rounded',
  startWindowBrandingImage: '$media:start_brand',
  startWindowBackgroundColor: '$color:start_window_background'
});
const module = read('entry/src/main/module.json5');
assert.match(module, /"startWindow"\s*:\s*"\$profile:start_window"/);
assert.match(module, /"startWindowIcon"\s*:\s*"\$media:start_icon_rounded"/);
assert.match(module, /"icon"\s*:\s*"\$media:jim1_resized"/, '桌面入口图标不改');
assert.ok(fs.statSync(path.join(repo, 'AppScope/resources/base/media/jim1_resized.png')).size > 0);

/** 独立读取两张 PNG 的原始 RGBA，避免只凭文件名或绘图工具自身校验认定裁剪正确。 */
function rgbaPng(file) {
  const png = fs.readFileSync(path.join(repo, file));
  assert.deepEqual([...png.subarray(0, 8)], [137, 80, 78, 71, 13, 10, 26, 10]);
  const width = png.readUInt32BE(16), height = png.readUInt32BE(20);
  assert.equal(png[24], 8);
  assert.equal(png[25], 6, '启动资产使用 RGBA PNG');
  assert.equal(png[28], 0, '测试资产不使用交错扫描');
  const blocks = [];
  for (let at = 8; at < png.length;) {
    const length = png.readUInt32BE(at);
    if (png.toString('ascii', at + 4, at + 8) === 'IDAT') blocks.push(png.subarray(at + 8, at + 8 + length));
    at += length + 12;
  }
  const raw = inflateSync(Buffer.concat(blocks));
  const stride = width * 4, pixels = Buffer.alloc(stride * height);
  assert.equal(raw.length, (stride + 1) * height);
  function paeth(a, b, c) {
    const p = a + b - c, da = Math.abs(p - a), db = Math.abs(p - b), dc = Math.abs(p - c);
    return da <= db && da <= dc ? a : db <= dc ? b : c;
  }
  for (let y = 0; y < height; y++) {
    const type = raw[y * (stride + 1)];
    assert.ok(type >= 0 && type <= 4);
    for (let x = 0; x < stride; x++) {
      const index = y * stride + x;
      const left = x >= 4 ? pixels[index - 4] : 0;
      const above = y > 0 ? pixels[index - stride] : 0;
      const corner = y > 0 && x >= 4 ? pixels[index - stride - 4] : 0;
      const prediction = [0, left, above, Math.floor((left + above) / 2), paeth(left, above, corner)][type];
      pixels[index] = (raw[y * (stride + 1) + 1 + x] + prediction) & 255;
    }
  }
  return { width, height, pixels };
}
const original = rgbaPng('AppScope/resources/base/media/jim1_resized.png');
const rounded = rgbaPng(res + 'base/media/start_icon_rounded.png');
assert.equal(rounded.width, original.width);
assert.equal(rounded.height, original.height);
const radius = Math.min(rounded.width, rounded.height) * 0.22;
let changedAlpha = 0;
for (let y = 0; y < rounded.height; y++) {
  for (let x = 0; x < rounded.width; x++) {
    const i = (y * rounded.width + x) * 4;
    for (let c = 0; c < 3; c++) assert.equal(rounded.pixels[i + c], original.pixels[i + c], '不改变图案 RGB');
    assert.ok(rounded.pixels[i + 3] <= original.pixels[i + 3]);
    if (rounded.pixels[i + 3] !== original.pixels[i + 3]) changedAlpha++;
    if ((x >= radius && x + 1 <= rounded.width - radius)
      || (y >= radius && y + 1 <= rounded.height - radius)) {
      assert.equal(rounded.pixels[i + 3], original.pixels[i + 3], '内部透明度不改');
    }
  }
}
assert.ok(changedAlpha > 0, '不能用未裁剪原图冒充圆角');
for (const [x, y] of [[0, 0], [rounded.width - 1, 0], [0, rounded.height - 1], [rounded.width - 1, rounded.height - 1]]) {
  assert.equal(rounded.pixels[(y * rounded.width + x) * 4 + 3], 0, '四角透明');
}
for (const mode of ['base', 'dark']) {
  const svg = read(res + mode + '/media/start_brand.svg');
  assert.match(svg, /viewBox="0 0 320 120"/);
  assert.match(svg, /两人份 \/ ForTwo/);
  assert.equal((svg.match(/<path\b/g) || []).length, 2, '中英字标各为一条轮廓路径');
  assert.doesNotMatch(svg, /<text\b|<image\b|<script\b|href=|font-family=/,
    '不依赖 SVG 文本字体、外部图片或脚本');
  const colors = JSON.parse(read(res + mode + '/element/color.json')).color;
  assert.equal(colors.find((c) => c.name === 'start_window_background').value,
    mode === 'base' ? '#FFF6F3' : '#241C3B');
}
assert.notEqual(read(res + 'base/media/start_brand.svg'), read(res + 'dark/media/start_brand.svg'));
const ability = read('entry/src/main/ets/entryability/EntryAbility.ets');
assert.match(ability, /loadContent\('pages\/Index'/, '直接加载原有首页');
assert.doesNotMatch(ability, /setTimeout|setInterval|Splash|splash|sleep\(/,
  '不能为启动品牌展示增加人为等待或新路由');
console.log('start-window-regression: PASS（启动专用圆角/RGB保持/桌面原图保留/深浅字标/无延时）');
