#!/usr/bin/env node
// Paint a 32x32 chibi-style CAT sprite as JSON.
//
// Design brief (v2 — ProHama alignment):
//   The previous iterations (v1.0, v1.1, v1.2) read as a fluffy generic
//   chibi but were a long way from ProHama's iconic style. After actually
//   studying ProHama cat patterns 5/7/9/11/12/13/15/19, the family
//   signature is:
//
//   - Eyes: SOLID BLACK 2×2 squares. No white highlight. No almond. No
//     pupil rim. Two flat black dots, separated by a meaningful gap of
//     forehead. (ref: cat-11, cat-12)
//   - Ears: TALL POINTY triangles, 5–6 rows tall, each ear with a light
//     inner highlight (lighter shade or pink). The ears define the
//     silhouette. (ref: cat-11, cat-12)
//   - Body: An egg/teardrop with a NARROW upper third (head) and a
//     wider lower third (body). The bottom is BROKEN by two discrete
//     front paws — separated by a gap of background. (ref: cat-11)
//   - Tail: A visible curl looping up from the side. (ref: cat-11, cat-12)
//   - Mouth: Tiny inverted V at most 2px wide. No separate nose. The
//     pink blob at center is a single pixel of accent at most.
//   - Cheeks: Tiny pink blush dots OFF to the sides — never the central
//     pink rectangle that dominated v1.
//   - Color palette: 5 colors. Outline (warm black-brown), primary fur
//     (saturated orange), secondary cream (belly + inner ears), pink
//     blush, mouth/nose accent (same pink works).
//   - NO whiskers. NO tabby stripes. NO white eye highlight.
//
// Implementation: each frame is encoded as a 32×32 ASCII grid using the
// character map below. This makes the sprite directly inspectable from
// the source — no arithmetic to mentally simulate.

import fs from 'fs';
import path from 'path';
import { fileURLToPath } from 'url';

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const outDir = path.resolve(__dirname, '../public/data');

const SIZE = 32;

// Character → palette index map for the ASCII grids.
//   . transparent
//   X outline (warm dark brown)
//   O primary body (orange)
//   c secondary cream (belly + inner ears)
//   B black eye dot (uses palette index 5 — repurposed from v1 pupil)
//   R blush pink (cheeks, mouth)
const CHAR_MAP = {
  '.': 0,
  X: 1,
  O: 2,
  c: 3,
  B: 5,
  R: 7,
};

/** Convert a 32-line string array into a 2D number array.
 *  Each line MUST be exactly 32 characters. */
function gridFromAscii(lines) {
  if (lines.length !== SIZE) {
    throw new Error(`grid must have ${SIZE} rows, got ${lines.length}`);
  }
  return lines.map((line, y) => {
    if (line.length !== SIZE) {
      throw new Error(`row ${y} has ${line.length} chars, want ${SIZE}: "${line}"`);
    }
    return line.split('').map((ch) => {
      const idx = CHAR_MAP[ch];
      if (idx === undefined) {
        throw new Error(`unknown char "${ch}" at row ${y}`);
      }
      return idx;
    });
  });
}

// =====================================================================
// Idle frame 0 — the canonical pose
// =====================================================================
//
// Layout (32x32, 0-indexed; sprite spans cols 6-25 = 20 wide, rows 2-29):
//
//   rows  2-3    ear tips (1px each)
//   rows  4-7    ear bodies (widening triangles, with cream highlight)
//   rows  7-12   head dome (egg-top)
//   rows 11-13   eye row — 2x2 black squares with 4px gap
//   rows 14-15   cheek row — pink blush dots, tiny mouth
//   rows 16-25   body egg (slightly wider than head); cream chest patch
//                rows 16-23
//   rows 24-26   tail curl (right side)
//   rows 26-28   front paws (two separate ovals with gap)
//
// Eye anchors:
//   left  eye cols 11-12 (2 wide, 2 tall: rows 12-13)
//   right eye cols 19-20 (2 wide, 2 tall: rows 12-13)
//   forehead gap = cols 13-18 (6 px) — wider gap reads "ProHama"
//
// Mouth anchor: cols 15-16 row 15 (2px inverted V at row 15-16 cols 15/16)
// Cheek anchors: col 9 row 14, col 22 row 14 (single pink dots)

