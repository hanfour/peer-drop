#!/usr/bin/env node
// Paint a 32x32 chibi-style cat sprite as JSON, in the ProHama tradition:
// big head (~60% vertical), big eyes, blush, round silhouette, triangular
// ears, small triangle nose. Output schema matches cat.json so the existing
// loader/SpriteCanvas can render it unchanged.
//
// Palette indices (extends the 6-slot scheme by 1):
//   0 transparent
//   1 outline       (#3A2418  warm dark brown — softer than pure black)
//   2 primary body  (#F4A041  saturated orange tabby)
//   3 secondary     (#FFE0B5  cream belly)
//   4 highlight     (#FFFFFF  pure white shine for eyes)
//   5 accent eyes   (#1F1F2E  near-black eye fill)
//   6 pattern       (#D67B26  warm darker orange — stripes)
//   7 blush         (#FF8FAA  soft pink — v1 extension)
//
// We compose each frame by stamping named regions onto a 32x32 grid.
// Frames share most pixels and differ only in eyes, mouth, ear tilt,
// paws, tail, body offset, etc. so we paint a base "head" + "body" once
// and then overlay deltas per frame.

import fs from 'fs';
import path from 'path';
import { fileURLToPath } from 'url';

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const outDir = path.resolve(__dirname, '../public/data');

const SIZE = 32;

/** Palette indices (named for readability). */
const T = 0; // transparent
const O = 1; // outline
const P = 2; // primary
const S = 3; // secondary (belly/inner ear)
const H = 4; // highlight (white)
const E = 5; // eye fill (near-black)
const M = 6; // pattern (darker orange stripes)
const B = 7; // blush

// =====================================================================
// Grid helpers
// =====================================================================

const blank = () =>
  Array.from({ length: SIZE }, () => Array(SIZE).fill(T));

const cloneGrid = (g) => g.map((row) => row.slice());

/** Draw a horizontal run starting at (x,y), width w, in color c. */
function hLine(g, x, y, w, c) {
  if (y < 0 || y >= SIZE) return;
  for (let i = 0; i < w; i++) {
    const px = x + i;
    if (px < 0 || px >= SIZE) continue;
    g[y][px] = c;
  }
}

/** Draw a vertical run. */
function vLine(g, x, y, h, c) {
  if (x < 0 || x >= SIZE) return;
  for (let i = 0; i < h; i++) {
    const py = y + i;
    if (py < 0 || py >= SIZE) continue;
    g[py][x] = c;
  }
}

/** Paint a single pixel. */
function px(g, x, y, c) {
  if (x < 0 || x >= SIZE || y < 0 || y >= SIZE) return;
  g[y][x] = c;
}

/** Fill a rectangle [x..x+w-1][y..y+h-1]. */
function rect(g, x, y, w, h, c) {
  for (let dy = 0; dy < h; dy++) {
    for (let dx = 0; dx < w; dx++) {
      px(g, x + dx, y + dy, c);
    }
  }
}

/** Draw a row by reading a string of ASCII codes. */
function row(g, x, y, str) {
  const map = {
    '.': null, // skip (preserve underlying pixel)
    ' ': null,
    o: O,
    p: P,
    s: S,
    h: H,
    e: E,
    m: M,
    b: B,
    '_': T, // explicit transparent
  };
  for (let i = 0; i < str.length; i++) {
    const ch = str[i];
    const c = map[ch];
    if (c === undefined)
      throw new Error(`Unknown char '${ch}' in row at y=${y}`);
    if (c === null) continue;
    px(g, x + i, y, c);
  }
}

/** Stamp a small 2D pattern onto the grid at (x,y). Use null/undefined to skip. */
function stamp(g, x, y, pattern) {
  for (let dy = 0; dy < pattern.length; dy++) {
    const r = pattern[dy];
    for (let dx = 0; dx < r.length; dx++) {
      const c = r[dx];
      if (c === null || c === undefined) continue;
      px(g, x + dx, y + dy, c);
    }
  }
}

