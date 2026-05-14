# PixelLab API mass-gen automation (Phase F follow-up)

PixelLab AI ships a public HTTP API (`api.pixellab.ai`). This doc
covers what's automatable, what's not, and the cost/time tradeoff vs
the existing operator-driven Apprentice-tier workflow.

Audience: operator (you) deciding whether to commit to API-driven
mass-gen.

## Why this matters

Per `docs/pet-design/ai-brief/STATUS.md` §0.2, Phase 3 v5 mass-gen is
~5 months of operator UI time on the Apprentice plan. The API
theoretically collapses that to a one-evening batch run. The catch:
the API requires the caller to supply skeleton keypoints frame-by-
frame, whereas the UI applies built-in walk/idle skeletons in one
click.

So the question isn't "can the API do it?" — yes, the endpoints exist.
The question is "is the skeleton preset library you'd need to build
worth it?"

## What's in this commit

Three Python pieces, all in `Scripts/`:

- **`pixellab_client.py`** — full HTTP client. Wraps `/rotate`,
  `/animate-with-skeleton`, `/estimate-skeleton`,
  `/create-image-pixflux`. Auth via `PIXELLAB_API_KEY` env var.
  Retry + backoff on 5xx, surface-immediately on 4xx. 15 unit tests
  (mocked at urllib layer) in `test_pixellab_client.py`.

- **`pixellab_cost.py`** — projects API cost + wall time vs the
  Apprentice subscription path, using live coverage from the bundle.
  Run with no args for the current state; flags for what-if numbers.

- **This doc** — the decision matrix.

## What's NOT in this commit

- An actual orchestrator that takes a species ID, builds the skeleton
  keypoints, calls the API in a loop, and writes a PixelLab-shaped
  zip. That requires the skeleton preset library (see below).
- An end-to-end test against the real API. The client tests use
  mocks; running for-real costs money + an API key the repo doesn't
  carry.

## Cost / time projection (2026-05-14)

```
$ python3 Scripts/pixellab_cost.py
=== PixelLab mass-gen cost projection ===
  Species remaining:        323
  Generations per species:  104
  Retry premium:            +30%
  Total API calls:          43,669

--- Option A: PixelLab API ---
  USD per call:             $0.01
  Total API cost:           $349
  Wall time:                36 hr sequential / 9 hr at 4× parallel

--- Option B: Apprentice subscription + UI clicks ---
  Months @ 2000/mo:         21.8
  Subscription cost:        $262
  Wall time:                ~21.8 months calendar

--- Delta ---
  Cost difference:          API costs $87 more
  Time saved:               655 days
```

The "21.8 months" assumes you hit the quota cap every month — the
realistic operator pace per STATUS.md §0.2 is ~5 months at 1-2
species/day. Either way, the API collapses calendar time by 1-2
orders of magnitude.

## The skeleton preset problem

`/animate-with-skeleton` takes:
- `reference_image`: the character's base PNG (re-use the v4 rotation)
- `skeleton_keypoints`: array of `{x, y, label, z_index}` per frame

The keypoints describe joint positions on the character. For a walk
cycle:
- ~12-14 joints (head, body, hip, knee, ankle ×4 for a quadruped)
- 8 frames showing legs moving back and forth in canonical walk pose
- Same pattern mirrored / repeated for each of the 8 compass
  directions (or use `/estimate-skeleton` to detect per-direction
  variations)

For idle: similar but ~5 frames with subtle bob / sway.

PixelLab's UI ships these skeletons internally. The API doesn't
expose them. To use the API end-to-end you'd need to either:

### Path A — Hand-craft skeleton presets

Design a walk + idle keypoint timeline once per character archetype
(quadruped, biped, no-legged-blob, flying). Apply per character with
slight per-species offsets.

- **Effort:** ~3-5 days of careful design + visual validation. Each
  archetype's walk needs to look natural at 8 fps across 8 dirs.
- **Risk:** Hand-tuned skeletons may not match PixelLab's internal
  ones — visual style of the output may diverge from the v5 cat-tabby
  already shipped.
- **Reusability:** Once built, runs forever; future species just pick
  the right archetype.

### Path B — Use `/estimate-skeleton` + parametric perturbation

Call `/estimate-skeleton` on the v4 reference, get base joint
positions, then apply walk-cycle math (sine wave on leg angles, body
bob, etc.) per frame.

- **Effort:** ~2 days. The walk-cycle math has well-known formulas
  but tuning amplitudes per archetype is iterative.
- **Risk:** Same style-divergence concern as Path A.
- **Reusability:** Stronger — works on novel archetypes without
  hand-tuned presets, just an estimate call.

### Path C — Skip the API for animations, use it only for rotations

The 7 rotations per species are 7/104 ≈ 7% of the work. Not worth
the API integration just for that. **Recommend skipping Path C.**

### Path D — Don't automate, finish via UI

Current trajectory. ~5 months operator time, $60 in subscription cost
($12 × 5).

## Decision matrix

| Path | Dev effort | Cost | Wall time | Risk |
|---|---|---|---|---|
| A. Hand-craft presets | 3-5 days | $349 API + dev time | 9 hr batch | Style divergence |
| B. Estimate + perturbation | 2 days | $349 API + dev time | 9 hr batch | Style divergence (same) |
| C. API rotations only | 1 day | trivial API | minimal saving | low |
| D. UI subscription | 0 days | $60 (over 5 mo) | 5 months calendar | none — proven |

## Recommendation

If TestFlight expansion (#15) is a near-term goal where richer pet
animations would help conversion: **Path B** (estimate + perturbation)
buys you 5 months of calendar time for $349 + 2 dev-days.

If the rest of the product (transfer / chat / IAP) is the priority and
pets are background: **Path D** (continue UI grinding) is fine —
$60/month with no extra engineering burden, and the v5 cat-tabby-adult
already in production proves the renderer works.

The PixelLab API client in this commit doesn't commit you either way.
It's just the foundation that makes Paths A/B/C cheap to start when /
if you decide to.

## To activate

```bash
export PIXELLAB_API_KEY="pl-..."          # from your PixelLab account settings
python3 Scripts/pixellab_client.py --smoke # confirms auth header builds
# ... build orchestrator on top per chosen path
```
