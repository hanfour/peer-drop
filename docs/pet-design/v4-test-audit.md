# v4.0 Pet Test Suite Audit (M11.1)

**Snapshot date:** 2026-05-04
**Branch:** `feat/v4-png-pipeline` @ M10 complete
**Suite size:** 913 tests, 0 failures, ~29 s wall clock

This is the M11.1 audit promised by `docs/plans/2026-04-29-v4.0-pet-png-pipeline-plan.md` §M11.1. Most of the work the plan budgeted under **M11.2 Updates** and **M11.3 New** has already happened naturally as each milestone (M0–M10) updated and added tests for its own concerns. M11 reduces to verification + this audit doc.

## Bucket categorisation

### ✅ Stays — model logic, mood transitions, age promotion (unchanged contract)

These tests exercise pet domain logic that survived v4.0 conceptually intact. Most were lightly touched by M1.1 (PetLevel rename) but are otherwise pristine.

| File | Notes |
|---|---|
| `PetActionTests.swift` | PetAction enum cases — survived |
| `PetActivityManagerTests.swift` | Live Activity wiring; updated for V3 image bridge |
| `PetAnimationControllerV2Tests.swift` | Animator frame counter; v4.0 keeps the animator |
| `PetAnimationLifecycleTests.swift` | Animator start/stop; unchanged |
| `PetBehaviorControllerTests.swift` | Behaviour FSM; unchanged |
| `PetBehaviorProviderTests.swift` | Per-species behaviour profiles; unchanged |
| `PetChatInteractionTests.swift` | Interaction → mood mapping; unchanged |
| `PetDailyLoginTests.swift` | Daily reward gate; unchanged |
| `PetDialogEngineTests.swift` | Dialogue templates per mood; updated for `.adult` rename |
| `PetExitEnterTests.swift` | View lifecycle; unchanged |
| `PetFeedingTests.swift` | Food/digestion FSM; unchanged |
| `PetInteractionTests.swift` | Interaction throttling; unchanged |
| `PetNamingTests.swift` | Pet rename flow; unchanged |
| `PetPalettesTests.swift` | ColorPalette resolution; v3.x palette logic kept (used by Pet/Model) |
| `PetPhysicsEngineTests.swift` | Physics integration; unchanged |
| `PetSocialEngineTests.swift` | PetMeeting + secret reveal; unchanged |
| `PetTrustVerificationTests.swift` | Pairing trust; unchanged |
| `IslandPoseTests.swift` | Mood → Live Activity pose mapping; unchanged |
| `PoopStateTests.swift` | Poop spawn + cleanup; unchanged |
| `MoodAndPalettesTests.swift` | Mood enum surface; unchanged |
| `PetStateTests.swift` | PetState model; M1.1 rename applied |
| `PetGenomeV2Tests.swift` | PetGenome model; M1.1 rename applied |

### 🔄 Updates — touched by v4.0 milestones

Tests that called M-numbered milestone code and got drag-along updates:

| File | Updated in | Why |
|---|---|---|
| `PetEvolutionTests.swift` | M1.2 | 3-day age threshold → 8-day age-only; M4.4 stale-test fix |
| `PetEvolutionEffectTests.swift` | M1.2 + M4.4 | Same threshold change |
| `PetSnapshotRendererTests.swift` | (deleted in M8.5) | PetSnapshotRenderer removed wholesale |
| `PetIntegrationTests.swift` | M4.4 | 2 V2-specific tests deleted; M8 phase 5 tested via the renderer migration |
| `PetSpeciesIntegrationTests.swift` | M8.5 | testSpriteRegistryFallbackIntegration removed (legacy registry gone) |
| `GuidanceCardSnapshotTests.swift` | M0 fixup + M2 review | Pre-M0 test rot from `a6b449e` resolved; renamed for assertion honesty in M2 review |
| `PetEngineTests.swift` | M2.4 + M8.2 | New PetGenome fields default-init; PetEngine init grew rendererV3 + sharedRenderedPet params |

### 🗑️ Deletes — pure pixel / [[UInt8]] assertions, gone with M8.5

13 *SpriteData test files + 4 legacy-renderer test files removed when their production code was deleted in M8 phase 5. Plan §M11.1's "Deletes" bucket is fully discharged.

| File | Removed in |
|---|---|
| `BearSpriteDataTests.swift` | M8.5 |
| `BirdSpriteDataTests.swift` | M8.5 |
| `CatSpriteDataTests.swift` | M8.5 |
| `DogSpriteDataTests.swift` | M8.5 |
| `DragonSpriteDataTests.swift` | M8.5 |
| `FrogSpriteDataTests.swift` | M8.5 |
| `GhostSpriteDataTests.swift` | M8.5 |
| `OctopusSpriteDataTests.swift` | M8.5 |
| `RabbitSpriteDataTests.swift` | M8.5 |
| `SlimeSpriteDataTests.swift` | M8.5 |
| `PaletteSwapRendererTests.swift` | M8.5 |
| `SpriteCompositorTests.swift` | M8.5 |
| `SpriteCacheTests.swift` (legacy) | M8.5 |
| `PetRendererV2Tests.swift` | M8.5 |
| `PetSnapshotRendererTests.swift` | M8.5 |
| `SpriteDataRegistryTests.swift` | M8.5 |
| `PetSpriteRegistryTests.swift` | M8.5 |