// =====================================================================
// Body / head silhouette
// =====================================================================
//
// Layout plan (32x32):
//  rows 0..1   blush of empty space + ear tips
//  rows 2..6   ears (triangular, 5 rows tall)
//  rows 4..19  HEAD — big, round, ~16 rows tall, ~20 wide centered at x=16
//  rows 20..27 BODY — round, ~8 rows tall, narrower than head
//  rows 28..29 paws/feet
//  rows 30..31 ground-line shadow / tail tip
//
// Outline strategy: only outline the silhouette + key features. We DON'T
// outline every interior shape — that's what makes ProHama feel "soft"
// rather than "blocky pixel art."

/**
 * Paint the base head (no eyes/mouth — just silhouette + ears + cheek
 * fill). Produces a round-ish head ~20px wide centered horizontally,
 * with triangle ears poking up.
 *
 * Returns a fresh grid.
 */
function paintBaseHead({ earTilt = 0 } = {}) {
  const g = blank();

  // ----- Ears (triangles, rows 2..7) -----
  // Left ear roughly at columns 6..11, right ear at columns 20..25.
  // Tilt: when earTilt = 1 the ears stand up slightly (1 row taller).
  // when earTilt = -1 they flatten.
  const earBaseY = 7 - earTilt; // 7 default; 6 when up, 8 when flat
  // Left ear outline
  // Triangular: tip at (8, earBaseY-5), base from (6, earBaseY) to (11, earBaseY)
  const leftTipX = 8;
  const rightTipX = 23;
  // Left ear
  for (let i = 0; i < 5; i++) {
    // i=0 tip, i=4 base. Width grows.
    const y = earBaseY - 5 + i + 1;
    const halfW = i + 1;
    const xStart = leftTipX - halfW + 1;
    const xEnd = leftTipX + halfW;
    // outline left + right of triangle row
    px(g, xStart, y, O);
    px(g, xEnd, y, O);
    // fill between
    for (let x = xStart + 1; x < xEnd; x++) px(g, x, y, P);
  }
  // Right ear (mirror)
  for (let i = 0; i < 5; i++) {
    const y = earBaseY - 5 + i + 1;
    const halfW = i + 1;
    const xStart = rightTipX - halfW + 1;
    const xEnd = rightTipX + halfW;
    px(g, xStart, y, O);
    px(g, xEnd, y, O);
    for (let x = xStart + 1; x < xEnd; x++) px(g, x, y, P);
  }
  // Inner ear pink/secondary triangles (smaller, inside each)
  // Left inner ear
  for (let i = 0; i < 3; i++) {
    const y = earBaseY - 3 + i + 1;
    const halfW = i;
    if (halfW <= 0) continue;
    for (let x = leftTipX - halfW + 1; x < leftTipX + halfW; x++) {
      px(g, x, y, S);
    }
  }
  for (let i = 0; i < 3; i++) {
    const y = earBaseY - 3 + i + 1;
    const halfW = i;
    if (halfW <= 0) continue;
    for (let x = rightTipX - halfW + 1; x < rightTipX + halfW; x++) {
      px(g, x, y, S);
    }
  }

  // ----- Head silhouette (round, rows ~6 to 19) -----
  // We define an outline mask for a round head with chunky cheeks.
  // Approximate shape: top flat-ish, sides curve out, bottom narrows
  // into the body.
  //
  // Outline rows (left edge x → right edge x), inclusive:
  // Index by absolute y row.
  const headOutline = {
    6:  [9, 22],   // upper-top after ears
    7:  [7, 24],   // forehead curve start
    8:  [6, 25],
    9:  [5, 26],
    10: [4, 27],
    11: [4, 27],
    12: [4, 27],
    13: [4, 27],
    14: [5, 26],
    15: [5, 26],
    16: [6, 25],
    17: [7, 24],
    18: [9, 22],
    19: [10, 21],
  };

  // Fill head interior with primary color; draw outline 1px on edges.
  for (const [yStr, [xL, xR]] of Object.entries(headOutline)) {
    const y = parseInt(yStr, 10);
    px(g, xL, y, O);
    px(g, xR, y, O);
    for (let x = xL + 1; x < xR; x++) px(g, x, y, P);
  }
  // Top cap between ears at y=5 — connect ears
  // (this is the head dome between the two ears)
  for (let x = 11; x <= 20; x++) px(g, x, 5, O);
  // Re-fill interior just below
  for (let x = 12; x <= 19; x++) px(g, x, 6, P);

  // Cheek/under-chin secondary patch (lighter cream around mouth area)
  // This makes the lower face read as "muzzle" — important for cute reading.
  for (let y = 14; y <= 17; y++) {
    for (let x = 12; x <= 19; x++) {
      g[y][x] = S;
    }
  }
  // Tighten the muzzle region slightly
  px(g, 12, 14, P);
  px(g, 19, 14, P);
  px(g, 12, 17, P);
  px(g, 19, 17, P);

  return g;
}