// Refined v2 layout — ears shortened to 4 rows, chest patch narrower
// vertical-oriented, tail curl larger.
//
// rows 3-7  ears (5 rows including base; tip at row 3)
// rows 7-9  head dome top
// rows 10-16 face (eyes row 12-13, blush row 13, mouth row 15)
// rows 17-24 body (chest patch is a vertical oval cols 13-18 rows 17-23)
// rows 21-25 tail curl (right side, larger sweeping curl)
// rows 25-28 paws + ground
const IDLE_F0 = gridFromAscii([
  /* 0  */ '................................',
  /* 1  */ '................................',
  /* 2  */ '................................',
  /* 3  */ '..........X............X........',
  /* 4  */ '..........XX..........XX........',
  /* 5  */ '..........XcX........XcX........',
  /* 6  */ '..........XccX......XccX........',
  /* 7  */ '..........XOccXXXXXXccOX........',
  /* 8  */ '.........XOOOOOOOOOOOOOOX.......',
  /* 9  */ '.........XOOOOOOOOOOOOOOX.......',
  /* 10 */ '........XOOOOOOOOOOOOOOOOX......',
  /* 11 */ '........XOOOOOOOOOOOOOOOOX......',
  /* 12 */ '........XOOOBBOOOOOOBBOOOX......',
  /* 13 */ '........XOOOBBOOOOOOBBOOOX......',
  /* 14 */ '........XOROOOOOOOOOOOOROX......',
  /* 15 */ '........XOOOOOOOXROXOOOOOX......',
  /* 16 */ '........XOOOOOOOXXOXOOOOOX......',
  /* 17 */ '.......XOOOOOOcccccOOOOOOOX.....',
  /* 18 */ '.......XOOOOOcccccccOOOOOOX.....',
  /* 19 */ '.......XOOOOcccccccccOOOOOX.....',
  /* 20 */ '.......XOOOOcccccccccOOOOOXX....',
  /* 21 */ '.......XOOOOcccccccccOOOOOXOX...',
  /* 22 */ '.......XOOOOcccccccccOOOOOXOOX..',
  /* 23 */ '.......XOOOOOcccccccOOOOOOXOOX..',
  /* 24 */ '.......XOOOOOOOOOOOOOOOOOOXOOX..',
  /* 25 */ '.......XOOOOOOOOOOOOOOOOOOXXOX..',
  /* 26 */ '.......XOOXXXOOOOOOXXXOOOOXXX...',
  /* 27 */ '.......XOOXccXOOOOXccXOOOOX.....',
  /* 28 */ '.......XXXXccXXXXXXccXXXXX......',
  /* 29 */ '..........XXXX....XXXX..........',
  /* 30 */ '................................',
  /* 31 */ '................................',
]);

// =====================================================================
// Variants — derived from IDLE_F0 with small, targeted patches
// =====================================================================

/** Deep-clone a 2D grid. */
function clone(g) {
  return g.map((row) => row.slice());
}

/** Apply pixel patches to a copy of a grid.
 *  patches: array of [x, y, paletteIndex] tuples. */
function patch(base, patches) {
  const g = clone(base);
  for (const [x, y, c] of patches) {
    if (x < 0 || x >= SIZE || y < 0 || y >= SIZE) continue;
    g[y][x] = c;
  }
  return g;
}

/** Translate a grid by (dx, dy), filling vacated pixels with transparent. */
function translate(base, dx, dy) {
  const g = Array.from({ length: SIZE }, () => Array(SIZE).fill(0));
  for (let y = 0; y < SIZE; y++) {
    for (let x = 0; x < SIZE; x++) {
      const sy = y - dy;
      const sx = x - dx;
      if (sy < 0 || sy >= SIZE || sx < 0 || sx >= SIZE) continue;
      g[y][x] = base[sy][sx];
    }
  }
  return g;
}

