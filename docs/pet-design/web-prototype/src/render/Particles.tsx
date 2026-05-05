import { useEffect, useState } from 'react';
import { SpriteCanvas } from './SpriteCanvas';
import type { Frame, Palette } from '../sprite/types';

export type ParticleKind = 'heart' | 'question' | 'sparkle' | 'exclamation';

export type Particle = {
  id: number;
  /** Stage-relative pixel coordinates. */
  x: number;
  y: number;
  /** Pixels per second. */
  vx: number;
  vy: number;
  /**
   * What kind of pixel-sprite to render. v1 replaces the v0 emoji glyph
   * with hand-painted 8×8 sprites loaded from `/data/particles.json`.
   */
  kind: ParticleKind;
  /** performance.now() timestamp when the particle was emitted. */
  bornAt: number;
  /** Lifespan in ms; the particle disappears after this. */
  lifeMs: number;
};

type ParticleData = {
  size: number;
  palettes: Record<ParticleKind, Palette>;
  sprites: Record<ParticleKind, Frame[]>;
};

let particleDataCache: ParticleData | null = null;
let particleDataPromise: Promise<ParticleData> | null = null;

function loadParticleData(): Promise<ParticleData> {
  if (particleDataCache) return Promise.resolve(particleDataCache);
  if (particleDataPromise) return particleDataPromise;
  particleDataPromise = fetch('/data/particles.json')
    .then((r) => r.json())
    .then((data: ParticleData) => {
      particleDataCache = data;
      return data;
    });
  return particleDataPromise;
}

/**
 * Renders a list of physics-lite particles overlaid inside the stage.
 * Each particle drifts with its initial velocity, accelerates downward
 * via a simple gravity term, and fades linearly over its lifespan.
 *
 * v1: each particle is a hand-painted 8×8 pixel sprite (heart, question,
 * sparkle, exclamation) with 2 frames of pulse animation. Rendered via
 * the same SpriteCanvas used for the pet, at scale=4.
 */
export function Particles({ particles }: { particles: Particle[] }) {
  const [now, setNow] = useState(performance.now());
  const [data, setData] = useState<ParticleData | null>(particleDataCache);

  useEffect(() => {
    if (!data) {
      loadParticleData().then(setData).catch(console.error);
    }
  }, [data]);

  useEffect(() => {
    let raf = 0;
    const tick = () => {
      setNow(performance.now());
      raf = requestAnimationFrame(tick);
    };
    raf = requestAnimationFrame(tick);
    return () => cancelAnimationFrame(raf);
  }, []);
  return (
    <>
      {particles.map((p) => {
        const elapsed = now - p.bornAt;
        if (elapsed > p.lifeMs) return null;
        const t = elapsed / 1000;
        const x = p.x + p.vx * t;
        const y = p.y + p.vy * t + 60 * t * t; // gravity downward
        const opacity = Math.max(0, 1 - elapsed / p.lifeMs);
        // Pulse: alternate sprite frame every ~140ms.
        const sprites = data?.sprites[p.kind];
        const palette = data?.palettes[p.kind];
        const frames = sprites && sprites.length > 0 ? sprites : null;
        const frameIdx =
          frames && frames.length > 1
            ? Math.floor(elapsed / 140) % frames.length
            : 0;
        return (
          <div
            key={p.id}
            style={{
              position: 'absolute',
              left: x,
              top: y,
              opacity,
              pointerEvents: 'none',
              transform: 'translate(-50%, -50%)',
              imageRendering: 'pixelated',
            }}
          >
            {frames && palette ? (
              <SpriteCanvas frame={frames[frameIdx]} palette={palette} scale={4} />
            ) : null}
          </div>
        );
      })}
    </>
  );
}
