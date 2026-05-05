# PeerDrop Pet Prototype

Web prototype of the v3.5+ pet companion redesign. Discussion + iteration sandbox before SwiftUI port.

See [`../../plans/2026-04-25-pet-companion-redesign-design.md`](../../plans/2026-04-25-pet-companion-redesign-design.md) for the design context and rationale.

## Scope (read this first)

This prototype exists to align on **interaction design**, not sprite-art quality.
Reviewers should focus on:

- Peer meeting choreography (walk-in, greeting beats per dominant trait)
- File-transfer reactions (success cheer, failure recoil, dual-pet sync)
- Trait sliders (Independent / Curious / Timid / Mischievous) and their visible effects on idle picks, dialogue, and particle bursts
- Dialogue bubble selection (trait-weighted lines, ambient idle cadence)
- Scene chrome (stage backdrop, accent tint, progress bar, particles)

The cat sprite is a **placeholder**. Production sprite art will be commissioned
separately. Earlier iterations of an in-house hand-painted sprite reached the
limit of what's achievable without a dedicated pixel artist; we have therefore
swapped in a CC0 chibi cat as a "good enough" stand-in so reviewers don't get
stuck nitpicking the art instead of the interactions.

## Quick start

```bash
cd docs/pet-design/web-prototype
npm install
npm run dev
```

Open http://localhost:5173/.

## What's in v0 (interaction features)

- One cat sprite, animated at 6 FPS, breathing + drop shadow
- Four trait sliders (Independent / Curious / Timid / Mischievous) that visibly change behavior
- Mood-accent stage tint based on dominant trait
- Connect peer → second cat walks in, trait-flavored greeting beat
- Tap cat → tapReact + heart particles (variants by trait)
- Transfer success → progress bar + dual-pet cheer + emoji burst
- Transfer fail → progress halts at 70% + trait-flavored failure reactions
- Trait-weighted dialogue bubbles wired to all scenarios + ambient idle

## Tech

- Vite + React + TypeScript
- Canvas 2D for pet rendering
- No game engine — keeps it portable to SwiftUI

## Sprite data

- `public/data/cat.json` (v0 — 16×16) is exported from
  `PeerDrop/Pet/Sprites/CatSpriteData.swift` via `scripts/export-sprite.mjs`.
  Re-run that script if the source Swift sprites change.
- `public/data/cat-v1.json` (v1 — 32×32 side-view placeholder) is imported
  from the **Cat sprites** sheet via `scripts/import-sprite.mjs`. The raw
  source GIF lives at `scripts/side-cat-source/` (kept in-tree so the
  import is fully reproducible offline).

### Asset credit

The v1 sprite is **Cat sprites** by **Shepardskin**, sourced from
[OpenGameArt](https://opengameart.org/content/cat-sprites), licensed under
**CC0 1.0 Universal** (public domain — no attribution legally required). We
credit it anyway because it's good practice and because anyone forking this
prototype should know the asset isn't original work.

The original sheet is a 137×50 pixel-art image with three rows: idle/sit
(5 frames), walk cycle (6 frames), and run cycle (6 frames) — all in
profile, facing right. We picked this asset specifically because the
prototype's hero interaction is "peer's pet walks IN from the screen edge",
which only reads as locomotion when the sprite is in profile. The earlier
front-facing **Tiny Cat Sprite** by Segel was cuter as a stationary chibi
but couldn't sell the walk-in beat — it just bobbed in place.

The importer slices the sheet into per-row frames, drops the lavender
background to transparent, and places each frame onto a 32×32 canvas with
feet anchored to `groundY=29`. Source-frame substitutions used to fill our
schema:

| Our action | Source frames | Note |
|---|---|---|
| `idle` | row 1 (sit) frames 0–3 | sit + small head turns |
| `walking` | row 2 (walk) frames 0,2,3,5 | evenly sampled across the 6-frame walk loop |
| `happy` | row 2 frames 1,4 | mid-step "lifted-paw bounce" reads as joy |
| `tapReact` | row 1 frame 3 + row 3 (run) frame 0 | head-turn idle + recoil pose |
| `scared` | row 3 frames 4,5 | tail-end of run cycle = "fleeing" silhouette |

These mappings are documented in `scripts/import-sprite.mjs` so anyone can
re-derive the JSON without spelunking through this README. The cat faces
right in source; the renderer mirrors the peer pet via SpriteCanvas's
`flipped` prop so the two pets face each other on stage.

## Deploy

```bash
npm run build         # produces dist/
```

The `dist/` directory is fully static. Drop it on any static host (Vercel, Netlify, GitHub Pages, S3+CloudFront).

For Vercel:

```bash
vercel deploy        # interactive
# or set up a GitHub integration pointing at this subdir
```

`vercel.json` already configures this directory as the project root with the right build settings.

## Tests

```bash
npm test
```

Vitest unit tests for sprite loading, trait selectors, greeting beat, and dialogue selector.