// Eye coordinates (after iter3 grid shift):
//   left  eye: cols 12-13, rows 12-13 (2×2 black square)
//   right eye: cols 20-21, rows 12-13 (2×2 black square)

// ----- Idle: 4 frames -----
// f0: canonical pose
// f1: subtle breath rise — entire sprite up 1 px
// f2: blink — both eyes become single horizontal black line (2x1 each)
// f3: canonical echo
const BLINK_F = patch(IDLE_F0, [
  // Clear the eyes → restore to fur orange
  [12, 12, 2], [13, 12, 2], [20, 12, 2], [21, 12, 2],
  [12, 13, 2], [13, 13, 2], [20, 13, 2], [21, 13, 2],
  // Single horizontal line at row 13 (closed eye look)
  [12, 13, 5], [13, 13, 5], [20, 13, 5], [21, 13, 5],
]);
const idle = [IDLE_F0, translate(IDLE_F0, 0, -1), BLINK_F, IDLE_F0];

// ----- Walking: 4 frames -----
// We don't articulate the paws between frames — instead we bob the
// whole sprite to suggest a trot. ProHama's chibi cats don't do walk
// cycles either; their style is iconic-static, so a vertical bob
// preserves the look.
const walking = [
  IDLE_F0,
  translate(IDLE_F0, 0, -1),
  IDLE_F0,
  translate(IDLE_F0, 0, 1),
];

// ----- Happy: 2 frames -----
// f0: closed-arc smile eyes (^^), body lifts 1 px
// f1: same with body lifts 2 px (excited bounce)
//
// The closed-arc smile is a 3-px wide ^ shape per eye:
//   row 12: . X .   (tip of arc)
//   row 13: X . X   (legs of arc)
// We use eye anchors cols 12-13 (left) and 20-21 (right) and EXTEND
// by 1 col outward so the arc is 3 wide:
//   left arc cols 11-13: row13 col11, row12 col12, row13 col13
//   right arc cols 20-22: row13 col20, row12 col21, row13 col22
const HAPPY_BASE = patch(IDLE_F0, [
  // Clear the original 2x2 black eyes back to fur
  [12, 12, 2], [13, 12, 2], [20, 12, 2], [21, 12, 2],
  [12, 13, 2], [13, 13, 2], [20, 13, 2], [21, 13, 2],
  // Left ^ smile
  [11, 13, 5], [12, 12, 5], [13, 13, 5],
  // Right ^ smile
  [20, 13, 5], [21, 12, 5], [22, 13, 5],
]);
const happy = [
  translate(HAPPY_BASE, 0, -1),
  translate(HAPPY_BASE, 0, -2),
];

// ----- TapReact: 2 frames -----
// f0: surprised wide black eyes (3x2), body squashed 1 px down
// f1: stretched up 1 px, normal eyes (recovery)
//
// Wide eyes: extend 2x2 by one col toward the centre:
//   left  3x2 at cols 12-14 rows 12-13
//   right 3x2 at cols 19-21 rows 12-13
const TAP_WIDE_EYES = patch(IDLE_F0, [
  // Clear original eyes
  [12, 12, 2], [13, 12, 2], [20, 12, 2], [21, 12, 2],
  [12, 13, 2], [13, 13, 2], [20, 13, 2], [21, 13, 2],
  // 3x2 wide eyes
  [12, 12, 5], [13, 12, 5], [14, 12, 5],
  [12, 13, 5], [13, 13, 5], [14, 13, 5],
  [19, 12, 5], [20, 12, 5], [21, 12, 5],
  [19, 13, 5], [20, 13, 5], [21, 13, 5],
  // Tiny "o" mouth (round 2x2 black) instead of inverted V
  // Mouth was at row 15-16 cols 16-17 (XROXX). Replace with 2x2 black.
  [16, 15, 5], [17, 15, 5],
  [16, 16, 5], [17, 16, 5],
]);
const tapReact = [
  translate(TAP_WIDE_EYES, 0, 1),
  translate(IDLE_F0, 0, -1),
];