/**
 * Stamp eyes + nose + mouth onto a head grid.
 * Mode controls the variant.
 *   - 'open'   : large open eyes (default idle)
 *   - 'blink'  : eyes closed (thin horizontal line)
 *   - 'smile'  : ^^ shaped happy eyes
 *   - 'wide'   : larger eyes for scared
 *   - 'closed-smile': peaceful — used for reactions
 */
function paintFace(g, mode = 'open', { mouth = 'small', blushBoost = false } = {}) {
  const leftEyeX = 10;
  const rightEyeX = 19;
  const eyeY = 11;

  if (mode === 'open') {
    // 3x4 eye blocks with outline + white highlight pixel.
    // Left eye
    rect(g, leftEyeX, eyeY, 3, 4, E);
    px(g, leftEyeX + 1, eyeY + 1, H); // highlight
    // Right eye
    rect(g, rightEyeX, eyeY, 3, 4, E);
    px(g, rightEyeX + 1, eyeY + 1, H);
  } else if (mode === 'blink') {
    // Thin horizontal line (closed eyes)
    hLine(g, leftEyeX, eyeY + 2, 3, O);
    hLine(g, rightEyeX, eyeY + 2, 3, O);
  } else if (mode === 'smile') {
    // ^^ — outline pixels forming an upward arc
    px(g, leftEyeX, eyeY + 2, O);
    px(g, leftEyeX + 1, eyeY + 1, O);
    px(g, leftEyeX + 2, eyeY + 2, O);
    px(g, rightEyeX, eyeY + 2, O);
    px(g, rightEyeX + 1, eyeY + 1, O);
    px(g, rightEyeX + 2, eyeY + 2, O);
  } else if (mode === 'wide') {
    // Larger eye blocks (4x5 with prominent white)
    rect(g, leftEyeX - 1, eyeY - 1, 4, 5, E);
    rect(g, leftEyeX, eyeY, 2, 2, H);
    rect(g, rightEyeX, eyeY - 1, 4, 5, E);
    rect(g, rightEyeX + 1, eyeY, 2, 2, H);
  } else if (mode === 'closed-smile') {
    // Like blink but slightly curved: ‿ ‿
    hLine(g, leftEyeX, eyeY + 2, 3, O);
    px(g, leftEyeX, eyeY + 1, O);
    px(g, leftEyeX + 2, eyeY + 1, O);
    hLine(g, rightEyeX, eyeY + 2, 3, O);
    px(g, rightEyeX, eyeY + 1, O);
    px(g, rightEyeX + 2, eyeY + 1, O);
  }

  // Nose — small pink/dark triangle in the muzzle area, centered.
  // Centered between eyes, just above muzzle.
  const noseY = 15;
  const noseX = 15;
  // small inverted triangle
  px(g, noseX, noseY, B);
  px(g, noseX + 1, noseY, B);
  px(g, noseX, noseY + 1, B);
  // outline the bottom of the nose lightly
  px(g, noseX + 1, noseY + 1, O);

  // Mouth
  if (mouth === 'small') {
    // tiny "w" or single dimple under the nose
    px(g, noseX, noseY + 2, O);
    px(g, noseX + 1, noseY + 2, O);
  } else if (mouth === 'open') {
    // small "o"
    px(g, noseX, noseY + 2, O);
    px(g, noseX + 1, noseY + 2, O);
    px(g, noseX, noseY + 3, O);
    px(g, noseX + 1, noseY + 3, O);
    // pink inside
    // (no inside pixels available — keep simple)
  } else if (mouth === 'happy-w') {
    // ^v^ shape: small "w" mouth
    px(g, noseX - 1, noseY + 2, O);
    px(g, noseX, noseY + 3, O);
    px(g, noseX + 1, noseY + 3, O);
    px(g, noseX + 2, noseY + 2, O);
  } else if (mouth === 'frown') {
    px(g, noseX - 1, noseY + 3, O);
    px(g, noseX, noseY + 2, O);
    px(g, noseX + 1, noseY + 2, O);
    px(g, noseX + 2, noseY + 3, O);
  }

  // Blush dots — pink ovals on each cheek, BENEATH the eyes.
  // 2x1 strip per cheek; brighter when blushBoost.
  const blushY = eyeY + 4; // row 15
  // Left cheek
  px(g, 7, blushY, B);
  px(g, 8, blushY, B);
  // Right cheek
  px(g, 23, blushY, B);
  px(g, 24, blushY, B);
  if (blushBoost) {
    // Add a 2nd row of blush + a wider cheek smear
    px(g, 7, blushY + 1, B);
    px(g, 8, blushY + 1, B);
    px(g, 23, blushY + 1, B);
    px(g, 24, blushY + 1, B);
    px(g, 6, blushY, B);
    px(g, 25, blushY, B);
  }

  // Forehead tabby pattern — 2 small ticks at top of head (subtle)
  px(g, 12, 7, M);
  px(g, 14, 6, M);
  px(g, 17, 6, M);
  px(g, 19, 7, M);
}

