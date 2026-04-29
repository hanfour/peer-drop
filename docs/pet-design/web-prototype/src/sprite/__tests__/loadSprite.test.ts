import { test, expect, vi } from 'vitest';
import { loadSprite } from '../loadSprite';

test('loadSprite parses JSON', async () => {
  const fakeData = {
    meta: { groundY: 14, eyeAnchor: { x: 4, y: 5 } },
    baby: { idle: [[[0, 0], [0, 0]]] },
  };
  vi.stubGlobal(
    'fetch',
    vi.fn().mockResolvedValue({
      ok: true,
      json: () => Promise.resolve(fakeData),
    }),
  );
  const result = await loadSprite('/fake');
  expect(result.meta.groundY).toBe(14);
});

test('loadSprite throws on HTTP error', async () => {
  vi.stubGlobal('fetch', vi.fn().mockResolvedValue({ ok: false, status: 404 }));
  await expect(loadSprite('/missing')).rejects.toThrow();
});
