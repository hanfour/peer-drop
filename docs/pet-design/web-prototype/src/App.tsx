import { useEffect, useState } from 'react';
import { loadSprite } from './sprite/loadSprite';
import { SpriteCanvas } from './render/SpriteCanvas';
import { useFrameAnimation } from './animation/useFrameAnimation';
import type { SpriteData, Palette } from './sprite/types';

export default function App() {
  const [data, setData] = useState<SpriteData | null>(null);
  const [palette, setPalette] = useState<Palette | null>(null);

  useEffect(() => {
    loadSprite('/data/cat.json').then(setData).catch(console.error);
    fetch('/data/palettes.json')
      .then((r) => r.json())
      .then((j) => setPalette(j.default))
      .catch(console.error);
  }, []);

  const idleFrames = data?.baby.idle ?? [];
  const frameIdx = useFrameAnimation(idleFrames.length);

  if (!data || !palette || idleFrames.length === 0) {
    return <div style={{ padding: 24 }}>Loading...</div>;
  }

  return (
    <div style={{ padding: 24, fontFamily: 'system-ui' }}>
      <h1>PeerDrop Pet Prototype</h1>
      <SpriteCanvas frame={idleFrames[frameIdx]} palette={palette} />
    </div>
  );
}
