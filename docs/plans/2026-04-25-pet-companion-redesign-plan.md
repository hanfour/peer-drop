# Pet Companion Redesign — Web Prototype Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development to implement this plan task-by-task. Implementer subagents should invoke **frontend-design:frontend-design** when designing the visual surfaces.

**Goal:** Build an iterative web prototype (Vite + React + TS + Canvas 2D) of the pet redesign so the team can discuss and refine the design before porting to SwiftUI.

**Architecture:** Single-page React app under `docs/pet-design/web-prototype/`. Canvas-based pet stage with palette-swap rendering of existing 16×16 sprite data. Reactive React shell for trait sliders + scenario buttons. Local-only state — no networking; the "peer" pet is simulated.

**Tech Stack:** Vite 5, React 18, TypeScript 5, Canvas 2D API, no game engine. Sprite data exported from existing Swift `CatSpriteData.swift` to JSON via a one-shot Ruby/Swift script.

**Source design:** `docs/plans/2026-04-25-pet-companion-redesign-design.md`

---

## Phase 1 — Scaffold + sprite export

### Task 1: Create Vite + React + TS scaffold

**Files:**
- Create: `docs/pet-design/web-prototype/package.json`
- Create: `docs/pet-design/web-prototype/vite.config.ts`
- Create: `docs/pet-design/web-prototype/tsconfig.json`
- Create: `docs/pet-design/web-prototype/index.html`
- Create: `docs/pet-design/web-prototype/src/main.tsx`
- Create: `docs/pet-design/web-prototype/src/App.tsx`
- Create: `docs/pet-design/web-prototype/.gitignore`

**Step 1: Bootstrap with Vite**

```bash
cd docs/pet-design && npm create vite@latest web-prototype -- --template react-ts
cd web-prototype && npm install
```

**Step 2: Verify dev server runs**

```bash
npm run dev
```

Expected: Vite shows `Local: http://localhost:5173/`. Open URL — default React+Vite landing page.

**Step 3: Replace `App.tsx` with placeholder**

```tsx
export default function App() {
  return <div style={{ padding: 24, fontFamily: 'system-ui' }}>
    <h1>PeerDrop Pet Prototype</h1>
    <p>v0 — scaffold ready</p>
  </div>;
}
```

**Step 4: Commit**

```bash
git add docs/pet-design/
git commit -m "scaffold(pet-prototype): vite + react + ts shell"
```

---

### Task 2: Add `.gitignore` for the prototype

**Files:**
- Create: `docs/pet-design/web-prototype/.gitignore`

```gitignore
node_modules/
dist/
.vite/
*.log
.env*
```

Commit: `chore(pet-prototype): gitignore node_modules + build output`

---

### Task 3: Export Cat sprite + palette to JSON

**Files:**
- Create: `docs/pet-design/web-prototype/scripts/export-sprite.swift` (one-shot)
- Create: `docs/pet-design/web-prototype/public/data/cat.json` (output)
- Create: `docs/pet-design/web-prototype/public/data/palettes.json` (output)

**Step 1: Write the export script**

Make a Swift CLI script that imports the existing `CatSpriteData.swift` and `PetPalettes.swift` and serializes them to JSON.

```swift
#!/usr/bin/env swift
import Foundation

// Path-relative imports won't work cleanly in a CLI script. Easier:
// add a temporary unit-test target that calls the export, OR
// make this script copy-and-paste the relevant data.

// SIMPLEST: write a one-off SwiftUI macOS playground or test. For
// this prototype, take the easier path: copy `CatSpriteData.baby[.idle]`
// (~10 frames × 16 rows × 16 cols = 2560 ints) into a Swift snippet
// that prints JSON.

// Or even simpler: have the implementer run this from inside Xcode
// as a unit test that writes the JSON to a known path, then commit
// the resulting JSONs.
```

**Pragmatic approach:** Add a `PetSpriteExportTests.swift` unit test in the existing test target that, when run, writes `cat.json` and `palettes.json` to a temp dir, then the implementer copies the result into `public/data/`.

**Step 2: JSON shape**