// ----- Scared: 2 frames -----
// f0: ears flattened back, wide eyes, body shrunk 1 px down
// f1: same, slight tremble (1 px shift left)
//
// Existing ears occupy rows 3-7 at cols 10-13 (left) and 19-22 (right).
const SCARED_BASE = (() => {
  const g = clone(IDLE_F0);
  // Erase the tall ears (rows 3-7, ear cols)
  for (let y = 3; y <= 6; y++) {
    for (let x = 10; x <= 13; x++) g[y][x] = 0;
    for (let x = 19; x <= 22; x++) g[y][x] = 0;
  }
  // Reflatten row 7 head top: cols 9 outline, 10-22 head fill, 23 outline.
  // Original row 7 left half had ears intermingled with head — clear and
  // rebuild it cleanly.
  for (let x = 9; x <= 23; x++) g[7][x] = 2;
  g[7][9] = 1; g[7][23] = 1;
  // Add flat back-folded ears: small dark triangles tilted outward sitting
  // on top of the head dome (row 6 cols 9-10 left, cols 22-23 right).
  g[6][9] = 1; g[6][10] = 1;
  g[6][22] = 1; g[6][23] = 1;
  // Wide-eyes: 3x2 wide black eyes (same as tap)
  const eyeFix = [
    [12, 12, 5], [13, 12, 5], [14, 12, 5],
    [12, 13, 5], [13, 13, 5], [14, 13, 5],
    [19, 12, 5], [20, 12, 5], [21, 12, 5],
    [19, 13, 5], [20, 13, 5], [21, 13, 5],
  ];
  for (const [x, y, c] of eyeFix) g[y][x] = c;
  // Tiny "o" sad mouth (2x2 black) at cols 16-17 rows 15-16
  g[15][16] = 5; g[15][17] = 5;
  g[16][16] = 5; g[16][17] = 5;
  return g;
})();
const scared = [
  translate(SCARED_BASE, 0, 1),
  translate(SCARED_BASE, -1, 1),
];

// =====================================================================
// Output
// =====================================================================

const catV1 = {
  version: 'v1',
  size: 32,
  meta: {
    groundY: 29,
    eyeAnchor: { x: 16, y: 13 },
  },
  baby: {
    idle,
    walking,
    happy,
    tapReact,
    scared,
  },
};

fs.mkdirSync(outDir, { recursive: true });
const outFile = path.join(outDir, 'cat-v1.json');
fs.writeFileSync(outFile, JSON.stringify(catV1) + '\n');

// Update palettes.json. v2 uses only 5 colors:
//   1 outline (warm dark brown)
//   2 primary fur (saturated orange)
//   3 secondary cream (belly + inner ears + paw centers)
//   5 black eye dots
//   7 pink blush (cheeks, mouth)
// Index 4 (white highlight) and 6 (tabby pattern) are unused but
// retained so the rest of the prototype's palette infrastructure
// keeps working.
const palettesPath = path.join(outDir, 'palettes.json');
const palettes = JSON.parse(fs.readFileSync(palettesPath, 'utf8'));
palettes.default = {
  '0': 'transparent',
  '1': '#3A2418', // outline (warm dark brown)
  '2': '#F0A040', // primary fur (warm saturated orange)
  '3': '#FFE6BE', // secondary cream (belly + inner ear + paw centers)
  '4': '#FFFFFF', // (unused in v2, kept for compat)
  '5': '#1A1A1A', // black eye dots
  '6': '#D67B26', // (unused in v2, kept for compat)
  '7': '#FF8FAA', // pink blush
};
for (const p of palettes.all) {
  if (!p['7']) p['7'] = '#FF8FAA';
}
fs.writeFileSync(palettesPath, JSON.stringify(palettes, null, 2) + '\n');

console.log(`Wrote ${path.relative(process.cwd(), outFile)}`);
console.log(
  `  baby frames: ${Object.entries(catV1.baby)
    .map(([k, v]) => `${k}=${v.length}`)
    .join(', ')}`,
);
console.log(`  size: ${SIZE}x${SIZE}`);
console.log(`Updated ${path.relative(process.cwd(), palettesPath)}.`);
