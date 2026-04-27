import { useEffect, useState, type ReactNode } from 'react';
import { SpriteCanvas } from '../render/SpriteCanvas';
import { DialogueBubble } from '../dialogue/DialogueBubble';
import type { Pattern } from '../render/patterns';
import type { Frame, Palette } from '../sprite/types';

export type StagePet = {
  id: string;
  frame: Frame;
  palette: Palette;
  scale?: number;
  flipped?: boolean;
  /** Horizontal position on the stage, 0..100 (clamped is the caller's job). */
  xPercent: number;
  onClick?: () => void;
  /** Optional pattern overlay applied at render time. */
  pattern?: Pattern;
  /** Per-pet seed feeding the pattern's PRNG (stable identity). */
  seed?: number;
};

const STAGE_W = 480;
const STAGE_H = 240;

/**
 * Pixel-art stage scene: sky gradient, drifting clouds, a soft sun,
 * horizon line, grass tufts. Hosts any number of pets at trait-driven
 * horizontal positions, plus an optional progress bar and overlay slot.
 *
 * Performance: clouds and sun are inline SVG with CSS-driven motion;
 * grass is a single <svg> repeated via background-image. No JS animation
 * loop is needed at the stage level — the parent owns the rAF loop for
 * particles & frame anims.
 */
export function PetStage({
  pets,
  accentColor = 'rgba(220, 220, 230, 0.0)',
  progressBar,
  overlay,
  dialogueByPet,
}: {
  pets: StagePet[];
  accentColor?: string;
  progressBar?: ReactNode;
  overlay?: ReactNode;
  /** Map of pet id → current bubble text. Pets without a key get no bubble. */
  dialogueByPet?: Record<string, string>;
}) {
  const [bobY, setBobY] = useState(0);

  useEffect(() => {
    const id = setInterval(() => {
      setBobY((prev) => (prev === 0 ? -2 : 0));
    }, 1000);
    return () => clearInterval(id);
  }, []);

  return (
    <div
      style={{
        position: 'relative',
        width: STAGE_W,
        height: STAGE_H,
        // Sky gradient (light mode soft blue → cream); horizon at ~70%;
        // grass green band at the bottom.
        background:
          'linear-gradient(180deg, #B7E3F4 0%, #DDF2F8 40%, #F5F2D6 68%, #97D26A 70%, #6FB54A 100%)',
        borderRadius: 12,
        overflow: 'hidden',
        boxShadow:
          'inset 0 0 0 2px rgba(40, 32, 24, 0.18), 0 8px 24px rgba(40, 32, 24, 0.12)',
        imageRendering: 'pixelated',
      }}
    >
      {/* Dark-mode override via media query */}
      <style>{`
        @media (prefers-color-scheme: dark) {
          .pet-stage-scene {
            background: linear-gradient(180deg,
              #1B1B3A 0%,
              #2E2A55 40%,
              #4A3A66 68%,
              #2D5C2E 70%,
              #1F4521 100%) !important;
          }
        }
        @keyframes cloud-drift-slow {
          0%   { transform: translateX(-60px); }
          100% { transform: translateX(540px); }
        }
        @keyframes cloud-drift-mid {
          0%   { transform: translateX(-80px); }
          100% { transform: translateX(560px); }
        }
        @keyframes cloud-drift-fast {
          0%   { transform: translateX(-50px); }
          100% { transform: translateX(530px); }
        }
        @keyframes sun-pulse {
          0%, 100% { opacity: 0.95; }
          50%      { opacity: 1; }
        }
      `}</style>

      <div
        className="pet-stage-scene"
        style={{
          position: 'absolute',
          inset: 0,
          background: 'inherit',
          pointerEvents: 'none',
        }}
      />

      {/* Sun / moon — upper right. Pale yellow disc with halo. */}
      <Sun />

      {/* Drifting clouds. Z stacked above sky, below the horizon. */}
      <Cloud
        size={1}
        top={28}
        animationDuration="32s"
        animationName="cloud-drift-slow"
      />
      <Cloud
        size={0.7}
        top={56}
        animationDuration="22s"
        animationName="cloud-drift-mid"
        delay="-9s"
      />
      <Cloud
        size={0.85}
        top={86}
        animationDuration="40s"
        animationName="cloud-drift-fast"
        delay="-25s"
      />

      {/* Horizon line — subtle line where the sky meets the grass band. */}
      <div
        style={{
          position: 'absolute',
          left: 0,
          right: 0,
          top: '70%',
          height: 1,
          background: 'rgba(40, 32, 24, 0.18)',
        }}
      />

      {/* Grass tufts band — repeating pixel pattern stamped along the horizon */}
      <GrassTufts />

      {/* Pet sprites. */}
      {pets.map((p) => (
        <div
          key={p.id}
          onClick={p.onClick}
          style={{
            position: 'absolute',
            left: `${p.xPercent}%`,
            top: '60%',
            transform: `translate(-50%, ${bobY}px)`,
            transition:
              'transform 1s ease-in-out, left 1.5s cubic-bezier(0.22, 1, 0.36, 1)',
            cursor: p.onClick ? 'pointer' : 'default',
          }}
        >
          {/* Drop shadow per pet */}
          <div
            style={{
              position: 'absolute',
              left: '50%',
              top: '76%',
              transform: 'translateX(-50%)',
              width: 96,
              height: 14,
              background:
                'radial-gradient(ellipse at center, rgba(0,0,0,0.28), transparent 70%)',
              filter: 'blur(2px)',
              pointerEvents: 'none',
            }}
          />
          <SpriteCanvas
            frame={p.frame}
            palette={p.palette}
            scale={p.scale}
            flipped={p.flipped}
            pattern={p.pattern}
            seed={p.seed}
          />
          {dialogueByPet?.[p.id] && (
            <DialogueBubble key={dialogueByPet[p.id]} text={dialogueByPet[p.id]} />
          )}
        </div>
      ))}

      {/* Optional progress bar slot (rendered above pets, below mood overlay) */}
      {progressBar}
      {/* Optional overlay slot (e.g. particles) */}
      {overlay}
      {/* Mood accent overlay — softer in v1 so the scene isn't washed out. */}
      <div
        style={{
          position: 'absolute',
          inset: 0,
          background: `radial-gradient(circle at 70% 30%, ${accentColor}, transparent 75%)`,
          pointerEvents: 'none',
          mixBlendMode: 'soft-light',
        }}
      />
    </div>
  );
}

