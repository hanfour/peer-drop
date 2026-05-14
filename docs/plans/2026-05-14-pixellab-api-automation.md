# PixelLab API mass-gen automation (Phase F follow-up)

PixelLab AI ships a public HTTP API (`api.pixellab.ai`). **API access
requires an active subscription** (confirmed via pixellab.ai/docs/faq
2026-05-14) — the Apprentice tier we already pay for unlocks it.
This doc covers how to use the API to chew through the mass-gen
backlog WITHOUT spending a dollar beyond the existing subscription.

Audience: operator (you) deciding whether to invest the engineering
days that turn quota-paid-but-unused into mass-gen throughput.

## Why this matters

The Apprentice subscription is $12/mo for 2000 generations/mo. The
operator's natural UI pace per `docs/pet-design/ai-brief/STATUS.md`
§0.2 is ~1-2 species/day = 100-200 zips/mo = 10k-20k API calls/mo,
which would FAR exceed the 2000 quota — except no operator actually
sustains daily UI sessions. Realistic UI throughput is much lower,
so most months underutilize the quota that's been paid for.

The API exists to flip that: one batch run per month consumes the
full 2000-call quota in hours, with no extra dollars beyond the
subscription. ~22 months calendar to finish the backlog, but ZERO
clicking and zero overage.

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

## Three scenarios (2026-05-14 numbers)

```
$ python3 Scripts/pixellab_cost.py
=== PixelLab mass-gen budget projection ===
  Species×stages remaining: 323
  Calls per species:        104
  Total API calls needed:   43,669 (with 30% retry premium)
  Apprentice plan:          $12/mo, 2,000 calls/mo included
  Per-call overage rate:    $0.01

★ RECOMMENDED — Scenario 2: API + stay in quota
  Calendar time:            21.8 months
  Subscription cost:        $262 (you pay this anyway)
  Extra dollars:            $0.00 ✓

Scenario 1: UI grinding (status quo)
  Same calendar time as #2 (quota-bound), but daily UI clicking
  Same total cost. Why prefer #2: one weekend/mo > clicking every day.

Scenario 3: API + accept overage (burst)
  Wall time:                9 hours at 4× parallel
  Extra dollars beyond
  existing subscription:    $333 (41,669 overage calls × $0.008)
```

**The recommended path costs zero additional dollars** — the
subscription is paid baseline, the API just lets you actually use
all 2000 quota each month instead of leaving most of it on the
table. The dev cost (skeleton preset library, below) is the same
across scenarios 2 + 3; only the calendar / dollar tradeoff differs.

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

Current trajectory. Realistic calendar ~22 months bound by Apprentice
quota — same calendar as the API path BUT requires the operator
clicking through 2000 generations every month manually. Same dollar
cost as Path B (subscription only). Worst-of-both: operator labor +
slow calendar.

## Decision matrix (subscription is paid baseline)

| Path | Dev effort | Extra $ beyond sub | Calendar | Operator labor / month |
|---|---|---|---|---|
| A. Hand-craft presets | 3-5 days | $0 | 22 mo | 1 weekend (batch run) |
| **B. Estimate + perturbation** | **2 days** | **$0** | **22 mo** | **1 weekend (batch run)** |
| B-burst. Same + accept overage | 2 days | $333 | **1 mo** | 1 weekend total |
| C. API rotations only | 1 day | $0 | ~22 mo | UI for animations + 1 hr/mo for rotations |
| D. UI grinding (status quo) | 0 days | $0 | 22 mo | Daily UI clicking |

## Recommendation

**Path B** is the answer for this audit's "no extra cost" framing:
~2 days of skeleton-orchestration dev → zero ongoing dollars beyond
the subscription you already pay → 22 months of unattended monthly
batch runs instead of 22 months of daily UI clicking.

Path B-burst is the answer if calendar time matters more than $333.
TestFlight #15 readiness or "we want richer pets before a marketing
push" are the realistic triggers. Defer the burst decision until the
plain-Path-B run is producing batches and the visual quality is
proven against the v5 cat-tabby-adult baseline.

The PixelLab API client in this commit doesn't commit you either way.
It's just the foundation that makes Paths A/B cheap to start when /
if you decide to invest the 2 dev days.

## To activate

```bash
export PIXELLAB_API_KEY="pl-..."          # from your PixelLab account settings
python3 Scripts/pixellab_client.py --smoke # confirms auth header builds
# ... build orchestrator on top per chosen path
```
