/** Read-only PNG alpha/consumer checks; visual identity remains a human acceptance criterion. */
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import { inflateSync } from 'node:zlib';
const root = path.resolve(import.meta.dirname, '../..');
const read = file => fs.readFileSync(path.join(root, file), 'utf8');
const historic = 'docs/prototype/assets/legacy-app-assets-2026-10-17/';
// Reuse the independent PNG reader from the existing startup asset regression, without executing its tests.
const startup = read('tools/test/start-window-regression.mjs');
const reader = startup.slice(startup.indexOf('function rgbaPng(file) {'), startup.indexOf('\nconst original = rgbaPng('));
const rgbaPng = new Function('fs', 'path', 'repo', 'assert', 'inflateSync', reader + '\nreturn rgbaPng;')(
  fs, path, root, assert, inflateSync);
for (const name of ['bubu_peek', 'xiuxiu_peek', 'xiuxiu_sleep']) {
  const png = rgbaPng(`entry/src/main/resources/base/media/${name}.png`);
  let transparent = 0, solid = 0, soft = 0;
  for (let i = 3; i < png.pixels.length; i += 4) {
    const alpha = png.pixels[i];
    // The image provider emits interior alpha 253/254; 98%+ is visually solid, not a glow.
    if (alpha <= 5) transparent++; else if (alpha >= 250) solid++; else soft++;
  }
  const count = png.width * png.height;
  assert.ok(transparent / count > .15, 'actual alpha, not a painted background');
  assert.ok(solid / count > .25, 'character is not a faint translucent ghost');
  assert.ok(soft / count < .05, 'no broad translucent exterior glow');
  for (const [x, y] of [[0, 0], [png.width - 1, 0], [0, png.height - 1], [png.width - 1, png.height - 1]]) {
    assert.equal(png.pixels[(y * png.width + x) * 4 + 3], 0, 'corners must be transparent');
  }
  console.log(`companion alpha ${name}: ${png.width}x${png.height}, soft ${(100 * soft / count).toFixed(2)}%`);
}
for (const role of ['bubu', 'xiuxiu']) {
  let plateSize;
  for (const layer of ['plate', 'head']) {
    const png = rgbaPng((layer === 'head' ? historic : 'entry/src/main/resources/base/media/') + `companions_${role}_${layer}.png`);
    if (layer === 'plate') plateSize = [png.width, png.height];
    else assert.deepEqual([png.width, png.height], plateSize, 'head edits preserve exact plate canvas dimensions');
    assert.ok(png.width > 0 && png.height > 0);
    for (const [x, y] of [[0, 0], [png.width - 1, 0], [0, png.height - 1], [png.width - 1, png.height - 1]]) {
      assert.equal(png.pixels[(y * png.width + x) * 4 + 3], 0);
    }
  }
  const faces = [];
  for (let face = 0; face < 4; face++) {
    const svg = read((face === 1 || face === 2 ? historic : 'entry/src/main/resources/base/media/') + `companions_${role}_face_${face}.svg`);
    assert.match(svg, /viewBox="0 0 120 120"/);
    assert.doesNotMatch(svg, /<rect\b|<image\b|<script\b|<text\b|href=|currentColor|<animate/);
    faces.push(svg);
  }
  assert.equal(new Set(faces).size, 4, 'four genuinely different expressions');
}
for (const [file, name] of [['ConfirmDialog', 'bubu_peek'], ['WindowDetailSheet', 'xiuxiu_peek'], ['StatePanel', 'xiuxiu_sleep']]) {
  const source = read(`entry/src/main/ets/component/${file}.ets`);
  assert.match(source, new RegExp(`Image\\(\\$r\\('app.media.${name}'\\)\\)`));
  assert.match(source, /objectFit\(ImageFit\.Contain\)/);
  assert.doesNotMatch(source, /app\.media\.mascot_(peek|bunny_sleep)/, 'old crude art no longer consumed');
}
// Measure the visible paw edge, not the transparent image box, against the native summary top.
const sheet = read('entry/src/main/ets/component/WindowDetailSheet.ets');
const value = name => {
  const match = sheet.match(new RegExp(`const ${name}: number = ([0-9.]+);`));
  assert.ok(match, name + ' stays measurable'); return Number(match[1]);
};
const peek = rgbaPng('entry/src/main/resources/base/media/xiuxiu_peek.png');
let visibleTop = peek.height, visibleBottom = 0;
for (let y = 0; y < peek.height; y++) for (let x = 0; x < peek.width; x++) {
  if (peek.pixels[(y * peek.width + x) * 4 + 3] >= 200) {
    visibleTop = Math.min(visibleTop, y); visibleBottom = Math.max(visibleBottom, y + 1);
  }
}
const h = value('PEEK_H'), w = value('PEEK_W'), out = h - value('PEEK_IN');
const fit = Math.min(w / peek.width, h / peek.height), pad = (h - peek.height * fit) / 2;
assert.match(sheet, /\.margin\(\{ top: 10, bottom: 12 \}\)/, 'handle geometry used by contact check');
assert.match(sheet, /\.width\(44\)\.height\(5\)/);
const summaryTop = 10 + 5 + 12;
const overlap = -out + value('PEEK_CARD_DROP') + pad + visibleBottom * fit - summaryTop;
assert.ok(overlap >= 2 && overlap <= 5, `visible paws should rest 2–5vp on the card, got ${overlap}`);
assert.ok(value('PEEK_CARD_DROP') + pad + visibleTop * fit > 0, 'ears stay inside the reserved sheet window');
console.log(`companion paw/card contact: ${overlap.toFixed(2)}vp overlap (asset/layout math, not device pixels)`);
console.log('companion-assets-regression: PASS (PNG alpha + native consumers, not device rendering)');
