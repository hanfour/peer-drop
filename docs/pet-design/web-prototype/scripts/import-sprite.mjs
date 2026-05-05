#!/usr/bin/env node
// Import the side-view "Cat sprites" by Shepardskin (CC0, OpenGameArt) into
// the prototype's cat-v1.json schema.
//
// Source:
//   https://opengameart.org/content/cat-sprites
//   License: CC0 1.0 Universal (Public Domain Dedication)
//   Author:  Shepardskin
//
// Why this asset (vs. the previous "Tiny Kitten" by Segel):
//   The earlier front-facing chibi could not communicate locomotion. Our hero
//   interaction is "peer's pet walks IN from the screen edge", which only
//   reads as motion when the sprite is in profile. Shepardskin's sheet is a
//   tiny side-view pixel cat with three loops — sit/idle (5 frames), walk
//   (6 frames), and run (6 frames) — all facing right, on a single 137×50
//   sheet. That gives us locomotion-correct walking and still preserves a
//   cute green-eyed silhouette.
//
// Layout of the source sheet (catspritesoriginal.gif, 137×50):
//
//     Row 1 y=[0,14]  → 5 idle/sitting frames (head turns, tail flicks)
//     Row 2 y=[17,31] → 6 walking-cycle frames
//     Row 3 y=[34,49] → 6 running-cycle frames
//
//   The sheet has 5 unique colours total:
//     - lavender background (164,117,160)
//     - dark body grey      ( 56, 56, 56)
//     - near-black outline  ( 28, 28, 28)
//     - green eyes          ( 95,160, 48)
//     - magenta cheek/eye accent (143, 52,160)
//
//   We treat the lavender as transparent and quantise the rest into our
//   32×32 schema (oversized vs. the 16-tall source, so the cat sits in the
//   bottom half of the canvas with feet on groundY=29).
//
//   The source cat faces LEFT in every frame (eye on the left, tail on the
//   right). The renderer's convention is base sprite faces RIGHT so:
//     - local pet (left of stage)  uses flipped:false → looks right at peer
//     - peer  pet (right of stage) uses flipped:true  → mirrors to look left
//   We therefore mirror every frame horizontally during import so the on-disk
//   JSON contains right-facing frames. The renderer is unchanged.
//
// Frame substitutions (we have fewer schema slots than source frames):
//   idle      ← row 1 frames 0,1,2,3 (sit + small head turns)
//   walking   ← row 2 frames 0,2,3,5 (evenly spaced across walk loop)
//   happy     ← row 2 frames 1,4 (mid-step "lifted" poses read as bouncy)
//   tapReact  ← row 1 frame 3 + row 3 frame 0 (cat head-turn + recoil pose)
//   scared    ← row 3 frames 4,5 (running away — recoil silhouette)
//
// Re-run with `node scripts/import-sprite.mjs` to re-derive the JSON. The
// output is committed.

import fs from 'fs';
import path from 'path';
import { fileURLToPath } from 'url';
import sharp from 'sharp';

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const SRC_PATH = path.join(__dirname, 'side-cat-source', 'catspritesoriginal.gif');
const OUT_DIR = path.resolve(__dirname, '../public/data');
const SIZE = 32;
const GROUND_Y = 29;

// Frame layout on the source sheet — derived from automated background
// detection (see commit message for the detection script). Order: rows
// top-to-bottom, frames left-to-right within each row.
const SHEET_FRAMES = {
  idle: [
    // Row 1 (y=[0,14])
    { x: 0, y: 0, w: 19, h: 15 },
    { x: 21, y: 0, w: 19, h: 15 },
    { x: 42, y: 0, w: 19, h: 15 },
    { x: 63, y: 0, w: 16, h: 15 },
    { x: 82, y: 0, w: 20, h: 15 },
  ],
  walking: [
    // Row 2 (y=[17,31])
    { x: 2, y: 17, w: 18, h: 15 },
    { x: 24, y: 17, w: 18, h: 15 },
    { x: 46, y: 17, w: 17, h: 15 },
    { x: 68, y: 17, w: 17, h: 15 },
    { x: 89, y: 17, w: 17, h: 15 },
    { x: 111, y: 17, w: 17, h: 15 },
  ],
  running: [
    // Row 3 (y=[34,49])
    { x: 3, y: 34, w: 19, h: 16 },
    { x: 25, y: 34, w: 19, h: 16 },
    { x: 48, y: 34, w: 20, h: 16 },
    { x: 70, y: 34, w: 20, h: 16 },
    { x: 93, y: 34, w: 20, h: 16 },
    { x: 117, y: 34, w: 20, h: 16 },
  ],
};