### 🆕 New — v4.0 PNG pipeline test surface

22 new test files under `PeerDropTests/Pet/`, all created during M0–M10:

| File | Milestone | Coverage |
|---|---|---|
| `SpikeLoaderTests.swift` | M0.2 | Initial spike — proves zip → CGImage round-trip |
| `PetLevelMigrationTests.swift` | M1.1 | Codable rawValue contract for `child` → `adult` |
| `PetLevelPromotionTests.swift` | M1.2 | 8-day baby→adult, 14-day adult→elder |
| `SpeciesIDTests.swift` | M2.1 | Family/variant parsing + Codable |
| `SpeciesCatalogTests.swift` | M2.2 | 34 families / 104 IDs registry |
| `BodyGeneMappingTests.swift` | M2.3 | Legacy BodyGene → SpeciesID |
| `PetGenomeSpeciesTests.swift` | M2.4 + review | Per-pet sub-variety + seeded resolve |
| `SpriteRequestTests.swift` | M3.1 | Cache key + 8-direction enum |
| `SpriteAssetResolverTests.swift` | M3.2 + review | Bundle URL with catalog fallback + `.egg` global |
| `SpriteDecoderTests.swift` | M3.3 + review | 8-dir decode + partial-zip skip-test |
| `SpriteCacheTests.swift` | M3.4 | NSCache wrapper + hit/miss metric |
| `SpriteServiceTests.swift` | M3.5 + review | Actor + concurrent dedup + bulk-fill |
| `PetRendererV3Tests.swift` | M4.1–M4b.2 + M8.5 | Stage/direction/mood overlay + ghost fallback |
| `MoodOverlayTests.swift` | M4b.1 | SF Symbol + tint per mood |
| `MainBundleAssetCoverageTests.swift` | M5.2 | Asset coverage audit + 100-species decode smoke test |
| `PetPayloadCrossVersionTests.swift` | M6.1 | v3.x ↔ v4.0 PetGreeting wire compat + 1000-frame fuzz |
| `PetGreetingProtocolVersionTests.swift` | M6.2 | protocolVersion handshake + elder→adult downgrade |
| `PetStateCloudSyncCompatTests.swift` | M7.1 + review | PetState wire compat + 1000-frame fuzz |
| `PetStoreMigrationTests.swift` | M7.2 + review | first-launch sweep + deterministic FNV seed |
| `SharedRenderedPetTests.swift` | M8.1 | App Group bridge round-trip |
| `PetEngineSharedRenderedPetTests.swift` | M8.2 | PetEngine writes to bridge integration |
| `V4UpgradeOnboardingTests.swift` | M10 | shouldPresent gate (4 states) |

## Test count delta

| Stage | Tests | Notes |
|---|---|---|
| Branch start (pre-M0) | 838 | v3.2.x baseline post-Batch-2 asset gen |
| After M3 (pipeline complete) | 926 | +88: new species/loader/cache/service tests |
| After M5 (assets bundled) | 945 | +19: catalog audit + decode-all |
| After M7 (cloud + migration) | 985 | +40: cross-version + migration sweep |
| After M8 (legacy delete) | 909 | **−76**: legacy *SpriteData / V2 / Compositor tests removed |
| After M10 (current) | 913 | +4: V4 onboarding gate |

Net branch delta: **+75 tests** vs branch start, despite deleting ~85 legacy tests.

## Coverage gaps surfaced + accepted

These were known gaps flagged in earlier reviews and intentionally deferred:

1. **Widget-target tests** (M8 review concern #8) — PetWidget + PetLiveActivity have no direct unit tests. Widget UI testing needs separate framework setup. Defer.
2. **PetIntegrationTests V3 rewrites** (M4.4) — 2 tests deleted; M5 main-bundle integration covers the equivalent end-to-end via `test_mainBundle_endToEnd_decodesEveryMultiVarietySpecies_adultEast`.
3. **Per-species PNG dimension audit** — only cat-tabby's 68×68 is hard-asserted. Other species presumed identical because PixelLab gen used the same template. Easy to add if a regen produces different dims.
4. **PetEngine.handlePetMeeting** — no test exercises the full peer→engine→render→write pipeline. Acceptable: each layer is tested independently.

## Status

✅ M11.1 audit complete. Plan §M11.2 / §M11.3 are placeholders satisfied by per-milestone work; no further M11 commits needed.

Ship-ready test surface: **913 tests, 0 failures**.
