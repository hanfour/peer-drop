#!/usr/bin/env node
// Paint a 32x32 chibi-style CAT sprite as JSON.
//
// Design brief (v1.1 — feline anatomy fix):
//   - Sharp narrow triangular ears (1px tip, 3px base, 4-5px tall)
//     with pink inner triangle. Set ON TOP of the head dome.
//   - FLAT FACE — no protruding muzzle, no cream snout patch.
//     Nose sits directly between/below the eyes.
//   - Whiskers — 3 short horizontal lines on each side at nose row.
//     This is the single biggest "cat" semaphore in chibi pixel art.
//   - Almond/slanted eyes — outer column dropped 1px so the eye reads as
//     subtly slanted upward at the outer corner (not a perfect rectangle).
//   - Thin curled tail (1-2px wide) clearly visible behind the body.
//
// Output schema matches cat.json so the existing loader/SpriteCanvas can
// render it unchanged.
//
// Palette (extends the 6-slot scheme by 1):
//   0 transparent
//   1 outline       (#3A2418  warm dark brown)
//   2 primary body  (#F4A041  saturated orange tabby)
//   3 secondary     (#FFE0B5  cream belly)
//   4 highlight     (#FFFFFF  pure white shine for eyes)
//   5 accent eyes   (#1F1F2E  near-black eye fill)
//   6 pattern       (#D67B26  warm darker orange — stripes / whiskers)
//   7 blush         (#FF8FAA  soft pink — inner ear, nose, cheeks)

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
const S = 3; // secondary (belly)
const H = 4; // highlight (white)
const E = 5; // eye fill (near-black)
const M = 6; // pattern (darker orange stripes / whiskers)
const B = 7; // blush / inner ear / nose

// =====================================================================
// Grid helpers
// =====================================================================

const blank = () =>
  Array.from({ length: SIZE }, () => Array(SIZE).fill(T));

/** Draw a horizontal run starting at (x,y), width w, in color c. */
function hLine(g, x, y, w, c) {
  if (y < 0 || y >= SIZE) return;
  for (let i = 0; i < w; i++) {
    const xx = x + i;
    if (xx < 0 || xx >= SIZE) continue;
    g[y][xx] = c;
  }
}

