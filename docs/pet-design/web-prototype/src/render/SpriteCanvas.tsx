import { useRef, useEffect } from 'react';
import type { Frame, Palette } from '../sprite/types';
import type { Pattern } from './patterns';

type Props = {
  frame: Frame;
  palette: Palette;
  scale?: number;
  flipped?: boolean;
  /**
   * Optional pattern overlay. When provided, source-space pixels that
   * currently render with palette slot 2 (primary) AND for which the
   * pattern's `getOverlayIndex(x, y, seed)` returns a non-null slot
   * (3/4/5/6) are re-mapped to that slot's colour. All other pixels
   * render normally.
   *
   * The pattern coordinate is always the SOURCE frame's (x, y) — even
   * when `flipped` is true — so the pattern stays visually consistent
   * regardless of which direction the sprite is facing.
   */
  pattern?: Pattern;
  /**
   * Per-pet seed feeding the pattern's PRNG. Same seed → same layout
   * across renders; different seeds → distinctive layouts within the
   * same pattern category (organic-stripe variations, scattered spots,
   * etc.). Defaults to 0 when omitted.
   */
  seed?: number;
};

export function SpriteCanvas({
  frame,
  palette,
  scale = 8,
  flipped = false,
  pattern,
  seed = 0,
}: Props) {
  const ref = useRef<HTMLCanvasElement>(null);

  useEffect(() => {
    const c = ref.current;
    if (!c) return;
    const ctx = c.getContext('2d');
    if (!ctx) return;
    if (!frame || frame.length === 0) {
      ctx.clearRect(0, 0, c.width, c.height);
      return;
    }
    ctx.imageSmoothingEnabled = false;
    ctx.clearRect(0, 0, c.width, c.height);
    ctx.save();
    if (flipped) {
      ctx.translate(c.width, 0);
      ctx.scale(-1, 1);
    }
    for (let y = 0; y < frame.length; y++) {
      const row = frame[y];
      for (let x = 0; x < row.length; x++) {
        const idx = row[x];
        if (idx === 0) continue;
        // Pattern overlay: recolour primary (slot 2) pixels to one of
        // the overlay slots (3/4/5/6) chosen by the pattern. The slot
        // and which palette entries fill it are decided per-seed inside
        // the pattern (see patterns.ts). Coordinates passed are SOURCE-
        // frame coords — we're inside the (possibly mirrored) ctx, but
        // `x`/`y` are read directly from `frame` so they're already
        // source-space.
        let drawIdx = idx;
        if (pattern && idx === 2) {
          const overlayIdx = pattern.getOverlayIndex(x, y, seed);
          if (overlayIdx !== null) {
            const overlayColor = palette[String(overlayIdx)];
            // Only swap if the slot exists and is non-transparent.
            // Otherwise fall back to primary so we never punch a
            // transparent hole through the body.
            if (overlayColor && overlayColor !== 'transparent') {
              drawIdx = overlayIdx;
            }
          }
        }
        const color = palette[String(drawIdx)];
        if (!color || color === 'transparent') continue;
        ctx.fillStyle = color;
        ctx.fillRect(x * scale, y * scale, scale, scale);
      }
    }
    ctx.restore();

    // Rim light pass — drawn in WORLD coordinates (after restore) so the
    // highlight always lands on the world-right edge of the sprite, even
    // when the sprite itself is mirrored via `flipped`.
    ctx.fillStyle = 'rgba(255,255,255,0.32)';
    const width = frame[0]?.length ?? 0;
    for (let y = 0; y < frame.length; y++) {
      const row = frame[y];
      if (!flipped) {
        let rightmost = -1;
        for (let x = row.length - 1; x >= 0; x--) {
          if (row[x] !== 0) {
            rightmost = x;
            break;
          }
        }
        if (rightmost >= 0) {
          ctx.fillRect(rightmost * scale, y * scale, scale, scale);
        }
      } else {
        // For flipped sprites: the world-right edge is the source-frame's
        // leftmost non-transparent pixel, mapped via (width - 1 - leftmost).
        let leftmost = -1;
        for (let x = 0; x < row.length; x++) {
          if (row[x] !== 0) {
            leftmost = x;
            break;
          }
        }
        if (leftmost >= 0) {
          const worldX = width - 1 - leftmost;
          ctx.fillRect(worldX * scale, y * scale, scale, scale);
        }
      }
    }
  }, [frame, palette, scale, flipped, pattern, seed]);

  // Frame is square; derive size from frame data. For empty/missing
  // frames the canvas collapses to 0×0 — caller is expected to gate on
  // `frames.length`, but we tolerate it defensively here.
  const size = frame?.length ?? 0;

  return (
    <canvas
      ref={ref}
      width={size * scale}
      height={size * scale}
      style={{ imageRendering: 'pixelated' }}
    />
  );
}
