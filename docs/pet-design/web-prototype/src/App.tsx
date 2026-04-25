import { useEffect, useState } from 'react';
import { loadSprite } from './sprite/loadSprite';
import { SpriteCanvas } from './render/SpriteCanvas';
import { PetStage } from './stage/PetStage';
import { useFrameAnimation } from './animation/useFrameAnimation';
import type { SpriteData, Palette } from './sprite/types';
import { TraitPanel } from './traits/TraitPanel';
import { defaultTraits, dominantTrait, type TraitName, type Traits } from './traits/types';
import { selectIdleAction, type IdleAction } from './traits/idleSelector';

const ACCENT: Record<TraitName, string> = {
  curious: 'rgba(180, 220, 255, 0.5)', // cool blue
  timid: 'rgba(255, 200, 220, 0.45)', // pink
  mischievous: 'rgba(255, 240, 180, 0.5)', // warm yellow
  independent: 'rgba(220, 220, 230, 0.4)', // neutral gray
};

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
  // Clamp: when `currentAction` switches between actions with different frame
  // counts, the hook's internal frame state may transiently exceed the new
  // length on the first render. Clamping here avoids handing an undefined
  // frame to SpriteCanvas.
  const safeFrameIdx = frames.length > 0 ? Math.min(frameIdx, frames.length - 1) : 0;

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
          <PetStage accentColor={ACCENT[dominantTrait(traits)]}>
            <SpriteCanvas frame={frames[safeFrameIdx]} palette={palette} />
          </PetStage>
          <TraitPanel traits={traits} setTraits={setTraits} />
        </div>
      ) : (
        <div>Loading...</div>
      )}
    </div>
  );
}