`cat.json`:
```json
{
  "meta": {
    "groundY": 14,
    "eyeAnchor": { "x": 4, "y": 5 }
  },
  "baby": {
    "idle": [[/* 16x16 of palette indices */], /* ...frames */],
    "walking": [...],
    /* ... all PetAction variants */
  },
  "child": { ... }
}
```

`palettes.json`:
```json
{
  "default": ["transparent", "#1a1a1a", "#ffaa44", "#ffd99a", "#fff4d4", "#222222"],
  /* ...other palettes */
}
```

**Step 3: Commit**

```bash
git add docs/pet-design/web-prototype/public/data/cat.json \
        docs/pet-design/web-prototype/public/data/palettes.json
git commit -m "data(pet-prototype): export cat sprite + palettes to JSON"
```

---

## Phase 2 — Core renderer + idle pet

### Task 4: Sprite type definitions + JSON loader

**Files:**
- Create: `docs/pet-design/web-prototype/src/sprite/types.ts`
- Create: `docs/pet-design/web-prototype/src/sprite/loadSprite.ts`
- Create: `docs/pet-design/web-prototype/src/sprite/__tests__/loadSprite.test.ts` (vitest)

**Step 1: Add vitest**

```bash
cd docs/pet-design/web-prototype
npm install -D vitest @testing-library/react @testing-library/jest-dom jsdom
```

Add to `package.json` scripts: `"test": "vitest run"`.

Add `vitest.config.ts`:
```ts
import { defineConfig } from 'vitest/config';
import react from '@vitejs/plugin-react';
export default defineConfig({
  plugins: [react()],
  test: { environment: 'jsdom' }
});
```

**Step 2: Types**

```ts
// src/sprite/types.ts
export type Frame = number[][]; // 16x16 of palette indices
export type ActionFrames = Frame[];
export type Stage = 'baby' | 'child';
export type Action = 'idle' | 'walking' | 'run' | 'jump' | 'happy' | /* ... */ string;
export type SpriteData = {
  meta: { groundY: number; eyeAnchor: { x: number; y: number } };
  baby: Record<Action, ActionFrames>;
  child: Record<Action, ActionFrames>;
};
export type Palette = string[]; // hex colors, [0]='transparent'
```

**Step 3: Loader + failing test**

```ts
// src/sprite/loadSprite.ts
export async function loadSprite(url: string): Promise<SpriteData> {
  const r = await fetch(url);
  return await r.json();
}
```

```ts
// __tests__/loadSprite.test.ts
import { test, expect } from 'vitest';
import { loadSprite } from '../loadSprite';

test('loadSprite parses JSON', async () => {
  const fakeData: SpriteData = { /* minimal valid */ };
  global.fetch = (() => Promise.resolve({ json: () => Promise.resolve(fakeData) })) as any;
  expect(await loadSprite('fake')).toEqual(fakeData);
});
```

**Step 4: Run tests, commit**

`npm test` → 1 passing.

```bash
git commit -m "feat(pet-prototype): sprite type definitions + JSON loader with test"
```

---

### Task 5: Canvas-based sprite renderer

**Files:**
- Create: `docs/pet-design/web-prototype/src/render/SpriteCanvas.tsx`

**Step 1: Component**

```tsx
import { useRef, useEffect } from 'react';
import type { Frame, Palette } from '../sprite/types';

export function SpriteCanvas({
  frame, palette, scale = 8
}: { frame: Frame; palette: Palette; scale?: number }) {
  const ref = useRef<HTMLCanvasElement>(null);
  useEffect(() => {
    const c = ref.current;
    if (!c) return;
    const ctx = c.getContext('2d');
    if (!ctx) return;
    ctx.imageSmoothingEnabled = false; // crisp pixels
    ctx.clearRect(0, 0, c.width, c.height);
    for (let y = 0; y < frame.length; y++) {
      for (let x = 0; x < frame[y].length; x++) {
        const idx = frame[y][x];
        if (idx === 0) continue; // transparent
        ctx.fillStyle = palette[idx] ?? '#f0f';
        ctx.fillRect(x * scale, y * scale, scale, scale);
      }
    }
  }, [frame, palette, scale]);
  return <canvas ref={ref} width={16 * scale} height={16 * scale} />;
}
```

