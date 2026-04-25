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
