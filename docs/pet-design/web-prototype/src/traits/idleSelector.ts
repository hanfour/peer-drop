import type { Traits } from './types';

export type IdleAction = 'idle' | 'walking' | 'sleeping' | 'happy';

/**
 * Pick a weighted-random idle action based on personality traits.
 *
 * Curious → biases toward `walking`. Timid → biases toward `idle`.
 * Independent → mild bias toward `sleeping`. Mischievous → adds to `walking`.
 */
export function selectIdleAction(traits: Traits): IdleAction {
  const w: Record<IdleAction, number> = {
    idle: 30 + traits.timid * 0.3 - traits.curious * 0.1,
    walking: 20 + traits.curious * 0.4 + traits.mischievous * 0.2,
    sleeping: 10 + traits.independent * 0.1,
    happy: 5 + traits.curious * 0.05,
  };
  // Floor any negative weights at 0
  for (const k in w) {
    if (w[k as IdleAction] < 0) w[k as IdleAction] = 0;
  }
  const total = Object.values(w).reduce((a, b) => a + b, 0);
  let r = Math.random() * total;
  for (const k in w) {
    r -= w[k as IdleAction];
    if (r <= 0) return k as IdleAction;
  }
  return 'idle';
}