**Step 2: Mount in `App.tsx`**

```tsx
const [data, setData] = useState<SpriteData | null>(null);
const [paletteMap, setPaletteMap] = useState<Record<string, Palette> | null>(null);
useEffect(() => {
  loadSprite('/data/cat.json').then(setData);
  fetch('/data/palettes.json').then(r => r.json()).then(setPaletteMap);
}, []);
if (!data || !paletteMap) return <div>Loading...</div>;
const palette = paletteMap.default;
const idleFrame = data.baby.idle[0];
return <div><SpriteCanvas frame={idleFrame} palette={palette} /></div>;
```

**Step 3: Verify** — open dev server. Should see static cat. Commit.

```bash
git commit -m "feat(pet-prototype): canvas sprite renderer + integration in App"
```

---

### Task 6: Animation loop — idle frames at 6 FPS

**Files:**
- Create: `docs/pet-design/web-prototype/src/animation/useFrameAnimation.ts`
- Modify: `docs/pet-design/web-prototype/src/App.tsx`

```ts
// useFrameAnimation.ts
import { useEffect, useState } from 'react';
export function useFrameAnimation(totalFrames: number, fps = 6): number {
  const [frame, setFrame] = useState(0);
  useEffect(() => {
    const id = setInterval(() => {
      setFrame(f => (f + 1) % totalFrames);
    }, 1000 / fps);
    return () => clearInterval(id);
  }, [totalFrames, fps]);
  return frame;
}
```

In `App.tsx`:
```tsx
const idleFrames = data.baby.idle;
const frameIdx = useFrameAnimation(idleFrames.length);
return <SpriteCanvas frame={idleFrames[frameIdx]} palette={palette} />;
```

Verify cat now animates. Commit: `feat(pet-prototype): 6 FPS idle animation loop`.

---

### Task 7: Pet stage component — pet on a ground line, breath bob

**Files:**
- Create: `docs/pet-design/web-prototype/src/stage/PetStage.tsx`

**Step 1: Stage with breath**

```tsx
export function PetStage({ children }: { children: React.ReactNode }) {
  const [bobY, setBobY] = useState(0);
  useEffect(() => {
    const id = setInterval(() => {
      setBobY(prev => prev === 0 ? -2 : 0); // toggle 1px = scaled 2px
    }, 1000); // 0.5 Hz
    return () => clearInterval(id);
  }, []);
  return (
    <div style={{
      position: 'relative',
      width: 360, height: 240,
      background: 'linear-gradient(180deg, #f5f5f7 60%, #d8d8dc 100%)',
      borderRadius: 12,
      overflow: 'hidden'
    }}>
      <div style={{
        position: 'absolute', left: '50%', top: '60%',
        transform: `translate(-50%, ${bobY}px)`,
        transition: 'transform 1s ease-in-out'
      }}>
        {children}
      </div>
      {/* ground line */}
      <div style={{
        position: 'absolute', left: 0, right: 0, top: '78%', height: 1,
        background: 'rgba(0,0,0,0.06)'
      }} />
    </div>
  );
}
```

**Step 2:** Replace App.tsx render with `<PetStage><SpriteCanvas .../></PetStage>`.

**Step 3:** Commit `feat(pet-prototype): PetStage with ground line + breath bob`.

---

## Phase 3 — Soft lighting + motion polish

### Task 8: Drop shadow under sprite

**Files:**
- Modify: `docs/pet-design/web-prototype/src/stage/PetStage.tsx`

Add an elliptical shadow div behind the sprite:

```tsx
<div style={{
  position: 'absolute', left: '50%', bottom: 16,
  transform: 'translateX(-50%)',
  width: 96, height: 14,
  background: 'radial-gradient(ellipse, rgba(0,0,0,0.18), transparent 70%)',
  filter: 'blur(2px)',
}} />
```

Manually verify the shadow follows the sprite as it bobs (it doesn't yet because shadow is fixed position; that's fine for now — adjust later).

Commit: `feat(pet-prototype): drop shadow on stage`.

---

### Task 9: Rim light overlay (subtle right-edge highlight)

