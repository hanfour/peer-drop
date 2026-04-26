#!/usr/bin/env node
// Import the "Tiny Cat Sprite" by Segel (CC0, OpenGameArt) into the
// prototype's cat-v1.json + palettes.json schema.
//
// Source:
//   https://opengameart.org/content/tiny-kitten-game-sprite
//   License: CC0 1.0 Universal (Public Domain)
//   Author:  Segel
//
// The source is a high-resolution (489×461) anti-aliased grayscale chibi
// cat with idle/run/jump/hurt/dead animations as individual PNG frames in
// `tiny-cat-source/`. We:
//
//   1. Bilinearly downscale each PNG to 32×32. Bilinear preserves the
//      head/body silhouette better than nearest-neighbour at this ratio
//      (~15× shrink); we then quantize colours to recover hard pixel
//      edges.
//   2. Quantize every pixel's RGB to the nearest of a small fixed palette
//      (transparent / outline / dark / mid / light / cheek / muzzle).
//   3. Map (palette index) → integer per the cat-v1.json schema and emit
//      4 idle / 4 walking / 2 happy / 2 tapReact / 2 scared frames.
//
// Re-run with `node scripts/import-sprite.mjs` whenever you want to
// re-derive the JSON. The output is committed.

import fs from 'fs';
import path from 'path';
import { fileURLToPath } from 'url';
import sharp from 'sharp';

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const SRC_ROOT = path.join(__dirname, 'tiny-cat-source');
const OUT_DIR = path.resolve(__dirname, '../public/data');
const SIZE = 32;

// Quantization palette. Indices match palettes.json's "default" entry.
//
//   0 = transparent (alpha < THRESHOLD or near-pure background white)
//   1 = outline   — black ink (sprite is line-heavy)
//   2 = body fur  — mid grey, fills most of the head/body
//   3 = light fur — pale grey, used as belly/cheek
//   4 = white     — eye/inner-ear highlights
//   5 = eye dark  — almost-black pupils (kept distinct from outline so
//                   palette swaps can recolour eyes independently)
//   6 = body shade— darker than (2), used for soft body shading
//   7 = blush     — pink (carried from previous palette so existing
//                   per-trait swaps still resolve)
//
// We also keep the schema 8-slot wide so the existing "all" palette
// variants (curious blue cat, mischievous yellow cat, etc.) still resolve
// in the new sprite without rewiring the renderer.
const PALETTE_RGB = {
  1: [26, 26, 26], // outline (near-black)
  2: [128, 128, 128], // mid grey body
  3: [200, 200, 200], // light grey (belly/cheek)
  4: [245, 245, 245], // near-white
  5: [50, 50, 50], // pupil dark
  6: [88, 88, 88], // body shade
  7: [255, 143, 170], // blush (kept for compatibility)
};

const PALETTE_HEX = {
  0: 'transparent',
  1: '#1A1A1A',
  2: '#808080',
  3: '#C8C8C8',
  4: '#F5F5F5',
  5: '#323232',
  6: '#585858',
  7: '#FF8FAA',
};

// Background of source PNGs is solid white (R=G=B=255) on alpha=255.
// Anything within this distance of pure white we treat as transparent so
// the cat sits cleanly on our painted stage backdrop.
const WHITE_BG_THRESHOLD = 12; // RGB channel-distance
const ALPHA_THRESHOLD = 64;

function rgbDistance(r1, g1, b1, r2, g2, b2) {
  const dr = r1 - r2;
  const dg = g1 - g2;
  const db = b1 - b2;
  return dr * dr + dg * dg + db * db;
}

function quantizePixel(r, g, b, a) {
  if (a < ALPHA_THRESHOLD) return 0;
  // White background → transparent (lets us drop the painted backdrop).
  if (r > 255 - WHITE_BG_THRESHOLD && g > 255 - WHITE_BG_THRESHOLD && b > 255 - WHITE_BG_THRESHOLD) {
    return 0;
  }
  let bestIdx = 1;
  let bestD = Infinity;
  for (const [idxStr, [pr, pg, pb]] of Object.entries(PALETTE_RGB)) {
    const d = rgbDistance(r, g, b, pr, pg, pb);
    if (d < bestD) {
      bestD = d;
      bestIdx = parseInt(idxStr, 10);
    }
  }
  return bestIdx;
}

