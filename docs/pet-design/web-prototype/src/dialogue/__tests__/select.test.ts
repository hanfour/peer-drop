import { test, expect } from 'vitest';
import { selectLine } from '../select';
import type { Traits } from '../../traits/types';

test('high mischievous biases tap toward "heh."', () => {
  const traits: Traits = { independent: 0, curious: 0, timid: 0, mischievous: 100 };
  const samples = Array.from({ length: 200 }, () => selectLine(traits, 'tap')?.text);
  expect(samples.filter((t) => t === 'heh.').length).toBeGreaterThan(80);
});

test('high timid biases idle toward ellipses or quiet observations', () => {
  const traits: Traits = { independent: 0, curious: 0, timid: 100, mischievous: 0 };
  const samples = Array.from({ length: 200 }, () => selectLine(traits, 'idle')?.text);
  // either '...' or 'zZz' should dominate
  const quiet = samples.filter((t) => t === '...' || t === 'zZz').length;
  expect(quiet).toBeGreaterThan(80);
});

test('every context yields a valid line for default traits', () => {
  const traits: Traits = { independent: 50, curious: 50, timid: 50, mischievous: 50 };
  for (const ctx of [
    'idle',
    'greeting',
    'tap',
    'transferSuccess',
    'transferFail',
  ] as const) {
    const l = selectLine(traits, ctx);
    expect(l).not.toBeNull();
    expect(l!.context).toBe(ctx);
  }
});
