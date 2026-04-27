/**
 * Pattern overlay system for v3 prototype sprites (48×48).
 *
 * Production app encodes per-species body-region masks in
 * `PatternSpriteData.swift` so a stripe/spot mask can be intersected with
 * the body. For our prototype we don't have per-species masks, so we use
 * a simpler runtime overlay rule:
 *
 *   IF the source pixel currently uses palette index 2 (primary colour)
 *   AND `pattern.shouldOverlay(x, y)` is true,
 *   THEN render that pixel with palette index 6 (pattern colour) instead.
 *
 * This means patterns only take effect on the body (where primary lives),
 * never on the outline / eyes / shading. Works automatically for all 10
 * species without authoring per-species masks. Coordinates are in the
 * SOURCE frame's coordinate space — the renderer is responsible for
 * passing source-space (x, y) when the sprite is flipped, so the pattern
 * stays consistent regardless of facing direction.
 */
export type Pattern = {
  /** Stable id used for picker state. */
  id: string;
  /** User-facing label (繁體中文). */
  label: string;
  /**
   * Decide whether the given source-space pixel should be recoloured
   * to the palette's pattern slot (index 6). Only fires when the pixel
   * is currently the primary slot (index 2).
   */
  shouldOverlay: (x: number, y: number) => boolean;
};

export const PATTERNS: Pattern[] = [
  {
    id: 'plain',
    label: '無花紋',
    shouldOverlay: () => false,
  },
  {
    id: 'stripe',
    label: '條紋',
    // Horizontal bands every 3 rows: rows 0-2 striped, 3-5 plain, 6-8 striped, ...
    shouldOverlay: (_x, y) => Math.floor(y / 3) % 2 === 0,
  },
  {
    id: 'spot',
    label: '斑點',
    // 8×8 cells with a small (~2-pixel-radius) dot near each cell centre.
    // Produces tightly scattered spots that read clearly on a 48×48 body.
    shouldOverlay: (x, y) => {
      const cx = (x % 8) - 4;
      const cy = (y % 8) - 4;
      return cx * cx + cy * cy <= 2;
    },
  },
  {
    id: 'two-tone',
    label: '雙色',
    // Bottom half of the sprite is recoloured — reads as a "belly band"
    // for quadrupeds and as a "skirt" for upright species.
    shouldOverlay: (_x, y) => y > 24,
  },
  {
    id: 'star',
    label: '星印',
    // A single small 3×3 plus-shaped star roughly at chest height. Coords
    // chosen for 48×48 frames; species with no primary in this region
    // will simply not show the star (intentional — see plan §6).
    shouldOverlay: (x, y) => {
      // 5-pointed pixel star centred at (24, 28).
      return (
        (x === 24 && y === 26) ||
        (x === 23 && y === 27) || (x === 25 && y === 27) ||
        (x === 22 && y === 28) || (x === 24 && y === 28) || (x === 26 && y === 28) ||
        (x === 23 && y === 29) || (x === 25 && y === 29)
      );
    },
  },
];

/** Look up a Pattern by id; falls back to 'plain' if unknown. */
export function findPattern(id: string): Pattern {
  return PATTERNS.find((p) => p.id === id) ?? PATTERNS[0];
}
