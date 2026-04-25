import { useEffect, useRef, useState } from 'react';

export type TransferState = 'idle' | 'running' | 'success' | 'failed';

/**
 * Centered progress bar drawn inside the stage (between the two pets).
 * Color shifts from blue → red when the transfer enters the `failed`
 * terminal state.
 */
export function ProgressBar({
  progress,
  state,
}: {
  progress: number;
  state: TransferState;
}) {
  if (state === 'idle') return null;
  const fillBackground =
    state === 'failed'
      ? 'linear-gradient(90deg, #FF7B7B, #FF5252)'
      : 'linear-gradient(90deg, #4FC3F7, #29B6F6)';
  return (
    <div
      style={{
        position: 'absolute',
        left: '50%',
        top: '46%',
        transform: 'translate(-50%, -50%)',
        width: 160,
        height: 8,
        background: 'rgba(0,0,0,0.08)',
        borderRadius: 4,
        overflow: 'hidden',
        pointerEvents: 'none',
      }}
    >
      <div
        style={{
          width: `${Math.min(100, Math.max(0, progress * 100))}%`,
          height: '100%',
          background: fillBackground,
          transition: 'width 0.1s linear, background 0.3s ease',
        }}
      />
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
