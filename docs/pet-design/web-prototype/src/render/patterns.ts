/**
 * Pattern overlay system for v3 prototype sprites (48×48).
 *
 * Production app encodes per-species body-region masks in
 * `PatternSpriteData.swift` so a stripe/spot mask can be intersected with
 * the body. For our prototype we don't have per-species masks, so we use
 * a simpler runtime overlay rule:
 *
 *   IF the source pixel currently uses palette index 2 (primary colour)
 *   AND `pattern.shouldOverlay(x, y, seed)` is true,
 *   THEN render that pixel with palette index 6 (pattern colour) instead.
 *
 * This means patterns only take effect on the body (where primary lives),
 * never on the outline / eyes / shading. Works automatically for all 10
 * species without authoring per-species masks. Coordinates are in the
 * SOURCE frame's coordinate space — the renderer is responsible for
 * passing source-space (x, y) when the sprite is flipped, so the pattern
 * stays consistent regardless of facing direction.
 *
 * SEED-DRIVEN VARIATION
 * ---------------------
 * Every pattern (except `plain`) reads a numeric `seed` so the same
 * pattern category produces a *different layout* for each individual
 * pet. Stripe gets organic curves with varied amplitude/frequency/phase;
 * spot uses Poisson-disk-like scatter; two-tone varies its split angle
 * and ratio; star picks one of several body anchor points and shape
 * variants. Pure functions: same (x, y, seed) → same boolean.
 */

export type PatternId = 'plain' | 'stripe' | 'spot' | 'two-tone' | 'star';

export type Pattern = {
  /** Stable id used for picker state. */
  id: PatternId;
  /** User-facing label (繁體中文). */
  label: string;
  /**
   * Decide whether the given source-space pixel should be recoloured
   * to the palette's pattern slot (index 6). Only fires when the pixel
   * is currently the primary slot (index 2). `seed` is a 32-bit
   * unsigned int that selects one of many possible per-pet layouts
   * within this pattern category.
   */
  shouldOverlay: (x: number, y: number, seed: number) => boolean;
};

// ---------------------------------------------------------------------------
// PRNG: mulberry32 — small, fast, deterministic 32-bit hash. We use it both
// as a keyed PRNG (call repeatedly for a stream) and as a pure mixing hash
// (one call) when we just need a stable real in [0, 1) from a (seed, salt).
// ---------------------------------------------------------------------------

function mulberry32(seed: number): () => number {
  let s = seed >>> 0;
  return function () {
    s = (s + 0x6d2b79f5) >>> 0;
    let t = s;
    t = Math.imul(t ^ (t >>> 15), t | 1);
    t ^= t + Math.imul(t ^ (t >>> 7), t | 61);
    return ((t ^ (t >>> 14)) >>> 0) / 4294967296;
  };
}

/** Stable scalar in [0, 1) from a (seed, salt) pair — pure mixing. */
function hash01(seed: number, salt: number): number {
  let t = ((seed >>> 0) ^ Math.imul(salt | 0, 0x9e3779b1)) >>> 0;
  t = Math.imul(t ^ (t >>> 15), t | 1);
  t ^= t + Math.imul(t ^ (t >>> 7), t | 61);
  return ((t ^ (t >>> 14)) >>> 0) / 4294967296;
}

/** Map [0, 1) into [min, max) (continuous). */
function lerp(t: number, min: number, max: number): number {
  return min + t * (max - min);
}

/** Map [0, 1) into one of `n` discrete buckets. */
function bucket(t: number, n: number): number {
  return Math.min(n - 1, Math.floor(t * n));
}

// ---------------------------------------------------------------------------
// Stripe — sin-modulated horizontal bands. Each pet picks its own
// amplitude / frequency / phase / period so the stripes range from
// near-flat (zebra-like) to clearly wavy (tabby-like).
// ---------------------------------------------------------------------------

type StripeParams = {
  amp: number;     // vertical wave amplitude (px)
  freq: number;    // horizontal sin frequency (radians/px)
  phase: number;   // sin phase offset
  period: number;  // band thickness (px)
};

const stripeParamsCache = new Map<number, StripeParams>();

function getStripeParams(seed: number): StripeParams {
  const cached = stripeParamsCache.get(seed);
  if (cached) return cached;
  const r = mulberry32(seed ^ 0x517cc1b7);
  const params: StripeParams = {
    amp: lerp(r(), 1, 4),
    freq: lerp(r(), 0.15, 0.4),
    phase: lerp(r(), 0, Math.PI * 2),
    period: lerp(r(), 3, 5),
  };
  stripeParamsCache.set(seed, params);
  return params;
}