/**
 * Paint the body silhouette — round-ish blob that connects to the head.
 * Body proportions:
 *   - rows 20..27 (8 tall)
 *   - centered at x=16, ~16 wide
 *   - belly (cream) is a vertical strip in the middle-bottom
 *
 * Variants (controlled by paws/tail/squash/lift):
 *   pose: 'idle' | 'walkA' | 'walkB' | 'sit-squash' | 'sit-stretch' | 'shrunk'
 *   tail: 'up' | 'curl' | 'wagL' | 'wagR' | 'tucked'
 */
function paintBody(g, { pose = 'idle', tail = 'curl', yShift = 0 } = {}) {
  // Body silhouette outline rows (the "blob").
  const bodyShape = {
    20: [10, 21], // shoulders blend into head bottom
    21: [9, 22],
    22: [8, 23],
    23: [8, 23],
    24: [8, 23],
    25: [8, 23],
    26: [9, 22],
    27: [10, 21], // bottom narrows
  };
  for (const [yStr, [xL, xR]] of Object.entries(bodyShape)) {
    const y = parseInt(yStr, 10) + yShift;
    if (y < 0 || y >= SIZE) continue;
    px(g, xL, y, O);
    px(g, xR, y, O);
    for (let x = xL + 1; x < xR; x++) px(g, x, y, P);
  }
  // Belly cream — center bottom of body
  for (let y = 23 + yShift; y <= 26 + yShift; y++) {
    if (y < 0 || y >= SIZE) continue;
    for (let x = 12; x <= 19; x++) {
      g[y][x] = S;
    }
  }
  // A subtle stripe band on the back
  for (let x = 11; x <= 20; x++) {
    px(g, x, 21 + yShift, M);
  }
  // Re-outline the belly area's left/right edges so stripe doesn't paint over outline
  for (const [yStr, [xL, xR]] of Object.entries(bodyShape)) {
    const y = parseInt(yStr, 10) + yShift;
    if (y < 0 || y >= SIZE) continue;
    px(g, xL, y, O);
    px(g, xR, y, O);
  }

  // ----- Paws (rows 28..29) -----
  // Two front paws, position depends on pose.
  const pawY = 28 + yShift;
  if (pose === 'idle' || pose === 'sit-squash' || pose === 'sit-stretch') {
    // Symmetric small paws
    rect(g, 11, pawY, 3, 2, P);
    rect(g, 18, pawY, 3, 2, P);
    // outline bottom
    hLine(g, 11, pawY + 1, 3, O);
    hLine(g, 18, pawY + 1, 3, O);
    // outline top edges (where they meet body)
    px(g, 11, pawY, O);
    px(g, 13, pawY, O);
    px(g, 18, pawY, O);
    px(g, 20, pawY, O);
  } else if (pose === 'walkA') {
    // Right paw forward (lifted slightly), left paw back
    rect(g, 10, pawY - 1, 3, 2, P);
    hLine(g, 10, pawY, 3, O);
    px(g, 10, pawY - 1, O);
    px(g, 12, pawY - 1, O);
    rect(g, 19, pawY, 3, 2, P);
    hLine(g, 19, pawY + 1, 3, O);
    px(g, 19, pawY, O);
    px(g, 21, pawY, O);
  } else if (pose === 'walkB') {
    // Left paw forward, right paw back
    rect(g, 10, pawY, 3, 2, P);
    hLine(g, 10, pawY + 1, 3, O);
    px(g, 10, pawY, O);
    px(g, 12, pawY, O);
    rect(g, 19, pawY - 1, 3, 2, P);
    hLine(g, 19, pawY, 3, O);
    px(g, 19, pawY - 1, O);
    px(g, 21, pawY - 1, O);
  } else if (pose === 'shrunk') {
    // Tucked paws — single thin row
    rect(g, 12, pawY, 8, 1, P);
    hLine(g, 12, pawY + 1, 8, O);
  }

  // ----- Tail -----
  // Tail comes off the right side of body, curls up.
  if (tail === 'curl') {
    // Curling up over the back-right
    px(g, 24, 25, O);
    px(g, 25, 24, O);
    px(g, 25, 23, O);
    px(g, 26, 22, O);
    px(g, 26, 21, O);
    px(g, 26, 20, O);
    px(g, 25, 19, O);
    // fill curl interior (1px shy of outline)
    px(g, 25, 22, P);
    px(g, 25, 21, P);
    px(g, 25, 20, P);
    // tip
    px(g, 24, 19, S);
  } else if (tail === 'up') {
    vLine(g, 25, 19, 7, O);
    vLine(g, 26, 19, 7, P);
    px(g, 26, 18, S);
  } else if (tail === 'wagL') {
    px(g, 24, 25, O);
    px(g, 25, 24, O);
    px(g, 26, 23, O);
    px(g, 27, 22, O);
    px(g, 28, 21, O);
    px(g, 27, 21, P);
    px(g, 28, 22, P);
  } else if (tail === 'wagR') {
    px(g, 24, 25, O);
    px(g, 25, 25, O);
    px(g, 26, 24, O);
    px(g, 27, 24, O);
    px(g, 28, 23, O);
    px(g, 28, 24, P);
    px(g, 27, 23, P);
  } else if (tail === 'tucked') {
    // Just a stub
    px(g, 23, 26, P);
    px(g, 24, 26, O);
  }
}

