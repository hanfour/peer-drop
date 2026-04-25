import { useEffect, useState } from 'react';

/**
 * Cycles through `0..totalFrames-1` at the given fps, returning the current
 * frame index. Returns 0 (and no-ops) for single-frame or zero-frame
 * animations.
 */
export function useFrameAnimation(totalFrames: number, fps = 6): number {
  const [frame, setFrame] = useState(0);
  useEffect(() => {
    if (totalFrames <= 1) {
      setFrame(0);
      return;
    }
    const id = setInterval(() => {
      setFrame((f) => (f + 1) % totalFrames);
    }, 1000 / fps);
    return () => clearInterval(id);
  }, [totalFrames, fps]);
  return frame;
}