**Files:**
- Create: `docs/pet-design/web-prototype/src/render/applyRimLight.ts`
- Modify: `docs/pet-design/web-prototype/src/render/SpriteCanvas.tsx`

**Step 1:** Apply rim light by detecting the rightmost non-transparent pixel of each row and brightening it.

```ts
// applyRimLight.ts
export function applyRimLight(ctx: CanvasRenderingContext2D, frame: Frame, scale: number, palette: Palette) {
  // For each row, find the rightmost non-transparent pixel; overdraw with brighter shade
  for (let y = 0; y < frame.length; y++) {
    let rightmost = -1;
    for (let x = frame[y].length - 1; x >= 0; x--) {
      if (frame[y][x] !== 0) { rightmost = x; break; }
    }
    if (rightmost >= 0) {
      ctx.fillStyle = 'rgba(255,255,255,0.35)';
      ctx.fillRect(rightmost * scale, y * scale, scale, scale);
    }
  }
}
```

**Step 2:** Call from SpriteCanvas after the main render pass.

Commit: `feat(pet-prototype): rim light overlay`.

---

## Phase 4 — Trait system

### Task 10: Trait state + slider UI

**Files:**
- Create: `docs/pet-design/web-prototype/src/traits/types.ts`
- Create: `docs/pet-design/web-prototype/src/traits/TraitPanel.tsx`
- Modify: `docs/pet-design/web-prototype/src/App.tsx`

**Step 1: Types**

```ts
// traits/types.ts
export type TraitName = 'independent' | 'curious' | 'timid' | 'mischievous';
export type Traits = Record<TraitName, number>; // 0-100
export const defaultTraits: Traits = {
  independent: 50, curious: 70, timid: 30, mischievous: 40,
};
```

**Step 2: TraitPanel**

```tsx
export function TraitPanel({ traits, setTraits }: {
  traits: Traits; setTraits: (t: Traits) => void;
}) {
  return (
    <div style={{ padding: 16, display: 'grid', gap: 8 }}>
      {(Object.keys(traits) as TraitName[]).map(k => (
        <label key={k} style={{ display: 'flex', alignItems: 'center', gap: 8 }}>
          <span style={{ width: 110, textTransform: 'capitalize' }}>{k}</span>
          <input
            type="range" min={0} max={100}
            value={traits[k]}
            onChange={e => setTraits({ ...traits, [k]: +e.target.value })}
          />
          <span style={{ width: 30 }}>{traits[k]}</span>
        </label>
      ))}
    </div>
  );
}
```

**Step 3:** Add `<TraitPanel />` next to the stage in App.

Commit: `feat(pet-prototype): trait state + slider panel`.

---

### Task 11: Trait-driven idle action selection

**Files:**
- Create: `docs/pet-design/web-prototype/src/traits/idleSelector.ts`
- Create: `docs/pet-design/web-prototype/src/traits/__tests__/idleSelector.test.ts`
- Modify: App.tsx

**Step 1: Failing test**

```ts
test('high curious selects walking more often than idle', () => {
  const samples = Array.from({ length: 200 }, () =>
    selectIdleAction({ independent: 0, curious: 90, timid: 0, mischievous: 0 })
  );
  const walkRatio = samples.filter(a => a === 'walking').length / 200;
  expect(walkRatio).toBeGreaterThan(0.4); // significantly above default
});
```

**Step 2: Implementation**

```ts
// idleSelector.ts
export type IdleAction = 'idle' | 'walking' | 'sleeping' | 'happy';
export function selectIdleAction(traits: Traits): IdleAction {
  const w = {
    idle: 30 + traits.timid * 0.3 - traits.curious * 0.1,
    walking: 20 + traits.curious * 0.4 + traits.mischievous * 0.2,
    sleeping: 10 + traits.independent * 0.1,
    happy: 5 + traits.curious * 0.05,
  };
  return weightedPick(w);
}

function weightedPick<T extends string>(weights: Record<T, number>): T {
  const total = Object.values(weights).reduce((a, b) => a + b, 0);
  let r = Math.random() * total;
  for (const k in weights) {
    r -= weights[k];
    if (r <= 0) return k as T;
  }
  return Object.keys(weights)[0] as T;
}
```

