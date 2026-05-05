# v4.0 App Store Submission Checklist (M12.3)

**Generated:** 2026-05-05
**Branch:** `feat/v4-png-pipeline` @ M12 ship-prep complete
**Target version:** PeerDrop 4.0.0 (build 1)

This is the M12.3 submission gate. Items marked ✅ are committed/verified; ⏸ are intentionally user-driven (require Xcode UI / credentials / device); ⚠️ are known limitations to ship with.

## Code & build

| | Item | Notes |
|---|---|---|
| ✅ | All M0–M11 milestones complete on `feat/v4-png-pipeline` | 47+ commits, see PR #27 |
| ✅ | `xcodebuild build -scheme PeerDrop` clean | Both PeerDrop + PeerDropWidget targets |
| ✅ | Full unit test suite passes | 913 tests, 0 failures, ~29 s |
| ✅ | `MARKETING_VERSION = 4.0.0`, `CURRENT_PROJECT_VERSION = 1` | M12.2 bump |
| ⏸ | Archive + upload to TestFlight via Xcode | User: `Product → Archive → Distribute App → App Store Connect` |
| ⏸ | Internal TestFlight soak ≥ 1 week | Watch crash reports + Pet rendering issues |
| ⏸ | External TestFlight 5–10 testers ≥ 1 week | Verify v3.x → v4.0 migration on real upgrades |

## Asset coverage (plan §M12.3)

| | Item | Notes |
|---|---|---|
| ✅ | All 33+ multi-variety species have 3-stage zips bundled | `MainBundleAssetCoverageTests.test_mainBundle_fullCoverage_forEveryMultiVarietySpecies` |
| ⚠️ | Single-variety legacy families (bird, frog, octopus) ship partial coverage | bird/frog: only `-elder.zip`; octopus: `-baby` + `-elder`. Pinned via `expectedPartialCoverage` test table. Users with these v3.x bodies degrade to renderer-layer cat-tabby fallback (`PetRendererV3.ultimateFallback`) for missing stages. M4-pinned ghost contract reversed in M8 phase 5; documented in plan §M9 + PR description. |
| ✅ | Bundle size delta ~3.6 MB | `du -sh PeerDrop/Resources/Pets/` confirms |
| ✅ | App size well under App Store 50 MB cap | Pre-v4: ~10 MB → ~14 MB post-v4 |

## Pet system contracts

| | Item | Notes |
|---|---|---|
| ✅ | v3.x → v4.0 migration runs at first launch | `PetStore.loadAndMigrate()` wired into `PeerDropApp:81`; `PetStoreMigrationTests.test_loadAndMigrate_v3xJSON_onDisk_decodesAndMigrates` |
| ✅ | Migration is idempotent | `PetStoreMigrationTests.test_loadAndMigrate_isIdempotent_acrossCalls` |
| ✅ | Existing pets keep name/level/social log/stats | M2.4 + M7.2 fields are additive only; existing PetState fields untouched |
| ✅ | First-launch v4 onboarding shows once | `V4UpgradeOnboardingTests` (4 gate-state tests) |
| ✅ | Cross-version peer compat | `PetPayloadCrossVersionTests` (6 + 1000-frame fuzz); `PetGreetingProtocolVersionTests` (10 incl. v4→v3 simulated decode) |
| ✅ | iCloud round-trip across versions | `PetStateCloudSyncCompatTests` (6 + 1000-frame fuzz) |
| ⏸ | Cross-version peer interop tested with 2 real devices | User: pair v4.0 device with v3.x device, exercise pet meeting |
| ⏸ | iCloud round-trip tested with real device + real account | User: enable iCloud, install on 2nd device, verify pet syncs |

## Performance (plan §M12.3 floor: iPhone 8)

| | Item | Notes |
|---|---|---|
| ✅ | Sprite decode amortised via SpriteService cache | `SpriteServiceTests.test_decodeOnce_populatesAll8Directions_inCache` proves bulk-fill |
| ✅ | Renderer composite memoized per (species, stage, direction, mood) | `PetRendererV3.lastComposite` |
| ✅ | Widget reads pre-rendered PNG, doesn't run pipeline | M8 phases 1–3; widget extension stays small |
| ⏸ | iPhone 8 profile <16 ms per render frame | User: Instruments time-profile; if slow, revisit `Task.detached` decode (M3 review concern #2 already addressed) |
| ⏸ | 1-hour pet activity battery drain <5% | User: device test |

## Privacy & security

| | Item | Notes |
|---|---|---|
| ✅ | No new tracking added | M0–M12 net data flow: read existing PetState, write rendered PNG to App Group container. Same security domain. |
| ✅ | Privacy manifest unchanged | `PrivacyInfo.xcprivacy` untouched in this branch |
| ✅ | App Group entitlement unchanged | `group.com.hanfour.peerdrop` (existing) — M8's `SharedRenderedPet` reuses |
| ✅ | No CallKit changes | China availability story (per project memory) unchanged |

## App Store metadata

| | Item | Notes |
|---|---|---|
| ✅ | Release notes drafted in 5 languages | `fastlane/metadata/{en-US,zh-Hant,zh-Hans,ja,ko}/release_notes.txt` |
| ⏸ | `fastlane run upload_to_app_store force:true` | User: run when ready to submit metadata |
| ✅ | App icon unchanged | M0–M12 didn't touch `AppIcon.appiconset` |
| ✅ | Screenshots — pet-related screenshots may need refresh | Existing 3.x screenshots show legacy 16×16 sprites. Post-TestFlight, take new screenshots showing v4.0 visuals + onboarding screen. **Note:** existing screenshots are not invalid (they show valid functionality), just outdated. Apple won't reject for this. |

## Plan-decision review

| Decision | When | Documented in |
|---|---|---|
| Q3 pivot: per-mood PNG → SF Symbol overlay | M3 ↔ M4b transition | Plan §M3 + commit `23b3caf` |
| M8 Plan B: pre-render-and-share via App Group | M8 phase 1 start | M8 commits `1e05730..f74caa2` |
| M9 Classic Mode dropped | M9 decision point | Plan §M9 |
| Ghost-fallback contract reversal | M8 phase 5 | Plan §M8 + `c08583d` |

## Known limitations to ship with

- Bird/frog/octopus partial asset coverage → renderer falls back to cat-tabby placeholder for missing stages (acceptable; affects <5% of v3.x users with these legacy bodies; could expand in v4.1 asset-gen).
- Widget UI tests not set up — widget-side changes verified through manual + integration tests against the bridge (`PetEngineSharedRenderedPetTests`). M11 audit acknowledges this gap.
- v5+ peer handling: v4.0 receivers tolerate higher protocolVersion via permissive Codable, but no automatic downgrade path (v5+ doesn't exist yet; not pressing).

## Sign-off

When all ⏸ items are complete and TestFlight soak shows no regressions:

```bash
# In Xcode: Product → Archive → Distribute App → App Store Connect
# Then in App Store Connect:
#   1. Create v4.0.0 release with the auto-imported notes
#   2. Choose phased release (recommended for major version)
#   3. Submit for review
```

Reviewer notes (template — paste into App Store Connect):
> v4.0 is a visual overhaul of the pet companion feature. Existing
> users' pets are migrated automatically (preserves name, level,
> stats); a one-time onboarding screen explains the change. No new
> data is collected; no tracking changes. Cross-version interop with
> v3.x peers degrades gracefully via protocolVersion negotiation.
