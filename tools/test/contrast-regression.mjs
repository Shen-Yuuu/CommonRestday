/** 给浅色文字阶梯的 C3 审计喂一份旧色令牌副本，证明回潮会被拦下。 */
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { auditTextPalette } from './contrast-audit.mjs';

const HERE = path.dirname(fileURLToPath(import.meta.url));
const REPO = path.resolve(HERE, '../..');
const temp = fs.mkdtempSync(path.join(os.tmpdir(), 'crd-contrast-'));
try {
  for (const tier of ['base', 'dark']) {
    const rel = `entry/src/main/resources/${tier}/element/color.json`;
    const dest = path.join(temp, rel);
    fs.mkdirSync(path.dirname(dest), { recursive: true });
    const palette = JSON.parse(fs.readFileSync(path.join(REPO, rel), 'utf8'));
    if (tier === 'base') {
      const secondary = palette.color.find((item) => item.name === 'text_secondary');
      if (secondary === undefined) {
        throw new Error('base palette lacks text_secondary');
      }
      secondary.value = '#8F7A82'; // 故意回填旧值：浅填充上约 3.55:1
    }
    fs.writeFileSync(dest, JSON.stringify(palette));
  }
  const cycleRel = 'entry/src/main/ets/pages/CycleEditor.ets';
  const cycleDest = path.join(temp, cycleRel);
  fs.mkdirSync(path.dirname(cycleDest), { recursive: true });
  fs.copyFileSync(path.join(REPO, cycleRel), cycleDest);
  const findings = auditTextPalette(temp);
  if (!findings.some((f) => f.includes('text_secondary') && f.includes('小字信息墨'))) {
    throw new Error('old text_secondary was not rejected');
  }
  console.log('contrast-regression: PASS（旧 text_secondary 被 C3 拦下）');
} finally {
  // temp 是本脚本刚由 mkdtempSync 创建的专属路径，不接受仓库路径或用户输入。
  fs.rmSync(temp, { recursive: true, force: true });
}
