# Pet Companion Redesign — Design Document

**Date:** 2026-04-25
**Status:** Approved — ready for implementation plan
**Authors:** hanfour (PO), Claude Opus 4.7 (collab)

> **For Claude:** REQUIRED NEXT-SKILL: Use **superpowers:writing-plans** to convert this design into a step-by-step implementation plan. From that plan, use **superpowers:subagent-driven-development** to execute, with **frontend-design:frontend-design** invoked by implementer subagents during the web prototype phase.

---

## 1. Vision

> **Two pixel pets, alive on each other's screens.**
>
> PeerDrop's pet evolves from "decoration" to "connection companion". In daily use it breathes in the corner, makes small movements, occasionally speaks. When you connect to a friend, **their pet walks into your screen** — as if you brought them along. When you transfer files, voice-call, or chat, the two pets improvise a duet. Each pet's personality (Independent / Curious / Timid / Mischievous) shapes its movement, dialogue, and initiative, so the user feels "this one is mine".
>
> Visual style: **modern boutique pixel art** (between Stardew Valley and Hades). Existing sprite assets are preserved; presentation is dramatically upgraded — soft shadows, sub-pixel-correct rendering, spring-driven motion, glassmorphic chrome.

The single most distinctive idea: **the peer's pet walking into your screen on connection**. No competitor in the file-sharing space does this; it turns transient connection into felt presence.

---

## 2. Visual Language

Five pillars:

1. **Pixel art principles** — preserve sprite resolution; sub-pixel-correct integer scaling; no anti-aliasing on sprite edges. Existing 6 FPS frame rate stays, but a 1-frame eased intermediate is rendered between sprite frames for a perceived 12 FPS smoothness without new art.

2. **Soft lighting system** — global light source from upper-right; auto-generated elliptical drop shadow (stretches/compresses with movement) plus a one-pixel rim light on the right edge of the sprite. Mood subtly tints the light: warm when happy, cool when sad, pink when shy.

3. **Motion language** — three tiers: (a) idle breath (1–2 px Y-bob @ 0.5 Hz), (b) action sprite frames, (c) transitions (SwiftUI spring, response 0.4, dampingFraction 0.7). All motion is interruption-friendly.

4. **World chrome** — pet stands on a translucent ground line (glassmorphic). Speech bubbles use `.ultraThinMaterial`. Particles (hearts, sweat, music notes, stars) are also pixel art with a subtle motion-blur trail.

5. **Color** — sprite is full color; world chrome is grayscale + a single mood-accent color. The sprite always wins focus. Dark mode darkens the world but keeps sprite untouched and warms the rim light.

---

## 3. Personality Model

Each pet is born with four trait scores, each 0–100. Traits are **preferences**, not exclusives — a single pet can be 70 Curious + 50 Mischievous + 20 Timid simultaneously. Behavior is a weighted mixture.

### Trait × Surface Matrix

| Trait | Idle | Tap reaction | Dialogue | Meeting other pet | Transfer / Call |
|---|---|---|---|---|---|
| **Independent** | wanders, explores screen alone | sometimes ignores; slow head-turn | terse, understated | observes first, approaches slowly | quiet companion |
| **Curious** | stares at new things, sniffs | leaps up excitedly | many questions ("what's that?") | runs over to sniff | watches progress bar; spins on completion |
| **Timid** | huddles in corners, half-crouches | startles → slowly approaches | ellipses, soft tone | hides behind own sprite | shrinks on failure; secretly happy on success |
| **Mischievous** | pushes UI elements, knocks things over | dodges; smirks | quips, dry jokes | steals food, pokes | mocks failed progress; bounces wildly on success |

### Mixture rules

