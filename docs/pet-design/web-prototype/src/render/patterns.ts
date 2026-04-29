/**
 * Pattern overlay system for v3 prototype sprites (48×48).
 *
 * Production app encodes per-species body-region masks in
 * `PatternSpriteData.swift` so a stripe/spot mask can be intersected with
 * the body. For our prototype we don't have per-species masks, so we use
 * a simpler runtime overlay rule:
 *
 *   IF the source pixel currently uses palette index 2 (primary colour)
 *   AND `pattern.getOverlayIndex(x, y, seed)` returns a non-null index,
 *   THEN render that pixel with the returned palette slot instead.
 *
 * This means patterns only take effect on the body (where primary lives),
 * never on the outline / eyes / shading. Works automatically for all 10
 * species without authoring per-species masks. Coordinates are in the
 * SOURCE frame's coordinate space — the renderer is responsible for
 * passing source-space (x, y) when the sprite is flipped, so the pattern
 * stays consistent regardless of facing direction.
 *
 * MULTI-COLOUR LAYOUT
 * -------------------
 * Real animals rarely look like "primary + one accent". A calico cat has
 * three patches; a holstein cow alternates black and white; a tabby has
 * dark and light stripes. To match this, every non-plain pattern picks
 * a 1–3 slot subset from the pool {3, 4, 5, 6} per seed (Fisher–Yates
 * shuffle), and `getOverlayIndex` returns one of those slots (or null)
 * for every body pixel.
 *
 *   - plain     : 0 slots (always null)
 *   - stripe    : 2 slots (alternating bands)
 *   - spot      : 2–3 slots (each spot picks one)
 *   - two-tone  : 2 slots (one per side of split)
 *   - star      : 1–2 slots (emblem fill + optional outline)
 *
 * SEED-DRIVEN VARIATION
 * ---------------------
 * Every pattern (except `plain`) reads a numeric `seed` so the same
 * pattern category produces a *different layout* for each individual
 * pet. Stripe gets organic curves with varied amplitude/frequency/phase;
 * spot uses Poisson-disk-like scatter; two-tone varies its split angle
 * and ratio; star picks one of several body anchor points and shape
 * variants. Pure functions: same (x, y, seed) → same overlay index.
 */

export type PatternId = 'plain' | 'stripe' | 'spot' | 'two-tone' | 'star';

/** Palette slot index returned by an overlay (3 / 4 / 5 / 6). */
export type OverlayIndex = 3 | 4 | 5 | 6;

