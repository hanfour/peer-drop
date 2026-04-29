import { test, expect } from 'vitest';
import { selectIdleAction } from '../idleSelector';
import type { Traits } from '../types';

test('high curious selects walking more often than baseline', () => {
  const traits: Traits = { independent: 0, curious: 90, timid: 0, mischievous: 0 };
  const samples = Array.from({ length: 500 }, () => selectIdleAction(traits));
  const walkRatio = samples.filter((a) => a === 'walking').length / 500;
  expect(walkRatio).toBeGreaterThan(0.4);
});

test('high timid biases toward idle', () => {
  const traits: Traits = { independent: 0, curious: 0, timid: 90, mischievous: 0 };
  const samples = Array.from({ length: 500 }, () => selectIdleAction(traits));
  const idleRatio = samples.filter((a) => a === 'idle').length / 500;
  expect(idleRatio).toBeGreaterThan(0.5);
});

test('default traits produce a mix (no single action > 60%)', () => {
  const traits: Traits = {
    independent: 50,
    curious: 50,
    timid: 50,
    mischievous: 50,
  };
  const samples = Array.from({ length: 500 }, () => selectIdleAction(traits));
  const counts = new Map<string, number>();
  for (const a of samples) counts.set(a, (counts.get(a) ?? 0) + 1);
  for (const [, c] of counts) {
    expect(c / 500).toBeLessThan(0.6);
  }
});
