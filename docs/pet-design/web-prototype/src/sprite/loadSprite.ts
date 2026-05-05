import type { SpriteData } from './types';

export async function loadSprite(url: string): Promise<SpriteData> {
  const r = await fetch(url);
  if (!r.ok) throw new Error(`Failed to load sprite: ${r.status}`);
  return await r.json();
}
