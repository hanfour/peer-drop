import { useEffect, useState } from 'react';
import { loadSprite } from './sprite/loadSprite';
import { SpriteCanvas } from './render/SpriteCanvas';
import { PetStage } from './stage/PetStage';
import { useFrameAnimation } from './animation/useFrameAnimation';
import type { SpriteData, Palette } from './sprite/types';
import { TraitPanel } from './traits/TraitPanel';
import { defaultTraits, type Traits } from './traits/types';
import { selectIdleAction, type IdleAction } from './traits/idleSelector';

export default function App() {
  const [data, setData] = useState<SpriteData | null>(null);
  const [palette, setPalette] = useState<Palette | null>(null);
  const [traits, setTraits] = useState<Traits>(defaultTraits);
  const [currentAction, setCurrentAction] = useState<IdleAction>('idle');

  useEffect(() => {
    loadSprite('/data/cat.json').then(setData).catch(console.error);
    fetch('/data/palettes.json')
      .then((r) => r.json())
      .then((j) => setPalette(j.default))
      .catch(console.error);
  }, []);

  // Re-roll the idle action whenever traits change so the user immediately
  // sees the effect of moving a slider, then re-roll again every 5s for
  // ambient variety.
  useEffect(() => {
    setCurrentAction(selectIdleAction(traits));
    const id = setInterval(() => setCurrentAction(selectIdleAction(traits)), 5000);
    return () => clearInterval(id);
  }, [traits]);

  const frames =
    (data?.baby[currentAction] && data.baby[currentAction].length > 0
      ? data.baby[currentAction]
      : data?.baby.idle) ?? [];
  const frameIdx = useFrameAnimation(frames.length);

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
      {data && palette && frames.length > 0 ? (
        <div style={{ display: 'flex', gap: 24, alignItems: 'flex-start' }}>
          <PetStage>
            <SpriteCanvas frame={frames[frameIdx]} palette={palette} />
          </PetStage>
          <TraitPanel traits={traits} setTraits={setTraits} />
        </div>
      ) : (
        <div>Loading...</div>
      )}
    </div>
  );
}