**Step 3:** In App, every 5 seconds, re-roll idle action based on traits:

```tsx
const [currentAction, setCurrentAction] = useState<IdleAction>('idle');
useEffect(() => {
  const id = setInterval(() => setCurrentAction(selectIdleAction(traits)), 5000);
  return () => clearInterval(id);
}, [traits]);
const frames = data.baby[currentAction] ?? data.baby.idle;
```

**Step 4:** Run tests, commit. `feat(pet-prototype): trait-weighted idle action selection`.

---

### Task 12: Visual mood tint based on traits

**Files:**
- Modify: `docs/pet-design/web-prototype/src/stage/PetStage.tsx`

Tint the stage background subtly based on dominant trait:
- High curious → cool blue
- High timid → pink
- High mischievous → soft yellow
- Default → neutral

```tsx
function moodAccent(traits: Traits): string {
  const dominant = (Object.entries(traits) as [TraitName, number][])
    .sort((a, b) => b[1] - a[1])[0][0];
  return {
    curious: 'rgba(180, 220, 255, 0.4)',
    timid: 'rgba(255, 200, 220, 0.4)',
    mischievous: 'rgba(255, 240, 180, 0.4)',
    independent: 'rgba(220, 220, 230, 0.4)',
  }[dominant];
}
```

Apply as a subtle gradient overlay in PetStage. Commit: `feat(pet-prototype): mood-based stage accent tint`.

---

## Phase 5 — Peer meeting + ambient companion

### Task 13: Second pet rendered on stage

**Files:**
- Modify: `docs/pet-design/web-prototype/src/App.tsx`
- Modify: `docs/pet-design/web-prototype/src/stage/PetStage.tsx`

**Step 1:** Refactor PetStage to accept multiple pets via children-array or pet props:

```tsx
type PetView = { x: number; frame: Frame; palette: Palette; scale?: number; flipped?: boolean };
function PetStage({ pets }: { pets: PetView[] }) { ... }
```

**Step 2:** Render pets at different x positions; flip the second (mirrored) so they face each other.

**Step 3:** Toggle "Peer connected" via a button in App. When true, second pet renders at right side.

Commit: `feat(pet-prototype): second pet on stage with toggle`.

---

### Task 14: Walk-in animation when peer connects

**Files:**
- Create: `docs/pet-design/web-prototype/src/animation/usePosition.ts`
- Modify: App.tsx

**Step 1:** When peer-connected toggles true, animate second pet's `x` from offscreen-right to its idle position over 1.5s.

Use a simple eased animation:
```ts
function useEasedX(target: number, duration = 1500): number {
  const [x, setX] = useState(target);
  const start = useRef<{ from: number; to: number; t0: number } | null>(null);
  useEffect(() => {
    start.current = { from: x, to: target, t0: performance.now() };
    let raf: number;
    const tick = () => {
      const now = performance.now();
      const p = Math.min(1, (now - start.current!.t0) / duration);
      const eased = 1 - Math.pow(1 - p, 3); // ease-out cubic
      setX(start.current!.from + (start.current!.to - start.current!.from) * eased);
      if (p < 1) raf = requestAnimationFrame(tick);
    };
    raf = requestAnimationFrame(tick);
    return () => cancelAnimationFrame(raf);
  }, [target]);
  return x;
}
```

**Step 2:** Use this hook for the second pet's x. When connected, target moves from 600 (offscreen) to 240. Animate `walking` action while moving.

Commit: `feat(pet-prototype): walk-in animation on peer connect`.

---

### Task 15: Greeting beat — trait-driven first interaction

**Files:**
- Create: `docs/pet-design/web-prototype/src/scenarios/greeting.ts`
- Modify: App.tsx

**Step 1:** When peer arrives, run a scripted "greeting" sequence based on local pet traits:
- High curious → run toward peer (sniff action), 1.5s
- High timid → step back (idle, no movement)
- High mischievous → poke (tapReact frame)
- High independent → glance once, then look away

