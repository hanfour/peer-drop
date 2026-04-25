import { useEffect, useState } from 'react';
import { loadSprite } from './sprite/loadSprite';
import { PetStage, type StagePet } from './stage/PetStage';
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

const buttonStyle: React.CSSProperties = {
  padding: '6px 12px',
  fontSize: 13,
  fontFamily: 'system-ui',
  borderRadius: 6,
  border: '1px solid rgba(0,0,0,0.15)',
  background: '#fff',
  cursor: 'pointer',
};

export default function App() {
  const [data, setData] = useState<SpriteData | null>(null);
  const [palette, setPalette] = useState<Palette | null>(null);
  const [traits, setTraits] = useState<Traits>(defaultTraits);
  const [currentAction, setCurrentAction] = useState<IdleAction>('idle');
  const [peerConnected, setPeerConnected] = useState(false);

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

  const localFrames =
    (data?.baby[currentAction] && data.baby[currentAction].length > 0
      ? data.baby[currentAction]
      : data?.baby.idle) ?? [];
  const localFrameIdx = useFrameAnimation(localFrames.length);
  const safeLocalIdx = localFrames.length > 0 ? Math.min(localFrameIdx, localFrames.length - 1) : 0;

  // Peer pet currently always plays idle (walk-in lands in Task 14).
  const peerFrames = data?.baby.idle ?? [];
  const peerFrameIdx = useFrameAnimation(peerFrames.length);
  const safePeerIdx = peerFrames.length > 0 ? Math.min(peerFrameIdx, peerFrames.length - 1) : 0;

  const ready = data && palette && localFrames.length > 0;

  let pets: StagePet[] = [];
  if (ready) {
    const localPet: StagePet = {
      id: 'local',
      frame: localFrames[safeLocalIdx],
      palette,
      xPercent: 30,
      flipped: false,
    };
    pets = [localPet];
    if (peerConnected && peerFrames.length > 0) {
      pets.push({
        id: 'peer',
        frame: peerFrames[safePeerIdx],
        palette,
        xPercent: 70,
        flipped: true,
      });
    }
  }

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
      {ready ? (
        <div style={{ display: 'flex', gap: 24, alignItems: 'flex-start' }}>
          <PetStage pets={pets} accentColor={ACCENT[dominantTrait(traits)]} />
          <div style={{ display: 'flex', flexDirection: 'column', gap: 12 }}>
            <TraitPanel traits={traits} setTraits={setTraits} />
            <div style={{ display: 'flex', flexDirection: 'column', gap: 6 }}>
              <button style={buttonStyle} onClick={() => setPeerConnected((c) => !c)}>
                {peerConnected ? 'Disconnect peer' : 'Connect peer'}
              </button>
            </div>
          </div>
        </div>
      ) : (
        <div>Loading...</div>
      )}
    </div>
  );
}