// Palette layout — 8 slots wide so existing rendering code (which keys off
// integer indices 0–7) keeps working. Indices 3, 4, 6 are unused by this
// asset but kept so the schema stays stable.
//
//   0 = transparent
//   1 = outline / near-black detail
//   2 = body grey (the dominant cat colour)
//   3 = (unused, light slot — kept for schema parity)
//   4 = (unused, white slot — kept for schema parity)
//   5 = eye green
//   6 = (unused, mid-shade slot — kept for schema parity)
//   7 = magenta accent (eye/cheek highlights in source)
const PALETTE_HEX = {
  0: 'transparent',
  1: '#1C1C1C',
  2: '#383838',
  3: '#5A5A5A',
  4: '#F5F5F5',
  5: '#5FA030',
  6: '#2A2A2A',
  7: '#8F34A0',
};

// Source colour → palette-index lookup. The source has 5 distinct colours
// (plus the lavender background which we drop), so we hard-code the mapping
// rather than running a nearest-colour quantiser (which would be brittle
// when the source changes by even a single channel).
const SOURCE_COLOR_TO_INDEX = new Map([
  ['164,117,160', 0], // lavender background → transparent
  ['56,56,56', 2], // body grey
  ['28,28,28', 1], // outline / near-black
  ['95,160,48', 5], // eye green
  ['143,52,160', 7], // magenta accent
]);

function rgbKey(r, g, b) {
  return `${r},${g},${b}`;
}

/** Slice a single frame out of the source sheet at (x,y,w,h), then place it
 *  into a SIZE×SIZE palette-index grid. The frame is centred horizontally
 *  and anchored so the bottom row of the slice sits on groundY (matches the
 *  schema's feet-on-ground convention). The slice is also mirrored
 *  horizontally on the way in — see header comment for why. */
async function extractFrame(sheetBuf, sheetW, sheetH, slice) {
  const grid = Array.from({ length: SIZE }, () => Array(SIZE).fill(0));
  const offsetX = Math.floor((SIZE - slice.w) / 2);
  // Anchor so the LAST row of the slice lands on groundY.
  const offsetY = GROUND_Y - slice.h + 1;

  for (let sy = 0; sy < slice.h; sy++) {
    for (let sx = 0; sx < slice.w; sx++) {
      const srcX = slice.x + sx;
      const srcY = slice.y + sy;
      if (srcX < 0 || srcX >= sheetW || srcY < 0 || srcY >= sheetH) continue;
      const i = (srcY * sheetW + srcX) * 4;
      const r = sheetBuf[i];
      const g = sheetBuf[i + 1];
      const b = sheetBuf[i + 2];
      const a = sheetBuf[i + 3];
      if (a < 8) continue;
      const idx = SOURCE_COLOR_TO_INDEX.get(rgbKey(r, g, b));
      if (idx === undefined) {
        // Unknown colour — leave transparent. Logged so a future asset
        // change is noisy rather than silently mis-quantised.
        if (!extractFrame._warned) {
          extractFrame._warned = new Set();
        }
        const k = rgbKey(r, g, b);
        if (!extractFrame._warned.has(k)) {
          extractFrame._warned.add(k);
          process.stderr.write(`  warn: unmapped source colour ${k} (treated as transparent)\n`);
        }
        continue;
      }
      if (idx === 0) continue;
      // Mirror horizontally: source faces left, schema wants right-facing.
      const mirroredSx = slice.w - 1 - sx;
      const dx = offsetX + mirroredSx;
      const dy = offsetY + sy;
      if (dx >= 0 && dx < SIZE && dy >= 0 && dy < SIZE) {
        grid[dy][dx] = idx;
      }
    }
  }

  return grid;
}