```ts
export type GreetingBeat = {
  action: Action;
  duration: number;
  xOffset?: number;
};
export function selectGreeting(traits: Traits): GreetingBeat {
  const dom = dominantTrait(traits);
  switch (dom) {
    case 'curious': return { action: 'walking', duration: 1500, xOffset: 60 };
    case 'timid':   return { action: 'scared',  duration: 1200, xOffset: -30 };
    case 'mischievous': return { action: 'tapReact', duration: 800 };
    case 'independent': return { action: 'idle', duration: 600 };
  }
}
```

**Step 2:** Sequence: peer walks in → greeting beat plays → both return to ambient idle.

**Step 3:** Commit. `feat(pet-prototype): trait-driven greeting beat`.

---

## Phase 6 — Tap interaction

### Task 16: Click on pet → tapReact + heart particles

**Files:**
- Modify: `docs/pet-design/web-prototype/src/stage/PetStage.tsx`
- Create: `docs/pet-design/web-prototype/src/render/Particles.tsx`

**Step 1:** Click on pet → switches to `tapReact` action briefly (0.6s), then back to idle.

**Step 2:** Spawn 3-5 heart particles from the pet's center. Each particle: pixel "♥" rendered on a small canvas, animates upward with gravity and fade.

```tsx
type Particle = { id: number; x: number; y: number; vx: number; vy: number; life: number };
// useEffect with requestAnimationFrame, decrement life, advance position
```

**Step 3:** Trait modulation: high mischievous → fewer hearts, more "?" particles (dodge/play hard-to-get). High timid → tiny hearts.

Commit: `feat(pet-prototype): tap interaction with heart particles`.

---

## Phase 7 — File transfer choreography

### Task 17: Transfer scenario — progress bar + dual-pet stance

**Files:**
- Create: `docs/pet-design/web-prototype/src/scenarios/Transfer.tsx`
- Modify: App.tsx (add scenario buttons)

**Step 1:** Layout: progress bar centered between the two pets. Local pet on left, peer pet on right. Both face toward the bar.

**Step 2:** Animate progress 0 → 100% over 4s. During transfer:
- Both pets play `idle` but lean toward bar
- Tail/ear small movements (palette-shift highlight pulse)

**Step 3:** On completion: both pets play `happy` action, particles erupt.

Commit: `feat(pet-prototype): transfer scenario with dual-pet choreography`.

---

### Task 18: Transfer failure variant — mood-flavored reactions

**Files:**
- Modify: `docs/pet-design/web-prototype/src/scenarios/Transfer.tsx`

When transfer is "failed":
- Local pet (per dominant trait):
  - Independent: idle, looks away
  - Curious: looks confused (idle frame held)
  - Timid: scared action, shrinks
  - Mischievous: tapReact action, smug shrug
- Peer pet does the same per simulated peer trait

Commit: `feat(pet-prototype): transfer failure trait-flavored reactions`.

---

## Phase 8 — Dialogue system

### Task 19: Dialogue bubble component + phrase pool

**Files:**
- Create: `docs/pet-design/web-prototype/src/dialogue/DialogueBubble.tsx`
- Create: `docs/pet-design/web-prototype/src/dialogue/pool.ts`
- Create: `docs/pet-design/web-prototype/src/dialogue/select.ts`
- Create: `docs/pet-design/web-prototype/src/dialogue/__tests__/select.test.ts`

**Step 1: Pool**

```ts
// pool.ts
export type DialogueLine = {
  text: string;
  context: 'idle' | 'greeting' | 'transferSuccess' | 'transferFail' | 'tap';
  traitWeights: Partial<Record<TraitName, number>>; // higher = more likely for that trait
};
export const linePool: DialogueLine[] = [
  { text: '...', context: 'idle', traitWeights: { timid: 80, independent: 30 } },
  { text: 'Whoa, what\'s that?', context: 'idle', traitWeights: { curious: 90 } },
  { text: 'meh.', context: 'idle', traitWeights: { independent: 80 } },
  { text: 'heh.', context: 'tap', traitWeights: { mischievous: 90 } },
  { text: '!', context: 'tap', traitWeights: { timid: 70 } },
  { text: 'Yay!!', context: 'transferSuccess', traitWeights: { curious: 60, mischievous: 60 } },
  { text: '...nice.', context: 'transferSuccess', traitWeights: { independent: 80, timid: 60 } },
  // ... 30+ lines covering each context × trait combo
];
```

