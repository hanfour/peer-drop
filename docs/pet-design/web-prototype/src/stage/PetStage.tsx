import { useEffect, useState, type ReactNode } from 'react';
import { SpriteCanvas } from '../render/SpriteCanvas';
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
};

/**
 * Glassmorphic stage with a soft gradient backdrop, a translucent ground
 * line, and a 1Hz "breath bob" applied to its children. Renders any number
 * of pets at trait-driven horizontal positions, plus an optional progress
 * bar and mood accent overlay.
 */
export function PetStage({
  pets,
  accentColor = 'rgba(220, 220, 230, 0.0)',
  progressBar,
  overlay,
}: {
  pets: StagePet[];
  accentColor?: string;
  progressBar?: ReactNode;
  overlay?: ReactNode;
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
        width: 480,
        height: 240,
        background: 'linear-gradient(180deg, #f5f5f7 60%, #d8d8dc 100%)',
        borderRadius: 12,
        overflow: 'hidden',
      }}
    >
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
                'radial-gradient(ellipse at center, rgba(0,0,0,0.22), transparent 70%)',
              filter: 'blur(2px)',
              pointerEvents: 'none',
            }}
          />
          <SpriteCanvas
            frame={p.frame}
            palette={p.palette}
            scale={p.scale}
            flipped={p.flipped}
          />
        </div>
      ))}
      {/* ground line */}
      <div
        style={{
          position: 'absolute',
          left: 0,
          right: 0,
          top: '78%',
          height: 1,
          background: 'rgba(0,0,0,0.06)',
        }}
      />
      {/* Optional progress bar slot (rendered above pets, below mood overlay) */}
      {progressBar}
      {/* Optional overlay slot (e.g. particles) */}
      {overlay}
      {/* Mood accent overlay */}
      <div
        style={{
          position: 'absolute',
          inset: 0,
          background: `radial-gradient(circle at 70% 30%, ${accentColor}, transparent 70%)`,
          pointerEvents: 'none',
        }}
      />
    </div>
  );
}
