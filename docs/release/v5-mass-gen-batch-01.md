# Phase 3 Mass-Gen — Batch 01 (operator)

**Generated 2026-05-12** from `/tmp/v5-priority.txt`. Owns the next 10 zips
to generate ordered by user-visible impact (genome × stage × variant
probability). Refresh by re-running `python3 Scripts/audit_v5_coverage.py`
once you've completed this batch.

---

## Current state

- **Total zips bundled:** 324
- **At v5 multi-frame schema:** 1 (cat-tabby-adult only)
- **At v4 static:** 323
- **Wrong size (≠68×68):** 257 — full character regen required
- **Already 68×68:** 66 — only need walk-animation export added

Cat-tabby-adult (the one v5 zip) covers ~7% of user pet encounters. Every
zip below adds another 1-7%. **The first 4 entries are 7% each and don't
need character regen** — quickest wins in the project.

---

## Batch 01 — Cat adult sub-varieties (28% impact, 4 zips)

All 4 already 68×68. PixelLab workflow: open existing character by ID →
"Add Animation" → Walk, 8 frames × 8 directions → export → normalize → drop.

Estimated PixelLab cost: 4 species × 8 frames × 8 directions = 256
generations ≈ 12.8% of monthly Apprentice quota (2000/mo).

| Priority | User % | Output zip | PixelLab character ID | Size |
|---:|---:|---|---|---|
| 1 | 7.0% | `cat-bengal-adult.zip` | `4b560d49-...` | 68×68 ✓ |
| 2 | 7.0% | `cat-calico-adult.zip` | `c00cf4e1-...` | 68×68 ✓ |
| 3 | 7.0% | `cat-persian-adult.zip` | `f9d064ed-...` | 68×68 ✓ |
| 4 | 7.0% | `cat-siamese-adult.zip` | `72b4c7c1-...` | 68×68 ✓ |

### Full character IDs (paste into PixelLab URL)

```
cat-bengal-adult:   4b560d49
cat-calico-adult:   c00cf4e1
cat-persian-adult:  f9d064ed
cat-siamese-adult:  72b4c7c1
```

(Truncated for display. Full UUIDs live in each existing v4 zip's
`metadata.json` under `character.id`. To extract:
`unzip -p PeerDrop/Resources/Pets/cat-bengal-adult.zip metadata.json | python3 -c 'import sys,json;print(json.load(sys.stdin)["character"]["id"])'`)

### Per-zip operator commands

After PixelLab exports the raw zip (call it `raw.zip`):

```bash
# Drop, normalize, install, test — one command each
Scripts/drop_v5_zip.sh ~/Downloads/cat-bengal-raw.zip   cat-bengal-adult
Scripts/drop_v5_zip.sh ~/Downloads/cat-calico-raw.zip   cat-calico-adult
Scripts/drop_v5_zip.sh ~/Downloads/cat-persian-raw.zip  cat-persian-adult
Scripts/drop_v5_zip.sh ~/Downloads/cat-siamese-raw.zip  cat-siamese-adult
```

The script:
1. Runs `normalize-pixellab-zip.sh` to map UUID-keyed PixelLab schema → v3.0
2. Drops the normalized zip into `PeerDrop/Resources/Pets/`
3. Prints the line to add to `expectedV5Coverage` (the script doesn't edit it)
4. Runs `MainBundleAssetCoverageTests` to validate everything wires up

After all 4 drops, manually add to `expectedV5Coverage`:

```swift
private static let expectedV5Coverage: Set<String> = [
    "cat-tabby-adult",
    "cat-bengal-adult",   // batch 01
    "cat-calico-adult",   // batch 01
    "cat-persian-adult",  // batch 01
    "cat-siamese-adult",  // batch 01
]
```

Then `git add` + commit per the cadence playbook.

---

## Batch 02 — Cat elder sub-varieties (10% impact, 5 zips)

After Batch 01 lands, next-highest impact = elder cats. Same workflow,
all 5 already 68×68. Brings total cat coverage to 5/5 adult + 5/5 elder
(10/15 cat zips at v5). Cat babies still v4 but pets only stay baby for
8 days vs ~82 days adult → babies are the lowest-impact stage.

| Priority | User % | Output zip | char ID |
|---:|---:|---|---|
| 5 | 2.0% | `cat-bengal-elder.zip` | `c29c2355-...` |
| 6 | 2.0% | `cat-calico-elder.zip` | `dc6ccec4-...` |
| 7 | 2.0% | `cat-persian-elder.zip` | `fbb668ab-...` |
| 8 | 2.0% | `cat-siamese-elder.zip` | `e83f33ae-...` |
| 9 | 2.0% | `cat-tabby-elder.zip`   | `fcea4ed7-...` |

After Batch 01 + 02: **all cat owners get v5 walking animation** for 90%
of their pet's life (everything except the 8-day baby window).

---

## After Batch 02 — pick by audit

Re-run `python3 Scripts/audit_v5_coverage.py` (or examine
`/tmp/v5-priority.txt` if cached) and pick the next highest %user
entries. Likely order:

- bird (1.6%, single-variety, 48×48 → full regen needed)
- dog-{shiba/collie/dachshund/husky/labrador}-adult (1.4% each, 7% total, 68×68 ✓)
- rabbit-{angora/dutch/lionhead/lop}-adult (1.4% each, 5.6% total, 68×68 ✓)

bird is single-variety high-impact but needs full character regen
(48×48 → 68×68 size mismatch from STATUS.md §0.3 gotcha). Skip until
PixelLab character is recreated at 68×68. Dog and rabbit adults are
already 68×68 — pick those instead.

---

## PixelLab UI gotchas reminder (from STATUS.md §0.3)

1. **MUST be 68×68.** PixelLab defaults new characters to 48×48. For
   batches 01/02 you're opening EXISTING characters at 68×68 — confirm
   the character's size is 68×68 in PixelLab before adding animations.
2. **Walk animation: 8-frame preset × 8 directions = 64 generations per character.**
3. **Idle is optional in v5.0.x.** Walk is the priority. (Idle frames
   are 1-frame fallback today; even partial idle data is fine, no zip
   is "broken" by missing idle.)
4. **Don't click "Add Animation → Walk" twice on the same character.**
   PixelLab creates a duplicate UUID slot instead of refusing. The
   normalize script auto-dedupes (newest mtime + most frames wins) but
   it costs you the duplicate quota.
5. **Animation metadata key is "walk", not "walking"** — PetAction's
   rawValue is "walking" but the v5 schema key is "walk". The normalize
   script handles this; no manual edit.

---

## Verification after each batch

After landing a batch's zips + updating `expectedV5Coverage`:

1. Focused test: `xcodebuild test -only-testing:PeerDropTests/MainBundleAssetCoverageTests`
2. Visual: `xcodebuild test -only-testing:PeerDropTests/DumpV5FramesForVisualCheck` and open `/tmp/cat-tabby-frames/` — confirm new zips have ≥6-frame walking south/east/west.
3. README badge auto-updates on next `git push origin main` (workflow `.github/workflows/asset-coverage-badge.yml` recomputes).

Estimated total batch time (operator wall clock): 30-60 min per batch
including PixelLab generation latency (~30-90 sec per direction).

---

## Tracking

Update the `expectedV5Coverage` set in
`PeerDropTests/Pet/MainBundleAssetCoverageTests.swift` after each batch.
That's the source of truth. The README badge reads from there.

When all multi-variety species × adult/elder stages are in the set,
flip `phase3Complete = true` in the test file and the acceptance gate
becomes enforced. Babies remain v4-fallback indefinitely — they're a
small window of pet life and lowest priority.
