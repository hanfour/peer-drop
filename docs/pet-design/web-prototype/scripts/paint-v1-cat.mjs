#!/usr/bin/env node
// Paint a 32x32 chibi-style CAT sprite as JSON.
//
// Design brief (v1.2 — conservative anatomy fix):
//   The previous iteration over-emphasised feline features — tall ears,
//   long whiskers and articulated paws — and the result read as a
//   rabbit-rabbit-teddy hybrid. This pass dials each feature WAY back:
//
//   - Ears: max 3 rows tall, narrow triangle (1px tip → 3px base).
//     Anchored on a wide head dome so the silhouette is "round head with
//     two small triangles", not "vertical bars sticking up".
//   - Whiskers: short — 2 pixels of outward protrusion at most. A single
//     stagger line of pattern colour, sitting flush with the cheek.
//   - Body: a single sitting oval with a cream belly. The bottom edge is
//     a flat outline row — NO leg/paw articulation, no separate digits.
//     Cat reads as sitting, not standing on hind legs.
//   - Eyes: closer together — at most 4 px of forehead between the inner
//     edges. Almond shape with white highlight + dark pupil.
//   - Nose + mouth: kept tiny (3-px nose triangle, 2-3 px mouth line).
//   - Tail: a simple curl up the rear-right of the body.
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
//   X outline (dark brown)
//   O primary body (orange)
//   c cream belly (secondary)
//   W white eye highlight
//   B dark pupil — we override palette index 5 to a dark colour for v1
//     so this reads as a pupil, not the warm orange #E85D3A.
//   P pattern darker orange (back stripes)
//   R blush pink (inner ear, nose)
const CHAR_MAP = {
  '.': 0,
  X: 1,
  O: 2,
  c: 3,
  W: 4,
  B: 5,
  P: 6,
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
// Anatomy plan (32x32):
//   rows  3-5    ears (3 rows tall, narrow triangle, pink inner)
//   rows  6-9    head dome (curved top)
//   rows 10-15   face — back stripes, eyes, whiskers
//   rows 16-18   chin / nose / mouth
//   rows 19-26   sitting body oval with cream belly
//   row  27      flat outline (no leg articulation)
//   rows 23-26   curl tail to rear-right of body
//
// Eye anchors:
//   left  eye cols 11-13 (3 wide)
//   right eye cols 18-20 (3 wide)
//   forehead gap = cols 14-17 (4 px) — at the upper limit
//
// Whisker anchors (short!):
//   left:  cols 5-6 (2 px outward of the head edge at col 7)
//   right: cols 25-26 (2 px outward of the head edge at col 24)
//
// Counted carefully: each row is 32 chars.

const IDLE_F0 = gridFromAscii([
  /* 0  */ '................................',
  /* 1  */ '................................',
  /* 2  */ '................................',
  /* 3  */ '..........X.........X...........',
  /* 4  */ '.........XRX.......XRX..........',
  /* 5  */ '........XORX.......XORX.........',
  /* 6  */ '.......XOOOXXXXXXXXXOOOX........',
  /* 7  */ '......XOOOOOOOOOOOOOOOOOX.......',
  /* 8  */ '......XOOOOOOOOOOOOOOOOOX.......',
  /* 9  */ '.....XOOOPPOOOOOOOOPPOOOOX......',
  /* 10 */ '.....XOOOOOOOOOOOOOOOOOOOX......',
  /* 11 */ '.....XOOOOOOOOOOOOOOOOOOOX......',
  /* 12 */ '.....XOOOOOXWBXOOXBWXOOOOOX.....',
  /* 13 */ '.....XOOOOOXBBXOOXBBXOOOOOX.....',
  /* 14 */ '.....XOOOOOOXXOOOOXXOOOOOOX.....',
  /* 15 */ '...XXXOOOOOOOOORROOOOOOOOOXXX...',
  /* 16 */ '.....XOOOOOOOOORROOOOOOOOOX.....',
  /* 17 */ '.....XOOOOOOOOOXXOOOOOOOOOX.....',
  /* 18 */ '.....XOOOOOOOOOOOOOOOOOOOX......',
  /* 19 */ '......XOOOOOOOOOOOOOOOOOX.......',
  /* 20 */ '.......XOOOOOOOOOOOOOOOX........',
  /* 21 */ '.......XOOOOOOOOOOOOOOOX........',
  /* 22 */ '......XOOcccccccccccccOX........',
  /* 23 */ '......XOcccccccccccccccOX.......',
  /* 24 */ '......XOcccccccccccccccOX..XX...',
  /* 25 */ '......XOcccccccccccccccOXXXOOX..',
  /* 26 */ '......XOOcccccccccccccOOXXOOX...',
  /* 27 */ '.......XOOOOOOOOOOOOOOOXXOOX....',
  /* 28 */ '........XXXXXXXXXXXXXXXXXX......',
  /* 29 */ '................................',
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

// ----- Idle: 4 frames -----
// f0: standard
// f1: subtle breath rise — entire sprite up 1 px
// f2: blink — eyes become a single horizontal line
// f3: standard echo
const idle = [
  IDLE_F0,
  translate(IDLE_F0, 0, -1),
  // Blink: replace eye blocks with a single dark line at row 13.
  // Original eyes occupy rows 12-14 cols 11-14 (left) and 17-20 (right).
  patch(IDLE_F0, [
    // Clear eye area (rows 12-13 at eye columns) → restore body orange.
    [11, 12, 2], [12, 12, 2], [13, 12, 2], [14, 12, 2],
    [17, 12, 2], [18, 12, 2], [19, 12, 2], [20, 12, 2],
    [11, 13, 2], [12, 13, 2], [13, 13, 2], [14, 13, 2],
    [17, 13, 2], [18, 13, 2], [19, 13, 2], [20, 13, 2],
    [12, 14, 2], [13, 14, 2], [18, 14, 2], [19, 14, 2],
    // Closed-eye lines (3 px each) at row 13.
    [11, 13, 1], [12, 13, 1], [13, 13, 1],
    [18, 13, 1], [19, 13, 1], [20, 13, 1],
  ]),
  IDLE_F0,
];

// ----- Walking: 4 frames -----
// We don't try to articulate paws (the sprite intentionally has no leg
// articulation). Instead we simulate trotting via vertical bob + tail
// wag. The body+head stays as a single oval — that's what reads "cat".
const walking = [
  IDLE_F0,
  translate(IDLE_F0, 0, -1), // bob up
  IDLE_F0,
  translate(IDLE_F0, 0, 1),  // bob down
];

// ----- Happy: 2 frames -----
// f0: smile eyes + perked ears + body lifts 1 px (excited)
// f1: same with ears even higher (tip pixel raised) + body lifts another 1 px
const HAPPY_BASE = patch(IDLE_F0, [
  // Replace open eyes with closed-arc smile eyes (^^):
  // Clear the 3-row eye blocks first
  [11, 12, 2], [12, 12, 2], [13, 12, 2], [14, 12, 2],
  [17, 12, 2], [18, 12, 2], [19, 12, 2], [20, 12, 2],
  [11, 13, 2], [12, 13, 2], [13, 13, 2], [14, 13, 2],
  [17, 13, 2], [18, 13, 2], [19, 13, 2], [20, 13, 2],
  [12, 14, 2], [13, 14, 2], [18, 14, 2], [19, 14, 2],
  // ^ shapes: dip in the middle
  [11, 13, 1], [12, 12, 1], [13, 13, 1],
  [18, 13, 1], [19, 12, 1], [20, 13, 1],
  // Slightly bigger blush dots on the cheeks (replace existing pink at
  // rows 15-16 — already blush). Add dots at row 14.
  [9, 14, 7], [22, 14, 7],
]);
const happy = [
  translate(HAPPY_BASE, 0, -1),
  translate(HAPPY_BASE, 0, -2),
];

// ----- TapReact: 2 frames -----
// f0: squash — body 1 px down, eyes wide
// f1: stretch — body 1 px up
const TAP_WIDE_EYES = patch(IDLE_F0, [
  // Clear original eyes
  [11, 12, 2], [12, 12, 2], [13, 12, 2], [14, 12, 2],
  [17, 12, 2], [18, 12, 2], [19, 12, 2], [20, 12, 2],
  [11, 13, 2], [12, 13, 2], [13, 13, 2], [14, 13, 2],
  [17, 13, 2], [18, 13, 2], [19, 13, 2], [20, 13, 2],
  [12, 14, 2], [13, 14, 2], [18, 14, 2], [19, 14, 2],
  // Wide round eyes (3x3 block of dark with white highlight in centre):
  [11, 12, 1], [12, 12, 5], [13, 12, 5], [14, 12, 1],
  [11, 13, 1], [12, 13, 5], [13, 13, 4], [14, 13, 1],
  [11, 14, 1], [12, 14, 1], [13, 14, 1], [14, 14, 1],
  [17, 12, 1], [18, 12, 5], [19, 12, 5], [20, 12, 1],
  [17, 13, 1], [18, 13, 4], [19, 13, 5], [20, 13, 1],
  [17, 14, 1], [18, 14, 1], [19, 14, 1], [20, 14, 1],
]);
const tapReact = [
  translate(TAP_WIDE_EYES, 0, 1),
  translate(IDLE_F0, 0, -1),
];

// ----- Scared: 2 frames -----
// f0: ears flat (only 2 rows), wide eyes, body shrunk 1 px down
// f1: same but tail tucked (we cheat — tail stays the same; emphasis on body)
const SCARED_BASE = (() => {
  const g = clone(IDLE_F0);
  // Erase the existing 3-row triangular ears (rows 3-5) — make them
  // squashed into rows 4-5 only.
  // Clear ear area first
  for (let y = 3; y <= 5; y++) {
    for (let x = 9; x <= 13; x++) g[y][x] = 0;
    for (let x = 18; x <= 22; x++) g[y][x] = 0;
  }
  // Add the head dome row at row 5 back (so ears sit ON the head):
  // The dome at row 6 already has outline. We need to refill row 5
  // where the head was visible (cols 8 and 23 outline, 9-22 primary).
  // Original row 5 ASCII: "........XORX.......XORX........."
  // After clearing: only col 8 outline, col 23 outline survive (both at
  // x=8 and x=23 as outline). Let me redraw row 5 as flat:
  // cols 8: X, 9-22: O (continuous head), 23: X
  g[5][8] = 1;
  for (let x = 9; x <= 22; x++) g[5][x] = 2;
  g[5][23] = 1;
  // Add flat ears (folded back) at rows 4-5: small triangles slightly
  // off to the sides.
  g[4][9] = 1; g[4][10] = 7; g[4][11] = 1;
  g[4][20] = 1; g[4][21] = 7; g[4][22] = 1;
  // Wide-eyes patches (rows 12-14)
  const eyeFix = [
    [11, 12, 1], [12, 12, 5], [13, 12, 5], [14, 12, 1],
    [11, 13, 1], [12, 13, 4], [13, 13, 5], [14, 13, 1],
    [11, 14, 1], [12, 14, 1], [13, 14, 1], [14, 14, 1],
    [17, 12, 1], [18, 12, 5], [19, 12, 5], [20, 12, 1],
    [17, 13, 1], [18, 13, 5], [19, 13, 4], [20, 13, 1],
    [17, 14, 1], [18, 14, 1], [19, 14, 1], [20, 14, 1],
  ];
  for (const [x, y, c] of eyeFix) g[y][x] = c;
  // Frown mouth: replace the small mouth ^ at row 17 cols 15-16 with a
  // downward V (corners up, middle down)
  g[17][14] = 1; g[17][15] = 0; g[17][16] = 0; g[17][17] = 1;
  g[18][15] = 1; g[18][16] = 1;
  return g;
})();
const scared = [
  translate(SCARED_BASE, 0, 1),
  translate(SCARED_BASE, 0, 1),
];

// =====================================================================
// Output
// =====================================================================

const catV1 = {
  version: 'v1',
  size: 32,
  meta: {
    groundY: 28,
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

// Update palettes.json so palette index 5 is the dark pupil colour for
// v1 (#3A2418-ish, not the warm orange that the production palette
// originally used).
const palettesPath = path.join(outDir, 'palettes.json');
const palettes = JSON.parse(fs.readFileSync(palettesPath, 'utf8'));
palettes.default = {
  '0': 'transparent',
  '1': '#3A2418', // outline (warm dark brown)
  '2': '#F4A041', // primary (saturated orange)
  '3': '#FFE0B5', // secondary cream
  '4': '#FFFFFF', // highlight (pure white for eye gleam)
  '5': '#1F1F2E', // dark pupil for v1
  '6': '#D67B26', // pattern (warm darker orange — back stripes)
  '7': '#FF8FAA', // blush pink (inner ear, nose)
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