/** Load a PNG, downscale to SIZE × SIZE, return a SIZE×SIZE 2-D palette
 *  index array. Centres the cat horizontally + sits its feet near
 *  groundY=29 by trimming the source whitespace before resizing. */
async function loadFrame(pngPath) {
  // 1. Read alpha-aware raw RGBA from source.
  const meta = await sharp(pngPath).metadata();
  const srcW = meta.width;
  const srcH = meta.height;
  const { data: srcBuf } = await sharp(pngPath)
    .ensureAlpha()
    .raw()
    .toBuffer({ resolveWithObject: true });

  // 2. Find the tight bounding box of non-background pixels in the source
  //    so we can ignore the empty right/bottom margins (the source frames
  //    are 489×461 with the cat occupying only a ~250×400 region in the
  //    top-left).
  let minX = srcW;
  let minY = srcH;
  let maxX = -1;
  let maxY = -1;
  for (let y = 0; y < srcH; y++) {
    for (let x = 0; x < srcW; x++) {
      const i = (y * srcW + x) * 4;
      const r = srcBuf[i];
      const g = srcBuf[i + 1];
      const b = srcBuf[i + 2];
      const a = srcBuf[i + 3];
      const isBg =
        a < ALPHA_THRESHOLD ||
        (r > 255 - WHITE_BG_THRESHOLD && g > 255 - WHITE_BG_THRESHOLD && b > 255 - WHITE_BG_THRESHOLD);
      if (!isBg) {
        if (x < minX) minX = x;
        if (y < minY) minY = y;
        if (x > maxX) maxX = x;
        if (y > maxY) maxY = y;
      }
    }
  }
  if (maxX < 0) {
    // Empty frame — return all transparent.
    return Array.from({ length: SIZE }, () => Array(SIZE).fill(0));
  }
  const bbW = maxX - minX + 1;
  const bbH = maxY - minY + 1;

  // 3. Resize the bbox region into a target rectangle that fits within
  //    SIZE×SIZE while preserving aspect ratio. Anchor the result so the
  //    cat's *feet* are aligned to row groundY=29 (matches existing schema
  //    meta.groundY) and the cat is horizontally centred.
  const targetH = Math.min(SIZE - 1, Math.round((bbH / Math.max(bbW, bbH)) * (SIZE - 2)));
  const targetW = Math.min(SIZE, Math.round((bbW / bbH) * targetH));

  const resized = await sharp(pngPath)
    .extract({ left: minX, top: minY, width: bbW, height: bbH })
    .resize(targetW, targetH, {
      kernel: 'lanczos3',
      fit: 'fill',
    })
    .ensureAlpha()
    .raw()
    .toBuffer();

  // 4. Quantize and place into a SIZE×SIZE grid centred horizontally,
  //    feet at groundY=29.
  const grid = Array.from({ length: SIZE }, () => Array(SIZE).fill(0));
  const offsetX = Math.floor((SIZE - targetW) / 2);
  const groundY = 29;
  const offsetY = Math.max(0, groundY - targetH + 1);

  for (let ry = 0; ry < targetH; ry++) {
    for (let rx = 0; rx < targetW; rx++) {
      const i = (ry * targetW + rx) * 4;
      const r = resized[i];
      const g = resized[i + 1];
      const b = resized[i + 2];
      const a = resized[i + 3];
      const idx = quantizePixel(r, g, b, a);
      const dx = offsetX + rx;
      const dy = offsetY + ry;
      if (dx >= 0 && dx < SIZE && dy >= 0 && dy < SIZE) {
        grid[dy][dx] = idx;
      }
    }
  }

  return grid;
}

