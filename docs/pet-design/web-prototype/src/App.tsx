import { useEffect, useRef, useState } from 'react';
import { loadSprite } from './sprite/loadSprite';
import { PetStage, type StagePet } from './stage/PetStage';
import { useFrameAnimation } from './animation/useFrameAnimation';
import type { SpriteData, Palette } from './sprite/types';
import { TraitPanel } from './traits/TraitPanel';
import { defaultTraits, dominantTrait, type TraitName, type Traits } from './traits/types';
import { selectIdleAction, type IdleAction } from './traits/idleSelector';
import type { GreetingBeat } from './scenarios/greeting';
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

  // v0 = original 16×16 production sprite (cat.json).
  // v1 = new 32×32 chibi sprite (cat-v1.json) — see scripts/paint-v1-cat.mjs.
  // Default to v1 so the polished version shows first.
  type SpriteVersion = 'v0' | 'v1';
  const [spriteVersion, setSpriteVersion] = useState<SpriteVersion>('v1');

  useEffect(() => {
    const url = spriteVersion === 'v1' ? '/data/cat-v1.json' : '/data/cat.json';
    loadSprite(url)
      .then((d) => {
        setData(d);
        // If the sprite ships its own palette (v1 chibi placeholder is
        // grayscale-quantised at import time), use it directly. This keeps
        // the v0 production palette (warm orange/cream from palettes.json)
        // untouched while the v1 sprite renders against its own intrinsic
        // gray scheme.
        if (d.palette) {
          setPalette(d.palette);
        } else {
          fetch('/data/palettes.json')
            .then((r) => r.json())
            .then((j) => setPalette(j.default))
            .catch(console.error);
        }
      })
      .catch(console.error);
  }, [spriteVersion]);

  // Re-roll the idle action whenever traits change so the user immediately
  // sees the effect of moving a slider, then re-roll again every 5s for
  // ambient variety.
  useEffect(() => {
    setCurrentAction(selectIdleAction(traits));
    const id = setInterval(() => setCurrentAction(selectIdleAction(traits)), 5000);
    return () => clearInterval(id);
  }, [traits]);

  // v1 idle micro-actions: every 12s, if no other beat is in flight,
  // briefly play `happy` for 1s as a "look around / brief enthusiasm" tic.
  // The blink is already baked into the idle 4-frame sequence (frame 2),
  // so the cat naturally blinks ~once per cycle without extra logic here.
  useEffect(() => {
    const id = setInterval(() => {
      if (localBeat) return;
      if (transfer.state === 'running') return;
      // 50% chance per tick — keeps the tic from feeling clockwork.
      if (Math.random() < 0.5) return;
      setLocalBeat({ action: 'happy', durationMs: 900 });
      setTimeout(() => setLocalBeat((b) => (b?.action === 'happy' ? null : b)), 900);
    }, 12000);
    return () => clearInterval(id);
  }, [localBeat, transfer.state]);

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

  // Trigger a multi-beat greeting each time peerPhase enters 'idle'.
  // v1: instead of running a single action for `durationMs`, we sequence
  // an anticipation → main → settle so the gesture has weight.
  //   curious:     tapReact (lean back, 200ms) → walking forward (1300ms) → idle (settle)
  //   mischievous: tapReact poke (250ms) → happy bounce (800ms)
  //   timid:       scared (recoil with negative xOffset, 400ms) → idle (scoot back, 600ms)
  //   independent: a single brief beat — basically nothing (character)
  const prevPeerPhaseRef = useRef<PeerPhase>('absent');
  useEffect(() => {
    const prev = prevPeerPhaseRef.current;
    prevPeerPhaseRef.current = peerPhase;
    if (prev === 'idle' || peerPhase !== 'idle') return;

    showDialogue('local', 'greeting');
    showDialogue('peer', 'greeting', 2500);

    const dom = dominantTrait(traits);
    const timers: ReturnType<typeof setTimeout>[] = [];

    if (dom === 'curious') {
      // Anticipation: lean back briefly
      setLocalBeat({ action: 'tapReact', durationMs: 200, xOffset: -2 });
      timers.push(
        setTimeout(() => {
          // Main: trot forward
          setLocalBeat({ action: 'walking', durationMs: 1300, xOffset: 15 });
        }, 200),
      );
      timers.push(
        setTimeout(() => {
          // Settle: idle, hold the new spot
          setLocalBeat({ action: 'idle', durationMs: 400, xOffset: 15 });
        }, 1500),
      );
      timers.push(setTimeout(() => setLocalBeat(null), 1900));
    } else if (dom === 'mischievous') {
      // Quick poke then happy bounce
      setLocalBeat({ action: 'tapReact', durationMs: 250 });
      timers.push(
        setTimeout(() => {
          setLocalBeat({ action: 'happy', durationMs: 800 });
        }, 250),
      );
      timers.push(setTimeout(() => setLocalBeat(null), 1050));
    } else if (dom === 'timid') {
      // Scared then a tiny scoot back
      setLocalBeat({ action: 'scared', durationMs: 400, xOffset: -10 });
      timers.push(
        setTimeout(() => {
          setLocalBeat({ action: 'idle', durationMs: 600, xOffset: -4 });
        }, 400),
      );
      timers.push(setTimeout(() => setLocalBeat(null), 1000));
    } else {
      // Independent: a single brief glance.
      setLocalBeat({ action: 'idle', durationMs: 600 });
      timers.push(setTimeout(() => setLocalBeat(null), 600));
    }

    return () => {
      for (const t of timers) clearTimeout(t);
    };
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
      const successKinds: ('sparkle' | 'heart' | 'exclamation')[] = [
        'sparkle',
        'heart',
        'sparkle',
        'exclamation',
      ];
      const burst: Particle[] = Array.from({ length: 12 }, (_, i) => ({
        id: ++particleIdRef.current,
        x: STAGE_W * 0.5 + (Math.random() - 0.5) * 80,
        y: STAGE_H * 0.46,
        vx: (Math.random() - 0.5) * 80,
        vy: -100 - Math.random() * 40,
        kind: successKinds[i % successKinds.length],
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
    const kind: 'heart' | 'question' | 'sparkle' =
      dom === 'mischievous' ? 'question' : dom === 'timid' ? 'sparkle' : 'heart';
    const count = dom === 'timid' ? 3 : dom === 'mischievous' ? 2 : 5;
    const petX = STAGE_W * (localXPercent / 100);
    const petY = STAGE_H * 0.6 + 40;
    const newParticles: Particle[] = Array.from({ length: count }, () => ({
      id: ++particleIdRef.current,
      x: petX + (Math.random() - 0.5) * 30,
      y: petY,
      vx: (Math.random() - 0.5) * 30,
      vy: -60 - Math.random() * 40, // upward
      kind,
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

  // Derive scale from the sprite size so v0 (16×16) and v1 (32×32) both
  // render at the same on-stage display size (~128px).
  const spriteSize = data?.baby.idle?.[0]?.length ?? 16;
  const renderScale = spriteSize <= 16 ? 8 : 4;

  // Scope-framing banner state. Persists per-tab via sessionStorage so
  // it stays out of the way once the reviewer has acknowledged it, but
  // re-appears for fresh sessions (and hard reloads).
  const [scopeBannerDismissed, setScopeBannerDismissed] = useState<boolean>(() => {
    if (typeof window === 'undefined') return false;
    return window.sessionStorage.getItem('petPrototype.scopeBannerDismissed') === '1';
  });
  const dismissScopeBanner = () => {
    setScopeBannerDismissed(true);
    if (typeof window !== 'undefined') {
      window.sessionStorage.setItem('petPrototype.scopeBannerDismissed', '1');
    }
  };

  let pets: StagePet[] = [];
  if (ready) {
    const localPet: StagePet = {
      id: 'local',
      frame: localFrames[safeLocalIdx],
      palette,
      scale: renderScale,
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
        scale: renderScale,
        xPercent: peerXPercent,
        flipped: true,
      });
    }
  }

  return (
    <div
      style={{
        minHeight: '100vh',
        padding: '32px 24px',
        maxWidth: 1100,
        margin: '0 auto',
      }}
    >
      <header
        style={{
          marginBottom: 24,
          display: 'flex',
          alignItems: 'flex-end',
          justifyContent: 'space-between',
          gap: 16,
        }}
      >
        <div>
          <h1 style={{ margin: 0, fontSize: 28, fontWeight: 600, letterSpacing: '-0.5px' }}>
            PeerDrop Pet Prototype
          </h1>
          <p style={{ margin: '4px 0 0', color: '#888', fontSize: 14 }}>
            {spriteVersion === 'v1'
              ? 'v1 — Tiny Cat Sprite (Segel, CC0) imported as 32×32 chibi placeholder'
              : 'v0 — production 16×16 sprite baseline'}
          </p>
        </div>
        <div
          role="group"
          aria-label="Sprite version toggle"
          style={{
            display: 'inline-flex',
            border: '2px solid currentColor',
            borderRadius: 8,
            overflow: 'hidden',
            fontSize: 13,
          }}
        >
          <button
            onClick={() => setSpriteVersion('v0')}
            style={{
              background:
                spriteVersion === 'v0' ? '#1976d2' : 'rgba(0,0,0,0.05)',
              color: spriteVersion === 'v0' ? 'white' : 'inherit',
              padding: '6px 14px',
              borderRadius: 0,
              fontWeight: spriteVersion === 'v0' ? 600 : 400,
            }}
          >
            v0 (16×16)
          </button>
          <button
            onClick={() => setSpriteVersion('v1')}
            style={{
              background:
                spriteVersion === 'v1' ? '#1976d2' : 'rgba(0,0,0,0.05)',
              color: spriteVersion === 'v1' ? 'white' : 'inherit',
              padding: '6px 14px',
              borderRadius: 0,
              fontWeight: spriteVersion === 'v1' ? 600 : 400,
            }}
          >
            v1 (32×32 chibi)
          </button>
        </div>
      </header>
      {!scopeBannerDismissed && (
        <div
          role="note"
          aria-label="原型範圍說明"
          style={{
            marginBottom: 20,
            padding: '14px 18px',
            border: '1px solid #d6e4ff',
            borderLeft: '4px solid #1976d2',
            background: 'rgba(25, 118, 210, 0.06)',
            borderRadius: 6,
            fontSize: 13.5,
            lineHeight: 1.6,
            display: 'flex',
            alignItems: 'flex-start',
            gap: 12,
          }}
        >
          <div style={{ flex: 1 }}>
            <strong style={{ display: 'block', marginBottom: 4 }}>
              本原型聚焦於互動設計討論
            </strong>
            請評估：見面動作編排、檔案傳輸反應、性格特徵滑桿、對話泡泡時機、場景視覺。
            Sprite 美術為占位素材（
            <a
              href="https://opengameart.org/content/tiny-kitten-game-sprite"
              target="_blank"
              rel="noreferrer"
              style={{ color: '#1976d2' }}
            >
              Tiny Cat Sprite by Segel, CC0
            </a>
            ），production 階段將另行委託定製像素藝術，請忽略目前 sprite 的細節品質。
          </div>
          <button
            onClick={dismissScopeBanner}
            aria-label="關閉說明"
            style={{
              border: 'none',
              background: 'transparent',
              cursor: 'pointer',
              fontSize: 18,
              lineHeight: 1,
              color: '#1976d2',
              padding: '2px 6px',
            }}
          >
            ×
          </button>
        </div>
      )}
      {ready ? (
        <main
          style={{
            display: 'grid',
            gridTemplateColumns: 'minmax(0, auto) minmax(280px, 320px)',
            gap: 32,
            alignItems: 'flex-start',
          }}
        >
          <PetStage
            pets={pets}
            accentColor={ACCENT[dominantTrait(traits)]}
            progressBar={<ProgressBar progress={transfer.progress} state={transfer.state} />}
            overlay={<Particles particles={particles} />}
            dialogueByPet={dialogue}
          />
          <aside style={{ display: 'grid', gap: 16 }}>
            <TraitPanel traits={traits} setTraits={setTraits} />
            <div style={{ display: 'grid', gap: 8 }}>
              <button onClick={onTogglePeer}>
                {peerPhase === 'absent' ? 'Connect peer' : 'Disconnect peer'}
              </button>
              <button onClick={onTransferSuccess} disabled={transfer.state === 'running'}>
                Transfer (success)
              </button>
              <button onClick={onTransferFail} disabled={transfer.state === 'running'}>
                Transfer (fail)
              </button>
            </div>
          </aside>
        </main>
      ) : (
        <div>Loading...</div>
      )}
      <footer style={{ marginTop: 48, color: '#aaa', fontSize: 12 }}>
        Designed 2026-04-25. See{' '}
        <code>docs/plans/2026-04-25-pet-companion-redesign-design.md</code> for context.
      </footer>
    </div>
  );
}