function stripeOverlay(x: number, y: number, seed: number): boolean {
  const { amp, freq, phase, period } = getStripeParams(seed);
  const wavyY = y + amp * Math.sin((x + phase) * freq);
  return Math.floor(wavyY / period) % 2 === 0;
}

// ---------------------------------------------------------------------------
// Spot — Poisson-disk-like scatter on a 48×48 frame. Spots vary in count
// (5..12), position, and radius (1..3). Cached per seed so the spot list
// is computed once per pet, not per pixel.
// ---------------------------------------------------------------------------

type Spot = { cx: number; cy: number; r2: number };

const spotListCache = new Map<number, Spot[]>();

function getSpots(seed: number): Spot[] {
  const cached = spotListCache.get(seed);
  if (cached) return cached;
  const r = mulberry32(seed ^ 0x2c1b3aed);
  const target = 6 + Math.floor(r() * 7); // 6..12
  const minDist = 7; // px between spot centres (squared check below)
  const minDist2 = minDist * minDist;
  const spots: Spot[] = [];
  // Try up to 80 candidates to fill `target` spots without overlap.
  for (let attempt = 0; attempt < 80 && spots.length < target; attempt++) {
    const cx = Math.floor(r() * 48);
    const cy = Math.floor(r() * 48);
    let ok = true;
    for (const s of spots) {
      const dx = cx - s.cx;
      const dy = cy - s.cy;
      if (dx * dx + dy * dy < minDist2) {
        ok = false;
        break;
      }
    }
    if (!ok) continue;
    // Radius bucket: 60% small (1), 30% mid (2), 10% large (3).
    const rt = r();
    const rad = rt < 0.6 ? 1 : rt < 0.9 ? 2 : 3;
    spots.push({ cx, cy, r2: rad * rad });
  }
  spotListCache.set(seed, spots);
  return spots;
}

function spotOverlay(x: number, y: number, seed: number): boolean {
  const spots = getSpots(seed);
  for (let i = 0; i < spots.length; i++) {
    const s = spots[i];
    const dx = x - s.cx;
    const dy = y - s.cy;
    if (dx * dx + dy * dy <= s.r2) return true;
  }
  return false;
}

// ---------------------------------------------------------------------------
// Two-tone — split the body along a line. Six variants: bottom/top half,
// left/right half, diagonal up-right, diagonal up-left. Split ratio
// varies in 0.3..0.7 so the band is sometimes generous, sometimes thin.
// ---------------------------------------------------------------------------

type TwoToneParams = {
  variant: 0 | 1 | 2 | 3 | 4 | 5;
  ratio: number; // 0.3..0.7
};

const twoToneParamsCache = new Map<number, TwoToneParams>();

function getTwoToneParams(seed: number): TwoToneParams {
  const cached = twoToneParamsCache.get(seed);
  if (cached) return cached;
  const variant = bucket(hash01(seed, 0xa1), 6) as TwoToneParams['variant'];
  const ratio = lerp(hash01(seed, 0xa2), 0.3, 0.7);
  const params: TwoToneParams = { variant, ratio };
  twoToneParamsCache.set(seed, params);
  return params;
}

function twoToneOverlay(x: number, y: number, seed: number): boolean {
  const { variant, ratio } = getTwoToneParams(seed);
  const SIZE = 48;
  switch (variant) {
    case 0: // bottom half
      return y > SIZE * ratio;
    case 1: // top half
      return y < SIZE * ratio;
    case 2: // right half
      return x > SIZE * ratio;
    case 3: // left half
      return x < SIZE * ratio;
    case 4: {
      // diagonal up-right: pixel below the line y = -x + (SIZE * ratio * 2)
      // ratio shifts the intercept up/down.
      const intercept = SIZE * (0.5 + (ratio - 0.5) * 0.6) * 2;
      return x + y > intercept;
    }
    case 5: {
      // diagonal up-left: pixel below the line y = x + (offset)
      const offset = SIZE * (ratio - 0.5) * 1.2;
      return y - x > offset;
    }
  }
}

// ---------------------------------------------------------------------------
// Star — single small emblem. Position is one of 6 candidate anchors
// (chest, forehead, hip, back, side, lower-side); shape is one of 4
// (plus, cross, dot-cluster, heart). Both vary by seed.
// ---------------------------------------------------------------------------