// =====================================================================
// Frame composition for each action
// =====================================================================

/** Compose a single frame from head+face+body options. */
function frame({
  faceMode = 'open',
  mouth = 'small',
  earTilt = 0,
  blushBoost = false,
  pose = 'idle',
  tail = 'curl',
  headYShift = 0,
  bodyYShift = 0,
}) {
  const g = paintBaseHead({ earTilt });
  paintFace(g, faceMode, { mouth, blushBoost });

  // Apply head Y-shift by translating the painted head DOWN/UP by
  // copying rows. (Simpler than threading yShift into every helper.)
  let headShifted = g;
  if (headYShift !== 0) {
    headShifted = blank();
    for (let y = 0; y < SIZE; y++) {
      const srcY = y - headYShift;
      if (srcY < 0 || srcY >= SIZE) continue;
      for (let x = 0; x < SIZE; x++) {
        if (g[srcY][x] !== T) headShifted[y][x] = g[srcY][x];
      }
    }
  }

  paintBody(headShifted, { pose, tail, yShift: bodyYShift });

  return headShifted;
}

// =====================================================================
// Action definitions
// =====================================================================

const idle = [
  // 0: standard
  frame({ faceMode: 'open', mouth: 'small', tail: 'curl' }),
  // 1: subtle breath rise — head 1px up
  frame({ faceMode: 'open', mouth: 'small', tail: 'curl', headYShift: -1 }),
  // 2: blink
  frame({ faceMode: 'blink', mouth: 'small', tail: 'curl' }),
  // 3: standard again (frame 0 echo)
  frame({ faceMode: 'open', mouth: 'small', tail: 'curl' }),
];