/** Draw a vertical run. */
function vLine(g, x, y, h, c) {
  if (x < 0 || x >= SIZE) return;
  for (let i = 0; i < h; i++) {
    const yy = y + i;
    if (yy < 0 || yy >= SIZE) continue;
    g[yy][x] = c;
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

// =====================================================================
// Head silhouette + ears
// =====================================================================
//
// Layout plan (32x32):
//  rows 1..5    EARS (5 rows tall, sharp narrow triangles)
//  rows 5..18   HEAD (round, ~13 rows tall, ~18 wide)
//  rows 19..27  BODY (round, narrower than head)
//  rows 28..29  PAWS / feet
//
// Reading priority for a 32px chibi cat (from far away → close):
//   1. Silhouette: round head + two pointy ears poking up (no flopping)
//   2. Whiskers: triple horizontal ticks on each cheek
//   3. Tiny pink nose + flat face (no muzzle bulge)
//   4. Almond eyes with bright kawaii highlight
//   5. Thin curled tail behind body
//
// Cheek/under-chin secondary patch is REMOVED — that was reading as
// muzzle/snout and making the silhouette look canine.

/**
 * Paint base head silhouette + ears.
 *   earTilt:  0 = default,  1 = ears perked higher (excited),
 *            -1 = ears flatter (scared)
 *   ears:    'up' (default) | 'flat' | 'tilt'
 */
function paintBaseHead({ earTilt = 0, ears = 'up' } = {}) {
  const g = blank();

  // ----- Head silhouette (rows 5..18, rounded) -----
  // Outline rows: inclusive [xL, xR] for each y.
  // Smooth dome on top — must read as one continuous head, not two
  // separate "earlobes".
  const headOutline = {
    5:  [12, 19],   // top dome (between the two ears)
    6:  [10, 21],
    7:  [8, 23],
    8:  [7, 24],
    9:  [6, 25],
    10: [6, 25],
    11: [6, 25],
    12: [6, 25],
    13: [6, 25],
    14: [7, 24],
    15: [8, 23],
    16: [9, 22],
    17: [10, 21],
    18: [11, 20],
  };

  for (const [yStr, [xL, xR]] of Object.entries(headOutline)) {
    const y = parseInt(yStr, 10);
    px(g, xL, y, O);
    px(g, xR, y, O);
    for (let x = xL + 1; x < xR; x++) px(g, x, y, P);
  }

  // ----- Ears -----
  // Sharp narrow triangles. Anchored at the head dome top (y=5).
  // Default earBase row is 5 (the top of the head).
  // Ears extend UP from there: tip is 4 rows above the base.
  //
  //   .X.    row earBase-4  (1px tip)
  //   XPX    row earBase-3  (2 outline + 1 pink inner)
  //   XPX    row earBase-2
  //   XPX    row earBase-1
  //   XBX    row earBase    (sits on head dome — wider base = 3 wide)
  //
  // Left ear centered around column 11; right ear centered around 20.
  const earBaseY = 5;
  const tilt = earTilt; // 1 = perked (taller), -1 = flat (shorter)
  const earHeight = 4 + tilt; // default 4, perked 5, flat 3

  function paintEar(centerX, side /* -1 left, +1 right */) {
    const tipY = earBaseY - earHeight;
    if (ears === 'flat') {
      // Flat ears: render as squashed triangle, half-height
      const h = Math.max(2, earHeight - 1);
      for (let i = 0; i < h; i++) {
        const y = earBaseY - h + i;
        const halfW = Math.floor((i + 1) / 2);
        const xStart = centerX - halfW;
        const xEnd = centerX + halfW;
        px(g, xStart, y, O);
        if (xEnd > xStart) px(g, xEnd, y, O);
        for (let x = xStart + 1; x < xEnd; x++) px(g, x, y, P);
      }
      return;
    }

    // Sharp ear:
    // Tip (1px) at (centerX, tipY)
    px(g, centerX, tipY, O);
    // Mid rows (3 rows): outline at center-1 and center+1, pink fill in middle
    for (let r = 1; r <= earHeight - 1; r++) {
      const y = tipY + r;
      px(g, centerX - 1, y, O);
      px(g, centerX + 1, y, O);
      // Inner ear pink fill (only middle row gets pink to keep it small)
      if (r >= 1) {
        px(g, centerX, y, B);
      }
    }
    // Base row (sits on head, 3 wide)
    const baseY = earBaseY;
    px(g, centerX - 1, baseY, O);
    px(g, centerX + 1, baseY, O);
    px(g, centerX, baseY, B);

    // 'tilt' variant: lean ear outward by 1 column at tip
    if (ears === 'tilt') {
      // Erase the upper tip and re-place 1 column outward
      px(g, centerX, tipY, T);
      px(g, centerX + side, tipY, O);
    }
  }

  paintEar(11, -1); // left ear
  paintEar(20, +1); // right ear

  // The head dome row (y=5) is between x=12..19 — let's make sure
  // the ear bases plug cleanly into the dome. Ear bases are at x=10..12
  // (left) and x=19..21 (right). The dome row already has outline at
  // x=12 and x=19 from headOutline[5]. We need to ensure x=11 and x=20
  // (ear bases) blend into the head silhouette.
  // Actually: at row 5 the head outline runs x=12..19 (outline at 12,19;
  // primary at 13..18). The ear base at row 5 is at x=10,11,12 (left)
  // and 19,20,21 (right). So the ear and head share columns 12 and 19.
  // That's fine — the outline at those points reads as the head dome's
  // edge AND the ear's base edge. Pretty.

  // ----- Subtle tabby stripe pattern on the forehead -----
  // 2 small ticks above the eyes — adds tabby cat character.
  px(g, 13, 7, M);
  px(g, 18, 7, M);

  return g;
}

// =====================================================================
// Face: eyes + nose + mouth + whiskers + cheek blush
// =====================================================================
//
// THE WHISKERS ARE THE MOST IMPORTANT FEATURE. They read CAT instantly
// even at thumbnail size.
//
// Eye anchor: leftEye at (10, 9), rightEye at (19, 9). Eyes are 3 cols
// wide × 4 rows tall, but the OUTER column drops 1 row to create the
// almond/slanted-up shape.
//
// Nose sits at (15, 13). FLAT face — no muzzle, no cream patch.
// Mouth is a tiny "^v^" or single dimple at (15, 14).
//
// Whiskers at row 13-14 (nose level), 3 short ticks on each side.

function paintFace(g, mode = 'open', { mouth = 'small', blushBoost = false, whiskers = true } = {}) {
  // Eye anchors
  const lx = 10; // left eye left column
  const rx = 19; // right eye left column
  const ey = 9;  // eye top row

  if (mode === 'open') {
    // Almond/slanted eye:
    //   Inner column (lx+1 for left, rx for right): 3 pixels tall (rows ey..ey+2)
    //   Middle column: 3 pixels tall
    //   Outer column: shifted DOWN 1 (rows ey+1..ey+3) — makes the eye
    //   slant upward at the outer corner.
    // Plus a pure white highlight at upper-INNER corner (kawaii gleam).
    //
    // Left eye (outer corner is on the LEFT, so outer = column lx)
    // Right eye (outer corner is on the RIGHT, so outer = column rx+2)

    // ---- Left eye ----
    // outer column (lx): rows ey+1..ey+3
    vLine(g, lx, ey + 1, 3, E);
    // middle column (lx+1): rows ey..ey+2
    vLine(g, lx + 1, ey, 3, E);
    // inner column (lx+2): rows ey..ey+2
    vLine(g, lx + 2, ey, 3, E);
    // highlight at upper-inner
    px(g, lx + 2, ey, H);
    // tiny lower-inner sparkle (1px)
    px(g, lx + 2, ey + 2, H);

    // ---- Right eye (mirrored) ----
    // outer column (rx+2): rows ey+1..ey+3
    vLine(g, rx + 2, ey + 1, 3, E);
    // middle column (rx+1): rows ey..ey+2
    vLine(g, rx + 1, ey, 3, E);
    // inner column (rx): rows ey..ey+2
    vLine(g, rx, ey, 3, E);
    // highlight at upper-inner
    px(g, rx, ey, H);
    // tiny lower-inner sparkle
    px(g, rx, ey + 2, H);
  } else if (mode === 'blink') {
    // Closed eyes — short curved line per eye (slight upward slant)
    hLine(g, lx, ey + 2, 3, O);
    px(g, lx, ey + 1, O); // outer corner lifted
    hLine(g, rx, ey + 2, 3, O);
    px(g, rx + 2, ey + 1, O); // outer corner lifted
  } else if (mode === 'smile') {
    // ^^ happy eyes — closed-arc shape
    px(g, lx, ey + 2, O);
    px(g, lx + 1, ey + 1, O);
    px(g, lx + 2, ey + 2, O);
    px(g, rx, ey + 2, O);
    px(g, rx + 1, ey + 1, O);
    px(g, rx + 2, ey + 2, O);
  } else if (mode === 'wide') {
    // Big shocked eyes — 4×4 with prominent white. Maintain slant.
    rect(g, lx - 1, ey, 4, 4, E);
    rect(g, lx, ey + 1, 2, 2, H);
    rect(g, rx, ey, 4, 4, E);
    rect(g, rx + 1, ey + 1, 2, 2, H);
  } else if (mode === 'closed-smile') {
    // ‿ ‿
    hLine(g, lx, ey + 2, 3, O);
    px(g, lx, ey + 1, O);
    px(g, lx + 2, ey + 1, O);
    hLine(g, rx, ey + 2, 3, O);
    px(g, rx, ey + 1, O);
    px(g, rx + 2, ey + 1, O);
  }

  // ----- Nose -----
  // Tiny pink inverted triangle, centered between eyes.
  // 2 cols wide × 1 row, plus a single pixel below tapering to the mouth.
  const noseX = 15;
  const noseY = 13;
  px(g, noseX, noseY, B);
  px(g, noseX + 1, noseY, B);
  px(g, noseX, noseY + 1, B); // taper

  // ----- Mouth -----
  // Smaller and lower than v0. Tiny line just under the nose.
  if (mouth === 'small') {
    // Single subtle ^ shape — 2 px
    px(g, noseX, noseY + 2, O);
    px(g, noseX + 1, noseY + 2, O);
  } else if (mouth === 'open') {
    // Small "o" — 2x2 with pink interior
    rect(g, noseX, noseY + 2, 2, 2, O);
    px(g, noseX, noseY + 2, O);
    // (no inside fill — keeps it crisp at this size)
  } else if (mouth === 'happy-w') {
    // Tiny ^v^ — 4 px arrangement
    px(g, noseX - 1, noseY + 2, O);
    px(g, noseX, noseY + 3, O);
    px(g, noseX + 1, noseY + 3, O);
    px(g, noseX + 2, noseY + 2, O);
  } else if (mouth === 'frown') {
    // Inverted ^ — corners up, middle down
    px(g, noseX - 1, noseY + 3, O);
    px(g, noseX, noseY + 2, O);
    px(g, noseX + 1, noseY + 2, O);
    px(g, noseX + 2, noseY + 3, O);
  }

  // ----- WHISKERS — the cat's signature -----
  // 3 horizontal ticks on each side, at nose level.
  // Use pattern color (M = darker orange) so they read as fur-tinted
  // hairs rather than silhouette outline. Length 3px each.
  //
  // Left whiskers: extend from cheek (x=4..6, x=3..5, x=4..6)
  // Right whiskers: mirrored
  // Stagger: middle whisker is 1px longer / starts 1px further out
  // for a natural "spray" silhouette.
  if (whiskers) {
    // Left side — start adjacent to the head edge (head outline at rows
    // 12..14 sits at x=6) and extend outward. 3 whiskers, middle longest.
    // Upper whisker  (row 12, length 3, x=3..5)
    hLine(g, 3, 12, 3, M);
    // Middle whisker (row 13, length 4, x=1..4) — longest, lowest start
    hLine(g, 1, 13, 4, M);
    // Lower whisker  (row 14, length 3, x=3..5)
    hLine(g, 3, 14, 3, M);

    // Right side — mirror
    hLine(g, 26, 12, 3, M);
    hLine(g, 27, 13, 4, M);
    hLine(g, 26, 14, 3, M);
  }

  // ----- Cheek blush -----
  // Small pink dots beneath the eyes, ABOVE the whiskers, so they don't
  // collide. Position: row 12, just inside the head edge.
  const blushY = 12;
  px(g, 8, blushY, B);
  px(g, 23, blushY, B);
  if (blushBoost) {
    px(g, 7, blushY, B);
    px(g, 8, blushY + 1, B);
    px(g, 24, blushY, B);
    px(g, 23, blushY + 1, B);
  }
}

// =====================================================================
// Body + paws + tail
// =====================================================================

function paintBody(g, { pose = 'idle', tail = 'curl', yShift = 0 } = {}) {
  // Body silhouette: rows 19..27, narrower than head (~15 wide).
  // The neck/shoulders blend into head bottom (which ended at y=18).
  const bodyShape = {
    19: [11, 20], // shoulders blend into head bottom
    20: [10, 21],
    21: [9, 22],
    22: [9, 22],
    23: [9, 22],
    24: [9, 22],
    25: [10, 21],
    26: [10, 21],
    27: [11, 20], // bottom narrows
  };

  for (const [yStr, [xL, xR]] of Object.entries(bodyShape)) {
    const y = parseInt(yStr, 10) + yShift;
    if (y < 0 || y >= SIZE) continue;
    px(g, xL, y, O);
    px(g, xR, y, O);
    for (let x = xL + 1; x < xR; x++) px(g, x, y, P);
  }

  // Belly cream — center bottom of body
  for (let y = 22 + yShift; y <= 26 + yShift; y++) {
    if (y < 0 || y >= SIZE) continue;
    for (let x = 12; x <= 19; x++) {
      g[y][x] = S;
    }
  }
  // Subtle stripe band on the back
  for (let x = 12; x <= 19; x++) {
    px(g, x, 20 + yShift, M);
  }
  // Re-outline body edges (in case stripe overran)
  for (const [yStr, [xL, xR]] of Object.entries(bodyShape)) {
    const y = parseInt(yStr, 10) + yShift;
    if (y < 0 || y >= SIZE) continue;
    px(g, xL, y, O);
    px(g, xR, y, O);
  }

  // ----- Paws (rows 28..29) -----
  const pawY = 28 + yShift;
  if (pose === 'idle' || pose === 'sit-squash' || pose === 'sit-stretch') {
    // Two tiny front paws, symmetric
    rect(g, 12, pawY, 3, 2, P);
    rect(g, 17, pawY, 3, 2, P);
    hLine(g, 12, pawY + 1, 3, O);
    hLine(g, 17, pawY + 1, 3, O);
    px(g, 12, pawY, O);
    px(g, 14, pawY, O);
    px(g, 17, pawY, O);
    px(g, 19, pawY, O);
  } else if (pose === 'walkA') {
    // Right paw forward (lifted), left paw back
    rect(g, 11, pawY - 1, 3, 2, P);
    hLine(g, 11, pawY, 3, O);
    px(g, 11, pawY - 1, O);
    px(g, 13, pawY - 1, O);
    rect(g, 18, pawY, 3, 2, P);
    hLine(g, 18, pawY + 1, 3, O);
    px(g, 18, pawY, O);
    px(g, 20, pawY, O);
  } else if (pose === 'walkB') {
    // Left paw forward, right paw back
    rect(g, 11, pawY, 3, 2, P);
    hLine(g, 11, pawY + 1, 3, O);
    px(g, 11, pawY, O);
    px(g, 13, pawY, O);
    rect(g, 18, pawY - 1, 3, 2, P);
    hLine(g, 18, pawY, 3, O);
    px(g, 18, pawY - 1, O);
    px(g, 20, pawY - 1, O);
  } else if (pose === 'shrunk') {
    // Tucked paws
    rect(g, 13, pawY, 6, 1, P);
    hLine(g, 13, pawY + 1, 6, O);
  }

  // ----- Tail (2px wide, curled over the body) -----
  // The tail curls UP and OVER from the rear-right of the body.
  // Cats hold their tail like a question mark when content.
  // All tail coordinates respect the body's yShift so the tail moves with
  // the body during hop/squash animations.
  const ys = yShift;
  const fillPx = (x, y) => px(g, x, y + ys, P);
  const outPx  = (x, y) => px(g, x, y + ys, O);
  const blushPx = (x, y) => px(g, x, y + ys, B);
  if (tail === 'curl') {
    // Question-mark curl rising from rear of body up over the back
    const spine = [
      [22, 26], [23, 25], [24, 24], [25, 23],
      [25, 22], [25, 21], [25, 20], [24, 19],
    ];
    // Fill — adjacent primary pixels for 2px width
    const fill = [
      [22, 25], [23, 24], [24, 23], [24, 22],
      [24, 21], [24, 20], [23, 19],
    ];
    for (const [x, y] of fill) fillPx(x, y);
    for (const [x, y] of spine) outPx(x, y);
    // Tip — pink with outline anchor
    blushPx(23, 18);
    outPx(23, 19); // already drawn but ensures continuity
  } else if (tail === 'up') {
    // Straight-up alert tail (excited) — 2px wide column with pink tip
    for (let y = 16; y < 25; y++) fillPx(24, y);
    for (let y = 16; y < 25; y++) outPx(25, y);
    blushPx(24, 15);
  } else if (tail === 'wagL') {
    const spine = [
      [22, 26], [23, 25], [24, 24], [25, 23],
      [26, 22], [26, 21], [25, 20], [24, 19],
    ];
    const fill = [
      [22, 25], [23, 24], [24, 23], [25, 22],
      [25, 21], [24, 20], [23, 19],
    ];
    for (const [x, y] of fill) fillPx(x, y);
    for (const [x, y] of spine) outPx(x, y);
    blushPx(23, 18);
  } else if (tail === 'wagR') {
    const spine = [
      [22, 26], [23, 26], [24, 25], [25, 25],
      [26, 24], [27, 23], [27, 22], [26, 21],
    ];
    const fill = [
      [22, 25], [23, 25], [24, 24], [25, 24],
      [26, 23], [26, 22], [25, 21],
    ];
    for (const [x, y] of fill) fillPx(x, y);
    for (const [x, y] of spine) outPx(x, y);
    blushPx(26, 20);
  } else if (tail === 'tucked') {
    // Tucked under — barely visible stub
    fillPx(22, 27);
    outPx(23, 27);
    outPx(22, 26);
  }
}

// =====================================================================
// Frame composition
// =====================================================================

function frame({
  faceMode = 'open',
  mouth = 'small',
  earTilt = 0,
  ears = 'up',
  blushBoost = false,
  whiskers = true,
  pose = 'idle',
  tail = 'curl',
  headYShift = 0,
  bodyYShift = 0,
}) {
  const headG = paintBaseHead({ earTilt, ears });
  paintFace(headG, faceMode, { mouth, blushBoost, whiskers });

  // Apply head Y-shift
  let g = headG;
  if (headYShift !== 0) {
    g = blank();
    for (let y = 0; y < SIZE; y++) {
      const srcY = y - headYShift;
      if (srcY < 0 || srcY >= SIZE) continue;
      for (let x = 0; x < SIZE; x++) {
        if (headG[srcY][x] !== T) g[y][x] = headG[srcY][x];
      }
    }
  }

  paintBody(g, { pose, tail, yShift: bodyYShift });
  return g;
}

// =====================================================================
// Action definitions — 5 actions, paint them all
// =====================================================================

const idle = [
  // 0: standard pose, tail curled
  frame({ faceMode: 'open', mouth: 'small', tail: 'curl' }),
  // 1: subtle breath rise — head 1px up
  frame({ faceMode: 'open', mouth: 'small', tail: 'curl', headYShift: -1 }),
  // 2: blink
  frame({ faceMode: 'blink', mouth: 'small', tail: 'curl' }),
  // 3: standard echo
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
  // Hop frame: whole body 2px up, ears tilted, tail straight up
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
  // Squashed — wide eyes, surprised
  frame({
    faceMode: 'wide',
    mouth: 'open',
    pose: 'sit-squash',
    tail: 'curl',
    bodyYShift: 1,
    headYShift: 1,
  }),
  // Stretched + cheek blush boost — recovered
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
  // Wide eyes, ears flat, tail tucked — frame 0
  frame({
    faceMode: 'wide',
    mouth: 'frown',
    earTilt: -1,
    ears: 'flat',
    pose: 'idle',
    tail: 'tucked',
  }),
  // Body shrunk, even smaller — frame 1
  frame({
    faceMode: 'wide',
    mouth: 'frown',
    earTilt: -1,
    ears: 'flat',
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
    eyeAnchor: { x: 16, y: 9 },
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
palettes.default = {
  '0': 'transparent',
  '1': '#3A2418', // outline (warm dark brown)
  '2': '#F4A041', // primary (saturated orange)
  '3': '#FFE0B5', // secondary (cream)
  '4': '#FFFFFF', // highlight (pure white)
  '5': '#1F1F2E', // eye fill (deep blue-black)
  '6': '#D67B26', // pattern (warm darker orange — stripes / whiskers)
  '7': '#FF8FAA', // blush (v1 extension)
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
console.log(`Updated ${path.relative(process.cwd(), palettesPath)} with index 7 blush.`);
