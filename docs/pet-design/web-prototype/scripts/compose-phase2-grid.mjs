#!/usr/bin/env node
// Compose a 5×3 grid (5 species × 3 lifecycle stages = 15 cells) of
// previously-captured viewport PNGs into a single PR-comment image.
// Crops the 480×240 stage rectangle out of each viewport and tiles them
// onto a labelled backdrop.
//
// Run from the web-prototype dir AFTER capturing
//   grid-{cat,dog,bird,bear,octopus}-{baby,adult,elder}.png
// at the repo root via Playwright.
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import sharp from 'sharp';

const __dirname = path.dirname(fileURLToPath(import.meta.url));
// scripts/ is at <repo>/docs/pet-design/web-prototype/scripts/
const REPO = path.resolve(__dirname, '../../../..');
const OUT = path.join(REPO, 'phase2-grid-5x3.png');

const ROWS = [
  { species: 'cat', label: '貓 / Cat' },
  { species: 'dog', label: '狗 / Dog' },
  { species: 'bird', label: '鳥 / Bird' },
  { species: 'bear', label: '熊 / Bear' },
  { species: 'octopus', label: '章魚 / Octopus' },
];
const COLS = [
  { stage: 'baby', label: '幼體' },
  { stage: 'adult', label: '成熟體' },
  { stage: 'elder', label: '老年體' },
];

// Crop: stage is 480×240 on the captured viewport PNGs. Y position
// varies for cells where the picker block is taller (bird's adult sub-
// variant 公雞/母雞 row adds ~40px). We override Y per-key.
const CROP_X = 114;
const CROP_Y_DEFAULT = 476;
const CROP_Y_BY_KEY = {
  'bird-adult': 516,
};
const STAGE_W = 480;
const STAGE_H = 240;
// Display cell size:
const CELL_W = 360;
const CELL_H = 180;
const LABEL_H = 28;
const GAP = 8;
const PAD = 16;
const HEADER_H = 36;
const ROW_LABEL_W = 100;

const totalW = PAD * 2 + ROW_LABEL_W + COLS.length * CELL_W + (COLS.length - 1) * GAP;
const totalH =
  PAD * 2 + HEADER_H + ROWS.length * (CELL_H + LABEL_H) + (ROWS.length - 1) * GAP;

async function main() {
  const labelSvg = `
<svg xmlns="http://www.w3.org/2000/svg" width="${totalW}" height="${totalH}">
  <rect width="100%" height="100%" fill="#FAFAFB"/>
  <style>
    .h { font: 600 14px -apple-system, BlinkMacSystemFont, "Helvetica Neue", sans-serif; fill: #333; }
    .s { font: 500 13px -apple-system, BlinkMacSystemFont, "Helvetica Neue", sans-serif; fill: #555; }
  </style>
  <text x="${PAD}" y="${PAD + 18}" class="h">PeerDrop Pet · 多階段生命週期 (5 物種 × 3 階段)</text>
  ${COLS.map((c, ci) => {
    const cx = PAD + ROW_LABEL_W + ci * (CELL_W + GAP) + CELL_W / 2;
    return `<text x="${cx}" y="${PAD + HEADER_H + 18}" text-anchor="middle" class="s">${c.label}</text>`;
  }).join('\n  ')}
  ${ROWS.map((r, ri) => {
    const ry = PAD + HEADER_H + LABEL_H + ri * (CELL_H + LABEL_H + GAP) + CELL_H / 2 + 6;
    return `<text x="${PAD + 4}" y="${ry}" class="s">${r.label}</text>`;
  }).join('\n  ')}
</svg>
  `.trim();

  const canvas = sharp(Buffer.from(labelSvg));
  const overlays = [];
  for (let ri = 0; ri < ROWS.length; ri++) {
    for (let ci = 0; ci < COLS.length; ci++) {
      const file = path.join(REPO, `grid-${ROWS[ri].species}-${COLS[ci].stage}.png`);
      if (!fs.existsSync(file)) {
        console.warn(`(missing) ${file}`);
        continue;
      }
      const key = `${ROWS[ri].species}-${COLS[ci].stage}`;
      const cropY = CROP_Y_BY_KEY[key] ?? CROP_Y_DEFAULT;
      const cropped = await sharp(file)
        .extract({ left: CROP_X, top: cropY, width: STAGE_W, height: STAGE_H })
        .resize(CELL_W, CELL_H, { fit: 'fill' })
        .toBuffer();
      const x = PAD + ROW_LABEL_W + ci * (CELL_W + GAP);
      const y = PAD + HEADER_H + LABEL_H + ri * (CELL_H + LABEL_H + GAP);
      overlays.push({ input: cropped, left: x, top: y });
    }
  }

  const buf = await canvas.composite(overlays).png().toBuffer();
  fs.writeFileSync(OUT, buf);
  console.log(`wrote ${OUT}  (${totalW}×${totalH})`);
}

main().catch((e) => {
  console.error(e);
  process.exit(1);
});