/** Load multiple source frames and return [Frame, Frame, ...]. */
async function loadFrames(relPaths) {
  const frames = [];
  for (const rel of relPaths) {
    const full = path.join(SRC_ROOT, rel);
    const grid = await loadFrame(full);
    frames.push(grid);
  }
  return frames;
}

// Frame selection — we have far more source frames than our schema needs,
// so we sample evenly across each animation to retain motion variety.
//
// Categories we must produce (per cat-v1.json):
//   idle:       4 frames
//   walking:    4 frames
//   happy:      2 frames
//   tapReact:   2 frames
//   scared:     2 frames
//
// Notes on substitution:
//   - "happy" maps to the JumpUp animation — the upward bounce reads as
//     enthusiasm in our scenes.
//   - "tapReact" reuses the squinty-eye Hurt frames at the start of the
//     reaction (eyes squeezed shut = surprised poke).
//   - "scared" uses later JumpFall frames (cat in mid-air recoil pose).
//     The Dead frames were too dramatic for a peer-discovery context.
const FRAME_PLAN = {
  idle: [
    '01_Idle/__Cat_Idle_000.png',
    '01_Idle/__Cat_Idle_003.png',
    '01_Idle/__Cat_Idle_006.png',
    '01_Idle/__Cat_Idle_009.png',
  ],
  walking: [
    '02_Run/__Cat_Run_000.png',
    '02_Run/__Cat_Run_002.png',
    '02_Run/__Cat_Run_005.png',
    '02_Run/__Cat_Run_007.png',
  ],
  happy: [
    '03_Jump/01_Up/__Cat_JumpUp_001.png',
    '03_Jump/01_Up/__Cat_JumpUp_003.png',
  ],
  tapReact: [
    '04_Hurt/__Cat_Hurt_001.png',
    '04_Hurt/__Cat_Hurt_003.png',
  ],
  scared: [
    '03_Jump/02_Fall/__Cat_JumpFall_000.png',
    '03_Jump/02_Fall/__Cat_JumpFall_002.png',
  ],
};

(async () => {
  console.log('Importing Tiny Cat Sprite (Segel, CC0) → cat-v1.json…');

  const baby = {};
  for (const [action, frameList] of Object.entries(FRAME_PLAN)) {
    process.stdout.write(`  ${action} (${frameList.length} frames)…`);
    baby[action] = await loadFrames(frameList);
    process.stdout.write(' done\n');
  }

  const json = {
    version: 'v1',
    size: SIZE,
    meta: { groundY: 29, eyeAnchor: { x: 16, y: 13 } },
    _credit: {
      asset: 'Tiny Cat Sprite',
      author: 'Segel',
      source: 'https://opengameart.org/content/tiny-kitten-game-sprite',
      license: 'CC0 1.0 Universal (Public Domain)',
      note:
        'Imported via scripts/import-sprite.mjs from raw PNG frames. Downscaled from 489×461 to 32×32, quantised to 7-colour grayscale palette + blush accent. tapReact uses Hurt frames; scared uses JumpFall frames; happy uses JumpUp frames (substitutions documented in import-sprite.mjs).',
    },
    // Inline palette: this sprite is grayscale-quantised at import time, so
    // the renderer should prefer THIS palette over palettes.json's
    // chromatic-orange default (which exists for the v0 sprite). App.tsx
    // checks `data.palette` first and falls back to the file's default.
    palette: PALETTE_HEX,
    baby,
  };

  fs.mkdirSync(OUT_DIR, { recursive: true });
  fs.writeFileSync(path.join(OUT_DIR, 'cat-v1.json'), JSON.stringify(json) + '\n');

  // We do NOT touch palettes.json. The v0 sprite needs its existing
  // chromatic palette (warm orange + cream) to look right, and the v1
  // sprite carries its own palette inline (see `palette` field above).

  console.log('\nWrote:');
  console.log(`  ${path.relative(process.cwd(), path.join(OUT_DIR, 'cat-v1.json'))}`);
  console.log('  (palettes.json untouched — v1 palette embedded in cat-v1.json)');
  console.log('\nLicense: CC0 — credit field embedded in cat-v1.json._credit.');
})();
