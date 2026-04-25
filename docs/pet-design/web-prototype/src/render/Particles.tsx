import { useEffect, useState } from 'react';

export type Particle = {
  id: number;
  /** Stage-relative pixel coordinates. */
  x: number;
  y: number;
  /** Pixels per second. */
  vx: number;
  vy: number;
  /** Single grapheme drawn for the particle (emoji or symbol). */
  emoji: string;
  /** performance.now() timestamp when the particle was emitted. */
  bornAt: number;
  /** Lifespan in ms; the particle disappears after this. */
  lifeMs: number;
};

/**
 * Renders a list of physics-lite particles overlaid inside the stage.
 * Each particle drifts with its initial velocity, accelerates downward
 * via a simple gravity term, and fades linearly over its lifespan.
 *
 * Owns a single rAF loop while mounted (one render-tick per frame); the
 * caller manages the underlying particle list.
 */
export function Particles({ particles }: { particles: Particle[] }) {
  const [now, setNow] = useState(performance.now());
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
        return (
          <div
            key={p.id}
            style={{
              position: 'absolute',
              left: x,
              top: y,
              opacity,
              fontSize: 18,
              pointerEvents: 'none',
              transform: 'translate(-50%, -50%)',
            }}
          >
            {p.emoji}
          </div>
        );
      })}
    </>
  );
}