type StarShape = 'plus' | 'cross' | 'dotCluster' | 'heart';
type StarParams = {
  anchorX: number;
  anchorY: number;
  shape: StarShape;
};

// Six body-region anchors, calibrated for 48×48 frames. Some species
// won't have primary pixels in every position; that's intentional (same
// constraint as before — see plan §6).
const STAR_ANCHORS: ReadonlyArray<{ x: number; y: number }> = [
  { x: 24, y: 28 }, // chest
  { x: 24, y: 18 }, // forehead
  { x: 30, y: 30 }, // hip
  { x: 18, y: 22 }, // back
  { x: 14, y: 28 }, // side-left
  { x: 32, y: 26 }, // side-right
];

const starParamsCache = new Map<number, StarParams>();

function getStarParams(seed: number): StarParams {
  const cached = starParamsCache.get(seed);
  if (cached) return cached;
  const anchorIdx = bucket(hash01(seed, 0xb1), STAR_ANCHORS.length);
  const anchor = STAR_ANCHORS[anchorIdx];
  const shapeIdx = bucket(hash01(seed, 0xb2), 4);
  const shapes: StarShape[] = ['plus', 'cross', 'dotCluster', 'heart'];
  const params: StarParams = {
    anchorX: anchor.x,
    anchorY: anchor.y,
    shape: shapes[shapeIdx],
  };
  starParamsCache.set(seed, params);
  return params;
}

function starOverlay(x: number, y: number, seed: number): boolean {
  const { anchorX, anchorY, shape } = getStarParams(seed);
  const dx = x - anchorX;
  const dy = y - anchorY;
  switch (shape) {
    case 'plus': {
      // 3×3 plus-sign centred on (anchorX, anchorY)
      // (0,-1)(0,0)(0,1) and (-1,0)(1,0)
      return (dx === 0 && Math.abs(dy) <= 1) || (dy === 0 && Math.abs(dx) <= 1);
    }
    case 'cross': {
      // 3×3 X-shape: corners + centre
      return (Math.abs(dx) === 1 && Math.abs(dy) === 1) || (dx === 0 && dy === 0);
    }
    case 'dotCluster': {
      // 5-pointed pixel star (the legacy emblem) — kept as one of the
      // shape variants so seeds that pick it look like the original.
      return (
        (dx === 0 && dy === -2) ||
        (dx === -1 && dy === -1) || (dx === 1 && dy === -1) ||
        (dx === -2 && dy === 0) || (dx === 0 && dy === 0) || (dx === 2 && dy === 0) ||
        (dx === -1 && dy === 1) || (dx === 1 && dy === 1)
      );
    }
    case 'heart': {
      // 5×4 pixel heart, centred on the anchor (slightly offset down).
      // Pattern (ax, ay) where ay 0..3, ax -2..2:
      //   . # . # .
      //   # # # # #
      //   . # # # .
      //   . . # . .
      const ay = dy + 1; // shift so anchor sits in upper-middle of the heart
      const ax = dx;
      if (ay === 0) return ax === -1 || ax === 1;
      if (ay === 1) return ax >= -2 && ax <= 2;
      if (ay === 2) return ax >= -1 && ax <= 1;
      if (ay === 3) return ax === 0;
      return false;
    }
  }
}

// ---------------------------------------------------------------------------
// Public registry.
// ---------------------------------------------------------------------------

export const PATTERNS: Pattern[] = [
  {
    id: 'plain',
    label: '無花紋',
    shouldOverlay: () => false,
  },
  {
    id: 'stripe',
    label: '條紋',
    shouldOverlay: stripeOverlay,
  },
  {
    id: 'spot',
    label: '斑點',
    shouldOverlay: spotOverlay,
  },
  {
    id: 'two-tone',
    label: '雙色',
    shouldOverlay: twoToneOverlay,
  },
  {
    id: 'star',
    label: '星印',
    shouldOverlay: starOverlay,
  },
];

/** Look up a Pattern by id; falls back to 'plain' if unknown. */
export function findPattern(id: string): Pattern {
  return PATTERNS.find((p) => p.id === id) ?? PATTERNS[0];
}

/** Stable seed used for the pattern picker preview thumbnails so they
 *  don't shimmer when the user clicks 🔀. The live stage uses the
 *  active pet's seed. */
export const PREVIEW_SEED = 12345;