/** Read the source sheet once, then extract every requested slice. */
async function loadAllFrames() {
  const meta = await sharp(SRC_PATH).metadata();
  const { data } = await sharp(SRC_PATH)
    .ensureAlpha()
    .raw()
    .toBuffer({ resolveWithObject: true });
  const w = meta.width;
  const h = meta.height;

  const out = {};
  for (const [row, slices] of Object.entries(SHEET_FRAMES)) {
    out[row] = [];
    for (const slice of slices) {
      out[row].push(await extractFrame(data, w, h, slice));
    }
  }
  return out;
}

/** Map source rows → schema actions. We have:
 *    idle:    4 frames sampled across row 1
 *    walking: 4 frames sampled across row 2 (full walk cycle)
 *    happy:   2 mid-step poses from row 2 (lifted-paw bounce read as joy)
 *    tapReact:2 frames — head-turn idle + first running pose (recoil)
 *    scared:  2 frames from the tail end of row 3 (fleeing pose)
 */
function buildAnimationSet(rows) {
  return {
    idle: [rows.idle[0], rows.idle[1], rows.idle[2], rows.idle[3]],
    walking: [rows.walking[0], rows.walking[2], rows.walking[3], rows.walking[5]],
    happy: [rows.walking[1], rows.walking[4]],
    tapReact: [rows.idle[3], rows.running[0]],
    scared: [rows.running[4], rows.running[5]],
  };
}

(async () => {
  console.log('Importing Shepardskin "Cat sprites" (CC0) → cat-v1.json…');

  const rows = await loadAllFrames();
  process.stdout.write(
    `  rows: idle=${rows.idle.length} walking=${rows.walking.length} running=${rows.running.length}\n`,
  );

  const baby = buildAnimationSet(rows);
  for (const [action, frames] of Object.entries(baby)) {
    process.stdout.write(`  ${action}: ${frames.length} frames\n`);
  }

  const json = {
    version: 'v1',
    size: SIZE,
    meta: { groundY: GROUND_Y, eyeAnchor: { x: 16, y: 22 } },
    _credit: {
      asset: 'Cat sprites',
      author: 'Shepardskin',
      source: 'https://opengameart.org/content/cat-sprites',
      license: 'CC0 1.0 Universal (Public Domain)',
      note:
        'Side-view pixel-art cat — 137×50 sprite sheet with sit/idle, walk, and run rows. Imported via scripts/import-sprite.mjs and placed on a 32×32 canvas with feet anchored to groundY=29. The cat faces right in source; the renderer mirrors the peer pet via SpriteCanvas `flipped` so the two pets face each other on stage. Frame substitutions: happy ← mid-step walk poses (lifted-paw bounce reads as joy); tapReact ← idle head-turn + first running frame (recoil); scared ← end of run cycle (fleeing). See scripts/import-sprite.mjs for exact source-frame mapping.',
    },
    // Inline palette — overrides palettes.json for v1 only. The v0 sprite
    // (cat.json, 16×16) keeps its chromatic-orange palette unchanged so the
    // v0/v1 toggle in App.tsx still flips between two distinct looks.
    palette: PALETTE_HEX,
    baby,
  };

  fs.mkdirSync(OUT_DIR, { recursive: true });
  fs.writeFileSync(path.join(OUT_DIR, 'cat-v1.json'), JSON.stringify(json) + '\n');

  console.log('\nWrote:');
  console.log(`  ${path.relative(process.cwd(), path.join(OUT_DIR, 'cat-v1.json'))}`);
  console.log('  (palettes.json untouched — v1 palette embedded in cat-v1.json)');
  console.log('\nLicense: CC0 — credit field embedded in cat-v1.json._credit.');
})();
