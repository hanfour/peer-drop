import { test, expect, vi } from 'vitest';
import { loadSprite } from '../loadSprite';

test('loadSprite parses JSON', async () => {
  const fakeData = {
    meta: { groundY: 14, eyeAnchor: { x: 4, y: 5 } },
    baby: { idle: [[[0, 0], [0, 0]]] },
  };
  global.fetch = vi.fn().mockResolvedValue({
    ok: true,
    json: () => Promise.resolve(fakeData),
  }) as unknown as typeof fetch;
  const result = await loadSprite('/fake');
  expect(result.meta.groundY).toBe(14);
});

test('loadSprite throws on HTTP error', async () => {
  global.fetch = vi.fn().mockResolvedValue({ ok: false, status: 404 }) as unknown as typeof fetch;
  await expect(loadSprite('/missing')).rejects.toThrow();
});