/** Pale sun disc with a soft halo. Pulses slowly. */
function Sun() {
  return (
    <div
      style={{
        position: 'absolute',
        top: 18,
        right: 22,
        width: 38,
        height: 38,
        borderRadius: '50%',
        background:
          'radial-gradient(circle at 38% 35%, #FFF7BC 0%, #FFE36B 50%, rgba(255, 220, 120, 0) 75%)',
        boxShadow: '0 0 18px rgba(255, 230, 130, 0.55)',
        animation: 'sun-pulse 6s ease-in-out infinite',
        pointerEvents: 'none',
      }}
    />
  );
}

/**
 * A small pixel cloud composed of stacked rounded chunks. Renders as a
 * pure DOM element with chunky white rectangles (no antialiasing), so it
 * reads as "pixel art cloud" rather than a smooth blur.
 */
function Cloud({
  size = 1,
  top,
  animationDuration,
  animationName,
  delay = '0s',
}: {
  size?: number;
  top: number;
  animationDuration: string;
  animationName: string;
  delay?: string;
}) {
  const w = 40 * size;
  const h = 16 * size;
  return (
    <div
      style={{
        position: 'absolute',
        top,
        left: 0,
        width: w,
        height: h,
        animation: `${animationName} ${animationDuration} linear infinite`,
        animationDelay: delay,
        pointerEvents: 'none',
      }}
    >
      {/* The cloud is a few rectangles offset so the silhouette has lumps. */}
      <div
        style={{
          position: 'absolute',
          top: h * 0.25,
          left: 0,
          width: w,
          height: h * 0.5,
          background: '#FFFFFF',
        }}
      />
      <div
        style={{
          position: 'absolute',
          top: 0,
          left: w * 0.2,
          width: w * 0.45,
          height: h * 0.65,
          background: '#FFFFFF',
        }}
      />
      <div
        style={{
          position: 'absolute',
          top: h * 0.1,
          left: w * 0.5,
          width: w * 0.4,
          height: h * 0.55,
          background: '#FFFFFF',
        }}
      />
      {/* Subtle 1px shadow underneath (cool gray) for depth */}
      <div
        style={{
          position: 'absolute',
          top: h * 0.7,
          left: w * 0.05,
          width: w * 0.9,
          height: h * 0.15,
          background: 'rgba(120, 140, 170, 0.35)',
        }}
      />
    </div>
  );
}

/** Repeating grass-blade tufts along the bottom of the stage. */
function GrassTufts() {
  // 16x8 tile: a few darker green tufts on a transparent background that
  // we overlay above the existing grass gradient. Encoded as inline SVG
  // and used as background-image (much smaller than per-blade DOM).
  const svg = encodeURIComponent(
    `<svg xmlns='http://www.w3.org/2000/svg' width='16' height='8' viewBox='0 0 16 8' shape-rendering='crispEdges'>
      <rect x='1' y='5' width='1' height='2' fill='#3F7C2A'/>
      <rect x='2' y='4' width='1' height='3' fill='#3F7C2A'/>
      <rect x='3' y='5' width='1' height='2' fill='#3F7C2A'/>
      <rect x='6' y='6' width='1' height='1' fill='#5BA240'/>
      <rect x='9' y='4' width='1' height='3' fill='#3F7C2A'/>
      <rect x='10' y='5' width='1' height='2' fill='#3F7C2A'/>
      <rect x='13' y='5' width='1' height='2' fill='#5BA240'/>
      <rect x='14' y='6' width='1' height='1' fill='#3F7C2A'/>
    </svg>`,
  );
  return (
    <div
      style={{
        position: 'absolute',
        left: 0,
        right: 0,
        top: 'calc(70% + 1px)',
        height: 24,
        backgroundImage: `url("data:image/svg+xml;utf8,${svg}")`,
        backgroundRepeat: 'repeat-x',
        backgroundSize: '32px 16px',
        imageRendering: 'pixelated',
        pointerEvents: 'none',
        opacity: 0.85,
      }}
    />
  );
}