export type Pattern = {
  /** Stable id used for picker state. */
  id: PatternId;
  /** User-facing label (繁體中文). */
  label: string;
  /**
   * Decide whether the given source-space pixel should be recoloured
   * to one of the overlay palette slots. Returns 3/4/5/6 for an
   * overlay, or null for "leave as primary". Only fires when the pixel
   * is currently the primary slot (index 2). `seed` is a 32-bit
   * unsigned int that selects one of many possible per-pet layouts
   * within this pattern category — including which palette slots act
   * as the overlay colours.
   */
  getOverlayIndex: (x: number, y: number, seed: number) => OverlayIndex | null;
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

/**
 * Pick `count` palette slot indices from the overlay pool {3, 4, 5, 6}
 * via Fisher–Yates shuffle. Returned slots are unique per call. Uses
 * the supplied `rng` so the choice is seed-driven and stable for a
 * given (seed, salt) pair.
 */
function pickPaletteSlots(rng: () => number, count: number): OverlayIndex[] {
  const pool: OverlayIndex[] = [3, 4, 5, 6];
  for (let i = pool.length - 1; i > 0; i--) {
    const j = Math.floor(rng() * (i + 1));
    [pool[i], pool[j]] = [pool[j], pool[i]];
  }
  return pool.slice(0, count);
}

// ---------------------------------------------------------------------------
// Stripe — sin-modulated horizontal bands. Each pet picks its own
// amplitude / frequency / phase / period so the stripes range from
// near-flat (zebra-like) to clearly wavy (tabby-like). Two slots from
// {3,4,5,6} alternate per band, giving real two-colour stripes (e.g.
// dark + light tabby) instead of "primary + one accent".
// ---------------------------------------------------------------------------

type StripeParams = {
  amp: number;     // vertical wave amplitude (px)
  freq: number;    // horizontal sin frequency (radians/px)
  phase: number;   // sin phase offset
  period: number;  // band thickness (px)
  slots: [OverlayIndex, OverlayIndex];
};

const stripeParamsCache = new Map<number, StripeParams>();

function getStripeParams(seed: number): StripeParams {
  const cached = stripeParamsCache.get(seed);
  if (cached) return cached;
  const r = mulberry32(seed ^ 0x517cc1b7);
  const amp = lerp(r(), 1, 4);
  const freq = lerp(r(), 0.15, 0.4);
  const phase = lerp(r(), 0, Math.PI * 2);
  const period = lerp(r(), 3, 5);
  const picked = pickPaletteSlots(r, 2);
  const params: StripeParams = {
    amp,
    freq,
    phase,
    period,
    slots: [picked[0], picked[1]],
  };
  stripeParamsCache.set(seed, params);
  return params;
}

function stripeOverlay(x: number, y: number, seed: number): OverlayIndex | null {
  const { amp, freq, phase, period, slots } = getStripeParams(seed);
  const wavyY = y + amp * Math.sin((x + phase) * freq);
  const band = Math.floor(wavyY / period);
  // Both bands are overlay colours — there is no "primary fill" in
  // stripe. This is what produces the proper two-colour tabby look
  // instead of "single-stripe over primary".
  return slots[((band % 2) + 2) % 2];
}

// ---------------------------------------------------------------------------
// Spot — Poisson-disk-like scatter on a 48×48 frame. Spots vary in count
// (5..12), position, and radius (1..3). Cached per seed so the spot list
// is computed once per pet, not per pixel. Each spot independently picks
// one of 2–3 palette slots, producing calico-style multi-colour patches.
// ---------------------------------------------------------------------------

type Spot = {
  cx: number;
  cy: number;
  r2: number;
  slot: OverlayIndex;
};

type SpotParams = {
  spots: Spot[];
};

const spotParamsCache = new Map<number, SpotParams>();

function getSpotParams(seed: number): SpotParams {
  const cached = spotParamsCache.get(seed);
  if (cached) return cached;
  const r = mulberry32(seed ^ 0x2c1b3aed);
  // 60% of pets get 3-colour calico, 40% get 2-colour holstein/cow look.
  const slotCount = r() < 0.6 ? 3 : 2;
  const slots = pickPaletteSlots(r, slotCount);
  const target = 6 + Math.floor(r() * 7); // 6..12
  const minDist = 7; // px between spot centres (squared check below)
  const minDist2 = minDist * minDist;
  const spots: Spot[] = [];
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
    const rt = r();
    const rad = rt < 0.6 ? 1 : rt < 0.9 ? 2 : 3;
    // Each spot independently picks one of the chosen slots so a
    // 3-slot calico shows three colours scattered across the body.
    const slotIdx = Math.floor(r() * slots.length);
    spots.push({ cx, cy, r2: rad * rad, slot: slots[slotIdx] });
  }
  const params: SpotParams = { spots };
  spotParamsCache.set(seed, params);
  return params;
}

function spotOverlay(x: number, y: number, seed: number): OverlayIndex | null {
  const { spots } = getSpotParams(seed);
  for (let i = 0; i < spots.length; i++) {
    const s = spots[i];
    const dx = x - s.cx;
    const dy = y - s.cy;
    if (dx * dx + dy * dy <= s.r2) return s.slot;
  }
  return null;
}

// ---------------------------------------------------------------------------
// Two-tone — split the body along a line. Six variants: bottom/top half,
// left/right half, diagonal up-right, diagonal up-left. Split ratio
// varies in 0.3..0.7 so the band is sometimes generous, sometimes thin.
// Two slots are picked: one for the "above split" region, one for "below
// split" — both are overlay slots so the pet reads as a clear two-tone
// (holstein cow, panda, cookies-and-cream) rather than "primary + flap".
// ---------------------------------------------------------------------------

type TwoToneParams = {
  variant: 0 | 1 | 2 | 3 | 4 | 5;
  ratio: number; // 0.3..0.7
  slots: [OverlayIndex, OverlayIndex];
};

const twoToneParamsCache = new Map<number, TwoToneParams>();

function getTwoToneParams(seed: number): TwoToneParams {
  const cached = twoToneParamsCache.get(seed);
  if (cached) return cached;
  const r = mulberry32(seed ^ 0x4d3a92e1);
  const variant = bucket(r(), 6) as TwoToneParams['variant'];
  const ratio = lerp(r(), 0.3, 0.7);
  const picked = pickPaletteSlots(r, 2);
  const params: TwoToneParams = { variant, ratio, slots: [picked[0], picked[1]] };
  twoToneParamsCache.set(seed, params);
  return params;
}

