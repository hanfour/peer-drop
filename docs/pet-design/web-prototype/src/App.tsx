import { useEffect, useRef, useState } from 'react';
import { loadSprite } from './sprite/loadSprite';
import { PetStage, type StagePet } from './stage/PetStage';
import { useFrameAnimation } from './animation/useFrameAnimation';
import type { SpriteData, Palette } from './sprite/types';
import { TraitPanel } from './traits/TraitPanel';
import { defaultTraits, dominantTrait, type TraitName, type Traits } from './traits/types';
import { selectIdleAction, type IdleAction } from './traits/idleSelector';
import { selectGreeting, type GreetingBeat } from './scenarios/greeting';

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
  type PeerPhase = 'absent' | 'walking-in' | 'idle';
  const [peerPhase, setPeerPhase] = useState<PeerPhase>('absent');
  // One-shot override for the local pet's action — used by the greeting
  // beat (Task 15), tap reaction (Task 16), and transfer outcomes
  // (Tasks 17/18). When non-null it wins over `currentAction`.
  const [localBeat, setLocalBeat] = useState<GreetingBeat | null>(null);

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

  // The local pet's effective action: if a beat is active, it overrides
  // the ambient idle pick.
  const effectiveLocalAction: string = localBeat?.action ?? currentAction;
  const localFrames =
    (data?.baby[effectiveLocalAction] && data.baby[effectiveLocalAction].length > 0
      ? data.baby[effectiveLocalAction]
      : data?.baby.idle) ?? [];
  const localFps = effectiveLocalAction === 'walking' ? 8 : 6;
  const localFrameIdx = useFrameAnimation(localFrames.length, localFps);
  const safeLocalIdx = localFrames.length > 0 ? Math.min(localFrameIdx, localFrames.length - 1) : 0;
  const localXPercent = 30 + (localBeat?.xOffset ?? 0);

  // Trigger a greeting beat each time peerPhase enters 'idle' (i.e. the
  // walk-in just finished). Latest-write-wins if a tap or transfer beat
  // is already active — accept the conflict for now.
  const prevPeerPhaseRef = useRef<PeerPhase>('absent');
  useEffect(() => {
    const prev = prevPeerPhaseRef.current;
    prevPeerPhaseRef.current = peerPhase;
    if (prev !== 'idle' && peerPhase === 'idle') {
      const beat = selectGreeting(traits);
      setLocalBeat(beat);
      const id = setTimeout(() => setLocalBeat(null), beat.durationMs);
      return () => clearTimeout(id);
    }
  }, [peerPhase, traits]);

  // Animated peer position. We mount the peer at xPercent=110 (offscreen
  // right) for one frame, then update to 70 so the CSS transition on `left`
  // animates a slide-in. After 1.5s we switch phase to 'idle'.
  const [peerXPercent, setPeerXPercent] = useState(110);
  useEffect(() => {
    if (peerPhase === 'walking-in') {
      // Ensure starting position is offscreen, then on next frame move to 70.
      setPeerXPercent(110);
      const raf = requestAnimationFrame(() => {
        // A second rAF guarantees the browser has painted the 110 frame
        // before we transition to 70.
        requestAnimationFrame(() => setPeerXPercent(70));
      });
      const id = setTimeout(() => setPeerPhase('idle'), 1500);
      return () => {
        cancelAnimationFrame(raf);
        clearTimeout(id);
      };
    }
    if (peerPhase === 'idle') {
      setPeerXPercent(70);
    }
    if (peerPhase === 'absent') {
      setPeerXPercent(110);
    }
  }, [peerPhase]);

  const onTogglePeer = () => {
    setPeerPhase((p) => (p === 'absent' ? 'walking-in' : 'absent'));
  };

  const peerAction: 'walking' | 'idle' = peerPhase === 'walking-in' ? 'walking' : 'idle';
  const peerFrames =
    (data?.baby[peerAction] && data.baby[peerAction].length > 0
      ? data.baby[peerAction]
      : data?.baby.idle) ?? [];
  // Slightly faster fps for the walking sprite reads better at speed.
  const peerFrameIdx = useFrameAnimation(peerFrames.length, peerAction === 'walking' ? 8 : 6);
  const safePeerIdx = peerFrames.length > 0 ? Math.min(peerFrameIdx, peerFrames.length - 1) : 0;

  const ready = data && palette && localFrames.length > 0;

  let pets: StagePet[] = [];
  if (ready) {
    const localPet: StagePet = {
      id: 'local',
      frame: localFrames[safeLocalIdx],
      palette,
      xPercent: localXPercent,
      flipped: false,
    };
    pets = [localPet];
    if (peerPhase !== 'absent' && peerFrames.length > 0) {
      pets.push({
        id: 'peer',
        frame: peerFrames[safePeerIdx],
        palette,
        xPercent: peerXPercent,
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
              <button style={buttonStyle} onClick={onTogglePeer}>
                {peerPhase === 'absent' ? 'Connect peer' : 'Disconnect peer'}
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