- Multiple traits → behavior is weighted-average of trait reactions.
- Major milestones (Nth peer connection, large successful transfer, accepting a stranger's invite, etc.) have a chance to add 1–3 points to a trait → **personality grows with use**.
- Detail UI shows the **top 2 dominant traits** as a bar chart, never the full attribute table.

### Dialogue system

- Dialogue is short (≤ 1 sentence) drawn from a phrase pool, with each phrase tagged with a trait weight.
- Cap at 3–5 bubbles per day to avoid noise.
- All phrase pools are localized in five languages from day one.

---

## 4. Core Interaction Inventory

Ranked by user priority: **(a) peer meeting + (e) personality + (b) transfer reactions + (c) daily cycle + (d) growth-via-use**.

### Top tier (must ship in v0 of web demo)

1. **Idle alone** — trait-driven ambient behavior; soft shadow; breath
2. **Peer connection greeting** — peer's pet walks in from screen edge; trait combination drives first-contact behavior
3. **Ambient companion** — both pets coexist for the duration of the session; occasionally interact
4. **File transfer choreography** — both pets surround the progress bar; trait-flavored stance/expression; victory or grief reactions
5. **Tap interaction** — direct touch; trait-flavored response strength

### Mid tier

6. Feeding — drag food onto pet; trait-flavored preferences
7. Personality detail view — trait bar chart, recent highlights, friendship score per peer
8. Voice call presence — both pets in a small bottom strip during call
9. Chat reaction — pets peek at messages; nudge the send key
10. Naming / first interaction — pet calls out the new name once

### Lower tier

11. Hatching / Onboarding — egg shake → cracks → break → naming sheet
12. Evolution — light pillar transition; trait-flavored line of dialogue
13. Sleep / background — "Z" bubble before app backgrounds
14. Disconnect goodbye — peer pet waves; trait controls wave amplitude

### Web demo coverage

| Tier | Interactive in prototype | Static mockup | Notes |
|---|---|---|---|
| Top (5) | ✅ all playable | — | sliders for traits; observable behavior diffs |
| Mid (5) | 🟡 partial (feeding playable) | ✅ static + caption | rest are static |
| Lower (4) | — | ✅ static + text | done after top/mid review |

---

## 5. Web Demo: Tech & Delivery

### Stack

- **Vite + React + TypeScript** — fast HMR; component model maps to SwiftUI mental model.
- **Canvas 2D** for the pet stage — sub-pixel rendering, soft shadow, particles.
- No game engine (Phaser / Pixi); we keep dependencies minimal.

### Sprite data bridge

- Run a one-time Swift script to export `CatSpriteData` (baby + child) and `PetPalettes` to JSON files (`cat.json`, `palettes.json`).
- Ship those JSONs in the web prototype repo.
- Cat is the canonical species; demoing one species is enough to validate the design language for all ten.

### Interaction simulation

- Each trait has a 0–100 slider; behavior recomputes live.
- "Fake peer connect" button → second pet walks in, ambient companion engages.
- "Fake file transfer" button → progress bar + dual-pet choreography.
- All events replayable.

### Delivery

- **Source**: `docs/pet-design/web-prototype/` (sibling to this design doc).
- **Local**: `cd docs/pet-design/web-prototype && npm install && npm run dev`.
- **Hosted**: deploy to Vercel; share preview URL for review.

### Iteration cadence

| Version | Scope |
|---|---|
| v0 | Top-tier 5 interactions, single trait combo |
| v1 | Trait sliders, personality-diff demo |
| v2 | File-transfer choreography, dialogue system |
| v3+ | Mid-tier surfaces, polish, dark mode |

Each version: commit + deploy. PO reviews. Iterate.

---

## 6. Out of scope for now

- Full SwiftUI implementation. The web demo's purpose is design alignment; the SwiftUI port becomes a separate plan once the web design is approved.
- Cross-pet network protocol (how peer pets actually transmit each other's state). The web demo simulates locally; the real protocol is a separate problem (likely a small payload added to existing PeerDrop messages).
- Multi-language dialogue corpus authoring. Web demo ships English placeholder copy; localization is a downstream task.
- Sound design. The web demo is silent; sound is a separate iteration.

---

## 7. Success criteria

- Web demo runs locally and deploys to Vercel preview.
- A naive viewer can drag trait sliders and see clearly different pet behavior.
- The peer-meeting interaction reads as "delightful, distinctive" to PO.
- The file-transfer choreography reads as "yes — this turns progress bars into something I look forward to".
- Design language is concrete enough that the SwiftUI port can be planned without further design churn.

---

## 8. Open questions for follow-up

- Real cross-pet protocol design — how peer pet state propagates without inflating relay payload.
- Sound / haptic design — we deliberately deferred.
- "Personality growth" thresholds — what specific milestones add what trait points; needs play-test data.
- Long-tail trait surfaces — what about timid+curious, vs. independent+mischievous; the matrix today shows pure traits, mixtures need play-test.

These are explicitly deferred until the web prototype validates the core design.
