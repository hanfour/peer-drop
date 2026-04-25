import { useEffect, useRef, useState } from 'react';

export type TransferState = 'idle' | 'running' | 'success' | 'failed';

/**
 * Pixel-art progress bar centered inside the stage (between the two
 * pets). 2px black border, recessed inner shadow (white top / gray
 * bottom), solid flat fill — saturated blue while running/success,
 * saturated red on failure. A 1px white shimmer stripe sweeps across
 * the success path for life.
 */
export function ProgressBar({
  progress,
  state,
}: {
  progress: number;
  state: TransferState;
}) {
  if (state === 'idle') return null;
  const isFail = state === 'failed';
  const fillColor = isFail ? '#FF5566' : '#5599FF';
  const fillShade = isFail ? '#B43040' : '#3A6FCC';
  return (
    <div
      style={{
        position: 'absolute',
        left: '50%',
        top: '55%',
        transform: 'translate(-50%, -50%)',
        width: 160,
        height: 12,
        // 2px black outer border + recessed inner shadow.
        background: '#1A1410',
        border: '2px solid #1A1410',
        borderRadius: 0,
        boxShadow:
          'inset 0 1px 0 rgba(0,0,0,0.6), 0 2px 0 rgba(0,0,0,0.25)',
        pointerEvents: 'none',
        imageRendering: 'pixelated',
      }}
    >
      {/* Recessed inner well (lighter top / darker bottom slivers) */}
      <div
        style={{
          position: 'absolute',
          inset: 0,
          background: 'linear-gradient(180deg, #2A2018 0%, #100A06 100%)',
        }}
      />
      {/* Filled portion — flat top color + 1px darker shade at bottom */}
      <div
        style={{
          position: 'absolute',
          left: 0,
          top: 0,
          height: '100%',
          width: `${Math.min(100, Math.max(0, progress * 100))}%`,
          background: `linear-gradient(180deg, ${fillColor} 0%, ${fillColor} 60%, ${fillShade} 100%)`,
          transition: 'width 0.1s linear, background 0.3s ease',
          overflow: 'hidden',
        }}
      >
        {/* Shimmer stripe (only on running/success). 1px white stripe
            sweeping diagonally — gives the bar life. */}
        {!isFail && (
          <div
            style={{
              position: 'absolute',
              top: 0,
              left: 0,
              width: 24,
              height: '100%',
              background:
                'linear-gradient(90deg, transparent 0%, rgba(255,255,255,0.55) 50%, transparent 100%)',
              animation: 'progress-shimmer 1.4s linear infinite',
            }}
          />
        )}
      </div>
      <style>{`
        @keyframes progress-shimmer {
          0%   { transform: translateX(-30px); }
          100% { transform: translateX(160px); }
        }
      `}</style>
    </div>
  );
}

/**
 * Drives a transfer simulation. Calling `start('success')` ramps progress
 * 0 → 1 over `durationMs` ms; `start('fail')` ramps to 0.7 then halts.
 * After 2s in a terminal state we auto-reset to idle.
 *
 * The hook owns its own rAF loop and cancels it on unmount or restart.
 */
export function useTransfer(durationMs = 4000): {
  state: TransferState;
  progress: number;
  start: (mode?: 'success' | 'fail') => void;
} {
  const [state, setState] = useState<TransferState>('idle');
  const [progress, setProgress] = useState(0);
  const rafRef = useRef<number | null>(null);

  useEffect(() => {
    return () => {
      if (rafRef.current !== null) cancelAnimationFrame(rafRef.current);
    };
  }, []);

  const start = (mode: 'success' | 'fail' = 'success') => {
    if (rafRef.current !== null) cancelAnimationFrame(rafRef.current);
    setState('running');
    setProgress(0);
    const startTime = performance.now();
    const tick = () => {
      const elapsed = performance.now() - startTime;
      const p = Math.min(1, elapsed / durationMs);
      if (mode === 'fail') {
        const capped = Math.min(p, 0.7);
        setProgress(capped);
        if (capped >= 0.7) {
          setState('failed');
          rafRef.current = null;
          return;
        }
      } else {
        setProgress(p);
        if (p >= 1) {
          setState('success');
          rafRef.current = null;
          return;
        }
      }
      rafRef.current = requestAnimationFrame(tick);
    };
    rafRef.current = requestAnimationFrame(tick);
  };

  // Auto-reset 2s after entering a terminal state so the next transfer
  // run starts clean.
  useEffect(() => {
    if (state === 'success' || state === 'failed') {
      const id = setTimeout(() => {
        setState('idle');
        setProgress(0);
      }, 2000);
      return () => clearTimeout(id);
    }
  }, [state]);

  return { state, progress, start };
}