/** Returns true if (x, y) is on the "below/right" side of the split. */
function twoToneBelowSplit(
  x: number,
  y: number,
  variant: TwoToneParams['variant'],
  ratio: number,
): boolean {
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

function twoToneOverlay(x: number, y: number, seed: number): OverlayIndex | null {
  const { variant, ratio, slots } = getTwoToneParams(seed);
  return twoToneBelowSplit(x, y, variant, ratio) ? slots[0] : slots[1];
}

// ---------------------------------------------------------------------------
// Star — single small emblem. Position is one of 6 candidate anchors
// (chest, forehead, hip, back, side, lower-side); shape is one of 4
// (plus, cross, dot-cluster, heart). Both vary by seed.
//
// 50% of seeds get a single-slot emblem (clean, classic mark). The
// other 50% get a 2-slot emblem with a fill colour and an outline
// colour, giving 3×3 plus / cross shapes a layered icon feel. The
// outline lives on the perimeter pixels of the shape; the inner pixel
// uses the fill slot.
// ---------------------------------------------------------------------------

type StarShape = 'plus' | 'cross' | 'dotCluster' | 'heart';
type StarParams = {
  anchorX: number;
  anchorY: number;
  shape: StarShape;
  /** [fillSlot] for single-colour, [fillSlot, outlineSlot] for two-colour. */
  slots: OverlayIndex[];
};

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
  const r = mulberry32(seed ^ 0x6f81b3a5);
  const anchorIdx = bucket(r(), STAR_ANCHORS.length);
  const anchor = STAR_ANCHORS[anchorIdx];
  const shapeIdx = bucket(r(), 4);
  const shapes: StarShape[] = ['plus', 'cross', 'dotCluster', 'heart'];
  // 50/50 between single-colour and layered (fill + outline).
  const slotCount = r() < 0.5 ? 1 : 2;
  const slots = pickPaletteSlots(r, slotCount);
  const params: StarParams = {
    anchorX: anchor.x,
    anchorY: anchor.y,
    shape: shapes[shapeIdx],
    slots,
  };
  starParamsCache.set(seed, params);
  return params;
}

/**
 * Returns the "ring layer" of the shape pixel relative to its anchor:
 *   0 = not part of the shape
 *   1 = inner pixel (centre, fill)
 *   2 = outer pixel (perimeter, outline)
 * For shapes without a clear inner/outer split (small dot-cluster, heart)
 * we treat the geometric "core" pixel as inner and the rest as outer so
 * the 2-slot variant still has visible layering.
 */
function starLayer(dx: number, dy: number, shape: StarShape): 0 | 1 | 2 {
  switch (shape) {
    case 'plus': {
      // Centre pixel = inner, four arms = outer.
      if (dx === 0 && dy === 0) return 1;
      if ((dx === 0 && Math.abs(dy) === 1) || (dy === 0 && Math.abs(dx) === 1)) return 2;
      return 0;
    }
    case 'cross': {
      // Centre pixel = inner, four diagonal corners = outer.
      if (dx === 0 && dy === 0) return 1;
      if (Math.abs(dx) === 1 && Math.abs(dy) === 1) return 2;
      return 0;
    }
    case 'dotCluster': {
      // 5-pointed pixel star. Centre + horizontal mid = inner spine,
      // outer arms = outline.
      if (dx === 0 && dy === 0) return 1;
      if (
        (dx === 0 && dy === -2) ||
        (dx === -1 && dy === -1) || (dx === 1 && dy === -1) ||
        (dx === -2 && dy === 0) || (dx === 2 && dy === 0) ||
        (dx === -1 && dy === 1) || (dx === 1 && dy === 1)
      ) {
        return 2;
      }
      return 0;
    }
    case 'heart': {
      // 5×4 pixel heart, anchor sits in upper-middle.
      const ay = dy + 1;
      const ax = dx;
      if (ay === 0) return ax === -1 || ax === 1 ? 2 : 0;
      if (ay === 1) {
        if (ax >= -2 && ax <= 2) {
          // The middle 3 of the wide row read as the heart's body (fill);
          // the two outer pixels read as the outline tips.
          return ax === -2 || ax === 2 ? 2 : 1;
        }
        return 0;
      }
      if (ay === 2) return ax >= -1 && ax <= 1 ? (ax === 0 ? 1 : 2) : 0;
      if (ay === 3) return ax === 0 ? 2 : 0;
      return 0;
    }
  }
}

function starOverlay(x: number, y: number, seed: number): OverlayIndex | null {
  const { anchorX, anchorY, shape, slots } = getStarParams(seed);
  const dx = x - anchorX;
  const dy = y - anchorY;
  const layer = starLayer(dx, dy, shape);
  if (layer === 0) return null;
  // Single-slot emblem: every shape pixel uses slots[0].
  if (slots.length === 1) return slots[0];
  // Two-slot emblem: inner = fill (slots[0]), outer = outline (slots[1]).
  return layer === 1 ? slots[0] : slots[1];
}

// ---------------------------------------------------------------------------
// Public registry.
// ---------------------------------------------------------------------------

export const PATTERNS: Pattern[] = [
  {
    id: 'plain',
    label: '無花紋',
    getOverlayIndex: () => null,
  },
  {
    id: 'stripe',
    label: '條紋',
    getOverlayIndex: stripeOverlay,
  },
  {
    id: 'spot',
    label: '斑點',
    getOverlayIndex: spotOverlay,
  },
  {
    id: 'two-tone',
    label: '雙色',
    getOverlayIndex: twoToneOverlay,
  },
  {
    id: 'star',
    label: '星印',
    getOverlayIndex: starOverlay,
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
