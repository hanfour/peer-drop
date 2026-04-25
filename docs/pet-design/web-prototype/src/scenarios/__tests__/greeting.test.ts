import { test, expect } from 'vitest';
import { selectGreeting } from '../greeting';

test('curious dominant → walking with positive xOffset', () => {
  const beat = selectGreeting({ independent: 0, curious: 90, timid: 0, mischievous: 0 });
  expect(beat.action).toBe('walking');
  expect(beat.xOffset).toBeGreaterThan(0);
});

test('mischievous dominant → tapReact short', () => {
  const beat = selectGreeting({ independent: 0, curious: 0, timid: 0, mischievous: 90 });
  expect(beat.action).toBe('tapReact');
  expect(beat.durationMs).toBeLessThan(1000);
});

test('timid dominant → scared with retreat', () => {
  const beat = selectGreeting({ independent: 0, curious: 0, timid: 90, mischievous: 0 });
  expect(beat.action).toBe('scared');
  expect(beat.xOffset).toBeLessThan(0);
});
