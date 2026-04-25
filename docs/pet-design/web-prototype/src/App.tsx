import { useEffect, useRef, useState } from 'react';
import { loadSprite } from './sprite/loadSprite';
import { PetStage, type StagePet } from './stage/PetStage';
import { useFrameAnimation } from './animation/useFrameAnimation';
import type { SpriteData, Palette } from './sprite/types';
import { TraitPanel } from './traits/TraitPanel';
import { defaultTraits, dominantTrait, type TraitName, type Traits } from './traits/types';
import { selectIdleAction, type IdleAction } from './traits/idleSelector';
import { selectGreeting, type GreetingBeat } from './scenarios/greeting';
import { Particles, type Particle } from './render/Particles';
import { ProgressBar, useTransfer } from './scenarios/Transfer';
import { selectLine } from './dialogue/select';
import type { DialogueContext } from './dialogue/types';

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
  const [particles, setParticles] = useState<Particle[]>([]);
  const particleIdRef = useRef(0);
  const transfer = useTransfer();

  // Dialogue bubbles, keyed by pet id ('local' | 'peer'). One concurrent
  // bubble per pet — newer bubble replaces older via the timer ref.
  const [dialogue, setDialogue] = useState<Record<string, string>>({});
  const dialogueTimerRef = useRef<Map<string, ReturnType<typeof setTimeout>>>(new Map());
  const traitsRef = useRef<Traits>(traits);
  useEffect(() => {
    traitsRef.current = traits;
  }, [traits]);

  const showDialogue = (
    petId: 'local' | 'peer',
    ctx: DialogueContext,
    durationMs = 2200,
  ) => {
    // Peer uses the same trait pool for v0; independent peer traits aren't
    // simulated yet.
    const line = selectLine(traitsRef.current, ctx);
    if (!line) return;
    setDialogue((prev) => ({ ...prev, [petId]: line.text }));
    const existing = dialogueTimerRef.current.get(petId);
    if (existing) clearTimeout(existing);
    const t = setTimeout(() => {
      setDialogue((prev) => {
        const next = { ...prev };
        delete next[petId];
        return next;
      });
      dialogueTimerRef.current.delete(petId);
    }, durationMs);
    dialogueTimerRef.current.set(petId, t);
  };

  // Stage size (must match PetStage's intrinsic 480x240) — used to position
  // particle bursts in stage-local coordinates.
  const STAGE_W = 480;
  const STAGE_H = 240;

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
      showDialogue('local', 'greeting');
      showDialogue('peer', 'greeting', 2500);
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

  // Ambient idle dialogue: every ~10s, if neither pet is in a beat,
  // randomly emit one idle bubble from one of the two pets (alternating).
  // Provides a gentle sense of life without over-saturating the bubbles.
  const ambientToggleRef = useRef<'local' | 'peer'>('local');
  useEffect(() => {
    const id = setInterval(() => {
      // Skip if a transfer or local beat is in flight — those have their
      // own dialogue.
      if (transfer.state === 'running' || localBeat) return;
      const target = ambientToggleRef.current;
      // Only emit a peer bubble when the peer is on stage and idle.
      if (target === 'peer' && peerPhase !== 'idle') {
        ambientToggleRef.current = 'local';
        return;
      }
      showDialogue(target, 'idle');
      ambientToggleRef.current = target === 'local' ? 'peer' : 'local';
    }, 10000);
    return () => clearInterval(id);
  }, [transfer.state, localBeat, peerPhase]);

  const onTransferSuccess = () => {
    // If the peer isn't on stage yet, run the walk-in first then start
    // the transfer. We wait slightly past the 1.5s walk-in so the
    // greeting beat doesn't immediately get clobbered by transfer state.
    if (peerPhase === 'absent') {
      setPeerPhase('walking-in');
      setTimeout(() => transfer.start('success'), 1700);
    } else {
      transfer.start('success');
    }
  };

  const onTransferFail = () => {
    if (peerPhase === 'absent') {
      setPeerPhase('walking-in');
      setTimeout(() => transfer.start('fail'), 1700);
    } else {
      transfer.start('fail');
    }
  };

  // React to transfer completion: emit a celebratory burst and put the
  // local pet into a longer `happy` beat. Peer pet's reaction is handled
  // by the transfer state itself (see action selection below).
  useEffect(() => {
    if (transfer.state === 'success') {
      const burst: Particle[] = Array.from({ length: 12 }, (_, i) => ({
        id: ++particleIdRef.current,
        x: STAGE_W * 0.5 + (Math.random() - 0.5) * 80,
        y: STAGE_H * 0.46,
        vx: (Math.random() - 0.5) * 80,
        vy: -100 - Math.random() * 40,
        emoji: ['✨', '💖', '🎉', '⭐'][i % 4],
        bornAt: performance.now(),
        lifeMs: 1500,
      }));
      setParticles((prev) => [...prev, ...burst]);
      setLocalBeat({ action: 'happy' as GreetingBeat['action'], durationMs: 1500 });
      showDialogue('local', 'transferSuccess');
      showDialogue('peer', 'transferSuccess');
      const id = setTimeout(() => setLocalBeat(null), 1500);
      return () => clearTimeout(id);
    }
    if (transfer.state === 'failed') {
      // Trait-flavored local reaction. Independent/curious are stoic;
      // timid recoils; mischievous goes smug.
      const reactionByTrait: Record<TraitName, GreetingBeat['action']> = {
        independent: 'idle',
        curious: 'idle',
        timid: 'scared',
        mischievous: 'tapReact',
      };
      const dom = dominantTrait(traits);
      setLocalBeat({ action: reactionByTrait[dom], durationMs: 1500 });
      showDialogue('local', 'transferFail');
      showDialogue('peer', 'transferFail');
      const id = setTimeout(() => setLocalBeat(null), 1500);
      return () => clearTimeout(id);
    }
  }, [transfer.state, traits]);

  // Peer pet's force-action — transfer outcomes drive this so both pets
  // can cheer (or commiserate) in sync. Cleared on a timer.
  const [peerForceAction, setPeerForceAction] = useState<string | null>(null);
  useEffect(() => {
    if (transfer.state === 'success') {
      setPeerForceAction('happy');
      const id = setTimeout(() => setPeerForceAction(null), 1500);
      return () => clearTimeout(id);
    }
    if (transfer.state === 'failed') {
      // Peer always looks concerned regardless of local pet's trait.
      setPeerForceAction('scared');
      const id = setTimeout(() => setPeerForceAction(null), 1500);
      return () => clearTimeout(id);
    }
  }, [transfer.state]);

  const peerAction: string =
    peerForceAction ?? (peerPhase === 'walking-in' ? 'walking' : 'idle');
  const peerFrames =
    (data?.baby[peerAction] && data.baby[peerAction].length > 0
      ? data.baby[peerAction]
      : data?.baby.idle) ?? [];
  // Slightly faster fps for the walking sprite reads better at speed.
  const peerFrameIdx = useFrameAnimation(peerFrames.length, peerAction === 'walking' ? 8 : 6);
  const safePeerIdx = peerFrames.length > 0 ? Math.min(peerFrameIdx, peerFrames.length - 1) : 0;

  const ready = data && palette && localFrames.length > 0;

  const onLocalPetTap = () => {
    // 1. Trait-flavored tap reaction. Timid pets recoil with `scared`,
    //    everyone else does the standard `tapReact` poke. Latest-write-wins
    //    if a greeting/transfer beat is also active.
    const dom = dominantTrait(traits);
    const tapAction: GreetingBeat['action'] = dom === 'timid' ? 'scared' : 'tapReact';
    setLocalBeat({ action: tapAction, durationMs: 600 });
    setTimeout(() => {
      // Only clear if our beat is still the latest. We keep this simple:
      // always clear; if a newer beat overwrites this one, this clear
      // races harmlessly (`localBeat` will already be null or the next).
      setLocalBeat((b) => (b && b.action === tapAction ? null : b));
    }, 600);

    // Tap dialogue bubble.
    showDialogue('local', 'tap');

    // 2. Trait-flavored particle burst from the local pet's position.
    const emoji = dom === 'mischievous' ? '?' : dom === 'timid' ? '♡' : '♥';
    const count = dom === 'timid' ? 3 : dom === 'mischievous' ? 2 : 5;
    const petX = STAGE_W * (localXPercent / 100);
    const petY = STAGE_H * 0.6 + 40;
    const newParticles: Particle[] = Array.from({ length: count }, () => ({
      id: ++particleIdRef.current,
      x: petX + (Math.random() - 0.5) * 30,
      y: petY,
      vx: (Math.random() - 0.5) * 30,
      vy: -60 - Math.random() * 40, // upward
      emoji,
      bornAt: performance.now(),
      lifeMs: 1100,
    }));
    setParticles((prev) => [...prev, ...newParticles]);

    // 3. Cleanup expired particles after their max lifespan to keep the
    //    array bounded.
    setTimeout(() => {
      setParticles((prev) => prev.filter((p) => performance.now() - p.bornAt < p.lifeMs));
    }, 1500);
  };

  let pets: StagePet[] = [];
  if (ready) {
    const localPet: StagePet = {
      id: 'local',
      frame: localFrames[safeLocalIdx],
      palette,
      xPercent: localXPercent,
      flipped: false,
      onClick: onLocalPetTap,
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
          <PetStage
            pets={pets}
            accentColor={ACCENT[dominantTrait(traits)]}
            progressBar={<ProgressBar progress={transfer.progress} state={transfer.state} />}
            overlay={<Particles particles={particles} />}
            dialogueByPet={dialogue}
          />
          <div style={{ display: 'flex', flexDirection: 'column', gap: 12 }}>
            <TraitPanel traits={traits} setTraits={setTraits} />
            <div style={{ display: 'flex', flexDirection: 'column', gap: 6 }}>
              <button style={buttonStyle} onClick={onTogglePeer}>
                {peerPhase === 'absent' ? 'Connect peer' : 'Disconnect peer'}
              </button>
              <button
                style={buttonStyle}
                onClick={onTransferSuccess}
                disabled={transfer.state === 'running'}
              >
                Transfer (success)
              </button>
              <button
                style={buttonStyle}
                onClick={onTransferFail}
                disabled={transfer.state === 'running'}
              >
                Transfer (fail)
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