**Step 2: Selector with test**

```ts
// __tests__/select.test.ts
test('high mischievous selects "heh." for tap', () => {
  const traits = { independent: 0, curious: 0, timid: 0, mischievous: 100 };
  const samples = Array.from({ length: 50 }, () => selectLine(traits, 'tap'));
  expect(samples.filter(l => l.text === 'heh.').length).toBeGreaterThan(20);
});
```

```ts
// select.ts
export function selectLine(traits: Traits, ctx: DialogueLine['context']): DialogueLine {
  const candidates = linePool.filter(l => l.context === ctx);
  const weights = candidates.map(l => {
    let w = 1;
    for (const [trait, weight] of Object.entries(l.traitWeights)) {
      w += (traits[trait as TraitName] / 100) * weight;
    }
    return w;
  });
  return weightedPickByIndex(candidates, weights);
}
```

**Step 3:** DialogueBubble — pixel-style speech bubble above pet using `.ultraThinMaterial`-like translucent CSS.

Commit: `feat(pet-prototype): dialogue pool + trait-weighted selector`.

---

### Task 20: Wire dialogue to scenarios

**Files:**
- Modify: App.tsx
- Modify: scenarios

When tap fires, also pick + show a tap-context line for 2s. Same for greeting, transferSuccess, transferFail. Cap concurrent bubbles to 1.

Commit: `feat(pet-prototype): wire dialogue to interaction scenarios`.

---

## Phase 9 — Polish + deploy

### Task 21: Layout polish + minimal app chrome

**Files:**
- Modify: App.tsx, App.css

Layout:
- Header: "PeerDrop Pet Prototype — v0"
- Main: PetStage at center
- Left sidebar: TraitPanel
- Right sidebar: scenario buttons (peer connect, transfer success, transfer fail, evolution placeholder)
- Footer: "Designed 2026-04-25. See design doc for context."

CSS: light/dark mode via `prefers-color-scheme`.

Commit: `style(pet-prototype): layout + chrome polish`.

---

### Task 22: Vercel deployment + README

**Files:**
- Create: `docs/pet-design/web-prototype/README.md`
- Create: `docs/pet-design/web-prototype/vercel.json` (if needed)

**Step 1:** Add `npm run build` works locally:

```bash
cd docs/pet-design/web-prototype && npm run build
```

Verify `dist/` produced with `index.html` + assets.

**Step 2:** README with screenshots + how to run locally + deploy.

```markdown
# PeerDrop Pet Prototype

Web prototype of the v3.5+ pet companion redesign. See
`../../plans/2026-04-25-pet-companion-redesign-design.md` for context.

## Run locally

\`\`\`bash
npm install
npm run dev
\`\`\`

Open http://localhost:5173/.

## Deploy

\`vercel\` (with project linked) or push the \`dist/\` to any static host.
```

**Step 3:** If user has Vercel CLI configured, run `vercel --prod` to deploy. Otherwise commit and instruct user to deploy.

Commit: `docs(pet-prototype): README + Vercel config`.

---

## Phase 10 — PR + iteration

### Task 23: Open PR for v0

**Step 1:** Push branch.

**Step 2:** PR title: `prototype(pet): v0 web demo for companion redesign`

**Step 3:** PR body:
- Link to design doc
- Vercel preview URL
- Screenshots of: idle, peer connect, transfer success, transfer fail, tap interaction
- Iteration plan (v1, v2 TBD based on feedback)

After PR merges, the user reviews live demo, gives feedback. Future tasks (v1, v2) added to a follow-up plan based on that feedback.

---

## Out of scope for this plan

- SwiftUI port (separate plan once web design is approved)
- Real cross-pet network protocol
- Sound design / haptics
- Multi-language dialogue authoring (English placeholder only in v0)
- Full coverage of all 10 species (cat only)
- Mid/lower tier interactions from §4 of the design doc

---

## Estimated timeline

23 bite-sized tasks. Realistic pace at subagent-driven cadence: ~6-8 hours of focused work, including reviews. Single session feasible if scope is held.
