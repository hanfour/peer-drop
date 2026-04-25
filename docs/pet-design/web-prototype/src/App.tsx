import { useEffect, useState } from 'react';
import { loadSprite } from './sprite/loadSprite';
import { SpriteCanvas } from './render/SpriteCanvas';
import { PetStage } from './stage/PetStage';
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

  return (
    <div
      style={{
        minHeight: '100vh',
        padding: 24,
        fontFamily: 'system-ui',
        display: 'flex',
        flexDirection: 'column',
        alignItems: 'center',
        gap: 16,
      }}
    >
      <h1 style={{ margin: 0 }}>PeerDrop Pet Prototype</h1>
      {data && palette && idleFrames.length > 0 ? (
        <PetStage>
          <SpriteCanvas frame={idleFrames[frameIdx]} palette={palette} />
        </PetStage>
      ) : (
        <div>Loading...</div>
      )}
    </div>
  );
}
