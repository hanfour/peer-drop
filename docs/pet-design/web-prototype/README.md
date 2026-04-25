# PeerDrop Pet Prototype

Web prototype of the v3.5+ pet companion redesign. Discussion + iteration sandbox before SwiftUI port.

See [`../../plans/2026-04-25-pet-companion-redesign-design.md`](../../plans/2026-04-25-pet-companion-redesign-design.md) for the design context and rationale.

## Quick start

```bash
cd docs/pet-design/web-prototype
npm install
npm run dev
```

Open http://localhost:5173/.

## What's in v0

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

`public/data/cat.json` is exported from `PeerDrop/Pet/Sprites/CatSpriteData.swift` via `scripts/export-sprite.mjs`. Re-run that script if the source Swift sprites change.

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