const walking = [
  frame({ faceMode: 'open', mouth: 'small', pose: 'walkA', tail: 'wagL' }),
  frame({ faceMode: 'open', mouth: 'small', pose: 'idle', tail: 'curl' }),
  frame({ faceMode: 'open', mouth: 'small', pose: 'walkB', tail: 'wagR' }),
  frame({ faceMode: 'open', mouth: 'small', pose: 'idle', tail: 'curl' }),
];

const happy = [
  frame({
    faceMode: 'smile',
    mouth: 'happy-w',
    earTilt: 1,
    tail: 'up',
    blushBoost: true,
  }),
  // Hop: whole body 1px up, ears still tilted
  frame({
    faceMode: 'smile',
    mouth: 'happy-w',
    earTilt: 1,
    tail: 'up',
    blushBoost: true,
    headYShift: -2,
    bodyYShift: -2,
  }),
];

const tapReact = [
  // Squashed
  frame({
    faceMode: 'wide',
    mouth: 'open',
    pose: 'sit-squash',
    tail: 'curl',
    bodyYShift: 1,
    headYShift: 1,
  }),
  // Stretched + cheek blush boost
  frame({
    faceMode: 'open',
    mouth: 'happy-w',
    pose: 'sit-stretch',
    tail: 'up',
    blushBoost: true,
    headYShift: -1,
  }),
];

const scared = [
  // Wide eyes, ears flat (negative tilt)
  frame({
    faceMode: 'wide',
    mouth: 'frown',
    earTilt: -1,
    pose: 'idle',
    tail: 'tucked',
  }),
  // Body shrunk
  frame({
    faceMode: 'wide',
    mouth: 'frown',
    earTilt: -1,
    pose: 'shrunk',
    tail: 'tucked',
    bodyYShift: 1,
  }),
];

// =====================================================================
// Output
// =====================================================================

const catV1 = {
  version: 'v1',
  size: 32,
  meta: {
    groundY: 28,
    eyeAnchor: { x: 16, y: 11 },
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

// Also extend palettes.json with index 7 (blush) for the v1 sprite.
const palettesPath = path.join(outDir, 'palettes.json');
const palettes = JSON.parse(fs.readFileSync(palettesPath, 'utf8'));
// Update default palette only (v1 cat references default).
// Refine outline + primary to read more "chibi": warmer dark-brown outline,
// saturated orange body, lighter cream secondary, near-black eyes (5),
// darker tabby (6), blush pink (7).
palettes.default = {
  '0': 'transparent',
  '1': '#3A2418', // outline (warm dark brown)
  '2': '#F4A041', // primary (saturated orange)
  '3': '#FFE0B5', // secondary (cream)
  '4': '#FFFFFF', // highlight (pure white)
  '5': '#1F1F2E', // eye fill (deep blue-black)
  '6': '#D67B26', // pattern (warm darker orange stripes)
  '7': '#FF8FAA', // blush (v1 extension)
};
// Ensure all alternate palettes also have an index 7 (so multi-palette
// rendering doesn't break). Use a soft pink default.
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
console.log(`Updated ${path.relative(process.cwd(), palettesPath)} with index 7 blush.`);
