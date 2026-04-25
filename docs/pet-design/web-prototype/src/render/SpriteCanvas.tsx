import { useRef, useEffect } from 'react';
import type { Frame, Palette } from '../sprite/types';

type Props = {
  frame: Frame;
  palette: Palette;
  scale?: number;
  flipped?: boolean;
};

export function SpriteCanvas({ frame, palette, scale = 8, flipped = false }: Props) {
  const ref = useRef<HTMLCanvasElement>(null);

  useEffect(() => {
    const c = ref.current;
    if (!c) return;
    const ctx = c.getContext('2d');
    if (!ctx) return;
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
        const color = palette[String(idx)];
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
  }, [frame, palette, scale, flipped]);

  return (
    <canvas
      ref={ref}
      width={16 * scale}
      height={16 * scale}
      style={{ imageRendering: 'pixelated' }}
    />
  );
}
