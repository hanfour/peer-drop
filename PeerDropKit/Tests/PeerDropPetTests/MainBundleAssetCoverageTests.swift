import XCTest
import PeerDropPet
@testable import PeerDropPet

/// Audits the M5-bundled species assets against the M2.2 SpeciesCatalog.
/// Catches asset-gen regressions early — if a species ID is added to the
/// catalog but the corresponding zip isn't bundled (or vice versa), these
/// tests fail at the next CI run rather than at first user render.
final class MainBundleAssetCoverageTests: XCTestCase {

    // Use SpriteAssetResolver.moduleBundle (PeerDropPet's Bundle.module) so
    // coverage tests audit the production bundle, not the test bundle.
    // Bundle.module in a test file resolves to PeerDropPetTests.bundle;
    // the production zips live in PeerDropPet.bundle.
    private var mainBundle: Bundle { SpriteAssetResolver.moduleBundle }

    /// Single-variety legacy families ship partial coverage from the
    /// pre-Batch-2 era. Single source of truth for both:
    ///   • which species the full-coverage tests skip
    ///   • exact stage sets the partial-coverage test asserts
    /// Update when asset gen fills gaps; entries with all 3 stages can be
    /// removed entirely (the species then participates in full-coverage).
    private static let expectedPartialCoverage: [SpeciesID: Set<String>] = [
        SpeciesID("bird"):    ["elder"],          // bird-elder.zip only; no bird-baby/-adult
        SpeciesID("frog"):    ["elder"],          // frog-elder.zip only
        SpeciesID("octopus"): ["baby", "elder"],  // octopus-adult missing
    ]

    private static var partialCoverageIDs: Set<SpeciesID> {
        Set(expectedPartialCoverage.keys)
    }

    // MARK: - per-species adult zip presence

    func test_mainBundle_containsAdultZip_forEveryMultiVarietySpecies() {
        var missing: [String] = []
        for id in SpeciesCatalog.allIDs where !Self.partialCoverageIDs.contains(id) {
            let req = SpriteRequest(species: id, stage: .adult, direction: .east)
            if SpriteAssetResolver.url(for: req, in: mainBundle) == nil {
                missing.append(id.rawValue)
            }
        }
        XCTAssertEqual(missing, [],
                       "Missing adult zip for \(missing.count) species: \(missing.joined(separator: ", "))")
    }

    // MARK: - 3-stage coverage

    func test_mainBundle_fullCoverage_forEveryMultiVarietySpecies() {
        var partial: [(id: String, stages: [String])] = []
        for id in SpeciesCatalog.allIDs where !Self.partialCoverageIDs.contains(id) {
            var present: [String] = []
            for stage in [PetLevel.baby, .adult, .elder] {
                let req = SpriteRequest(species: id, stage: stage, direction: .east)
                if SpriteAssetResolver.url(for: req, in: mainBundle) != nil {
                    present.append(stage.assetSlug)
                }
            }
            if present.count != 3 {
                partial.append((id.rawValue, present))
            }
        }
        let summary = partial
            .map { "\($0.id)(\($0.stages.joined(separator: "+")))" }
            .joined(separator: ", ")
        XCTAssertEqual(partial.count, 0,
                       "Expected 3-stage coverage for every multi-variety species. Partial: \(summary)")
    }

    // MARK: - locked legacy partial coverage

    func test_mainBundle_legacySingleVarietyFamilies_haveExpectedPartialCoverage() {
        for (id, expectedStages) in Self.expectedPartialCoverage {
            for stage in [PetLevel.baby, .adult, .elder] {
                let req = SpriteRequest(species: id, stage: stage, direction: .east)
                let url = SpriteAssetResolver.url(for: req, in: mainBundle)
                if expectedStages.contains(stage.assetSlug) {
                    XCTAssertNotNil(url,
                                    "\(id.rawValue) at \(stage.assetSlug) should be bundled but resolver returned nil")
                } else {
                    XCTAssertNil(url,
                                 "\(id.rawValue) at \(stage.assetSlug) unexpectedly resolved to \(url?.lastPathComponent ?? "nil") — update expectedPartialCoverage[]?")
                }
            }
        }
    }

    // MARK: - single-stage species

    /// Single-stage species (`SpriteAssetResolver.singleStageSpecies`) ship one
    /// zip total — the bare family ID, no stage suffix — and the same asset is
    /// returned for every PetLevel. Pins the expectation that every entry has
    /// a bundled `<id>.zip`. Currently the set is empty (no shipping family
    /// uses single-asset bundling); the test stays as plumbing in case a
    /// future species adopts that layout.
    func test_mainBundle_containsBareZip_forEverySingleStageSpecies() {
        var missing: [String] = []
        for id in SpriteAssetResolver.singleStageSpecies {
            let req = SpriteRequest(species: id, stage: .adult, direction: .east)
            if SpriteAssetResolver.url(for: req, in: mainBundle) == nil {
                missing.append(id.rawValue)
            }
        }
        XCTAssertEqual(missing, [],
                       "Missing bare zip for \(missing.count) single-stage species: \(missing.joined(separator: ", "))")
    }

    // MARK: - end-to-end render via main bundle

    func test_mainBundle_endToEnd_decodesCatTabbyAdultEast() async throws {
        let service = SpriteService(cache: SpriteCache(countLimit: 30), bundle: mainBundle)
        let req = SpriteRequest(species: SpeciesID("cat-tabby"), stage: .adult, direction: .east)
        let cg = try await service.image(for: req)
        XCTAssertEqual(cg.width, Int(AssetSpec.canonicalCanvas.width))
        XCTAssertEqual(cg.height, Int(AssetSpec.canonicalCanvas.height))
    }

    /// End-to-end decode of every multi-variety species' adult-east frame.
    /// Catches corrupt zips that pass URL resolution but fail decoding —
    /// distinct from the URL-only coverage tests above. Cache size is set
    /// to 8 (one direction × ~one species in flight) to avoid hoarding;
    /// the per-zip decode is sequential and serialised through the actor,
    /// so wall-clock cost is N × ~5–20 ms per zip ≈ 1–2 seconds for 100+
    /// species.
    func test_mainBundle_endToEnd_decodesEveryMultiVarietySpecies_adultEast() async throws {
        let service = SpriteService(cache: SpriteCache(countLimit: 8), bundle: mainBundle)
        var failures: [(id: String, error: String)] = []

        for id in SpeciesCatalog.allIDs where !Self.partialCoverageIDs.contains(id) {
            let req = SpriteRequest(species: id, stage: .adult, direction: .east)
            do {
                let cg = try await service.image(for: req)
                if cg.width == 0 || cg.height == 0 {
                    failures.append((id.rawValue, "zero-dim CGImage (w=\(cg.width), h=\(cg.height))"))
                }
            } catch {
                failures.append((id.rawValue, String(describing: error)))
            }
        }

        XCTAssertEqual(failures.count, 0,
                       "Decode failures: \(failures.map { "\($0.id): \($0.error)" }.joined(separator: "; "))")
    }

    // MARK: - Phase 4 prep — v5 schema coverage tracking

    /// Source of truth for "which bundled zips currently ship at v5.0
    /// schema (export_version 3.0)". Operator updates this set after each
    /// `Scripts/normalize-pixellab-zip.sh` run drops a v5 zip into
    /// `PeerDrop/Resources/Pets/`. When this set equals every (species,
    /// stage) entry in SpeciesCatalog (minus expectedPartialCoverage),
    /// Phase 3 mass-gen is functionally complete and the
    /// `phase3AcceptanceGate` test below can be un-skipped.
    ///
    /// Format: `<species-id>-<stage-slug>` to match the bundled zip
    /// filename, e.g. `cat-tabby-adult` for `cat-tabby-adult.zip`.
    ///
    /// Partial coverage WITHIN a v5 zip (e.g. only south direction
    /// generated) is fine — the C1 fix lets SpriteService gracefully
    /// degrade missing directions to single-frame static. This test only
    /// cares about the schema version flag, not direction completeness.
    private static let expectedV5Coverage: Set<String> = [
        "cat-tabby-adult",  // commit 54f0f69 — partial (south walk only)
        // Mass-gen batch 2026-05-15: 16 cat species via PixelLab API.
        // cat-tabby-adult kept its existing partial v5 zip; mass-gen
        // skipped it because its source zip had no rotations folder.
        "cat-bengal-adult",
        "cat-bengal-baby",
        "cat-bengal-elder",
        "cat-calico-adult",
        "cat-calico-baby",
        "cat-calico-elder",
        "cat-persian-adult",
        "cat-persian-baby",
        "cat-persian-elder",
        "cat-siamese-adult",
        "cat-siamese-baby",
        "cat-siamese-elder",
        "cat-tabby-baby",
        "cat-tabby-elder",
        // Mass-gen batch 2026-05-15 (afternoon): 17 dog species via PixelLab API.
        "dog-collie-adult",
        "dog-collie-baby",
        "dog-collie-elder",
        "dog-dachshund-adult",
        "dog-dachshund-baby",
        "dog-dachshund-elder",
        "dog-husky-adult",
        "dog-husky-baby",
        "dog-husky-elder",
        "dog-labrador-adult",
        "dog-labrador-baby",
        "dog-labrador-elder",
        "dog-shiba-adult",
        "dog-shiba-baby",
        "dog-shiba-elder",
        // Mass-gen batch 3 (2026-05-16): 37 species across bear / fox / pig
        // families (mid-size quadrupeds, same archetype as cat / dog).
        "bear-black-adult",
        "bear-black-baby",
        "bear-black-elder",
        "bear-brown-adult",
        "bear-brown-baby",
        "bear-brown-elder",
        "bear-panda-adult",
        "bear-panda-baby",
        "bear-panda-elder",
        "bear-polar-adult",
        "bear-polar-baby",
        "bear-polar-elder",
        "fox-arctic-adult",
        "fox-arctic-baby",
        "fox-arctic-elder",
        "fox-red-adult",
        "fox-red-baby",
        "fox-red-elder",
        "fox-silver-adult",
        "fox-silver-baby",
        "fox-silver-elder",
        "pig-black-adult",
        "pig-black-baby",
        "pig-black-elder",
        "pig-boar-adult",
        "pig-boar-baby",
        "pig-boar-elder",
        "pig-pink-adult",
        "pig-pink-baby",
        "pig-pink-elder",
        "pig-potbelly-adult",
        "pig-potbelly-baby",
        "pig-potbelly-elder",
        // Mass-gen batch 4 (2026-05-17): 14 rabbit species.
        "rabbit-angora-adult",
        "rabbit-angora-baby",
        "rabbit-angora-elder",
        "rabbit-dutch-adult",
        "rabbit-dutch-baby",
        "rabbit-dutch-elder",
        "rabbit-lionhead-adult",
        "rabbit-lionhead-baby",
        "rabbit-lionhead-elder",
        "rabbit-lop-adult",
        "rabbit-lop-baby",
        "rabbit-lop-elder",
        // Mass-gen batch 5 (2026-05-17): 7 hamster species (partial —
        // hit PixelLab monthly quota mid-batch; white/winterwhite +
        // golden-elder deferred to next month).
        "hamster-campbell-adult",
        "hamster-campbell-baby",
        "hamster-campbell-elder",
        "hamster-golden-adult",
        "hamster-golden-baby",
        // First asset via the gen_pixellab_zip API path (2026-06-13): 64×64
        // (API canvas) + full 8-frame walk / 5-frame idle. Renders identically
        // to the 68×68 UI-export zips.
        "hamster-white-adult",
        // Full-auto batch (2026-06-17): dragon adults — first v5 animation for
        // a high-exposure static BodyGene family. 64×64, 8-frame walk/idle.
        "dragon-western-adult",
        "dragon-eastern-adult",
        "dragon-fire-adult",
        "dragon-ice-adult",
        // Full-auto batch 2 (2026-06-17): slime adults — the other high-exposure
        // static BodyGene family. 64×64, 8-frame walk/idle (blob squash/bounce).
        "slime-green-adult",
        "slime-clear-adult",
        "slime-fire-adult",
        "slime-metal-adult",
        "slime-water-adult",
        // Full-auto batch 3 (2026-06-18): baby+elder for dragon & slime (both
        // core families now animate at every stage) + the available stages of
        // the single-variety families (bird/frog/octopus only ship those
        // stages as sources; their other stages fall back gracefully).
        "dragon-western-baby", "dragon-eastern-baby", "dragon-fire-baby", "dragon-ice-baby",
        "dragon-western-elder", "dragon-eastern-elder", "dragon-fire-elder", "dragon-ice-elder",
        "slime-green-baby", "slime-clear-baby", "slime-fire-baby", "slime-metal-baby", "slime-water-baby",
        "slime-green-elder", "slime-clear-elder", "slime-fire-elder", "slime-metal-elder", "slime-water-elder",
        "bird-elder", "frog-elder", "octopus-baby", "octopus-elder",
        // Full-auto batch 4 (2026-06-18): first 3 expansion families animated at
        // adult (all variants each) — totoro, unicorn, otter. 64×64, 8-frame
        // walk/idle. Remaining expansion families are a low-exposure multi-month
        // tail (run_monthly_batch).
        "totoro-grey-adult", "totoro-large-adult", "totoro-mini-adult", "totoro-white-adult",
        "unicorn-dark-adult", "unicorn-rainbow-adult", "unicorn-white-adult",
        "otter-river-adult", "otter-sea-adult",
    ]

    /// Asserts the `expectedV5Coverage` whitelist exactly matches reality.
    /// Two failure modes both surface here:
    ///   • A bundled zip is v5 but missing from the whitelist → operator
    ///     dropped a v5 zip without updating this file. Add the entry.
    ///   • The whitelist names a zip that's NOT v5 in the bundle → the
    ///     production zip got reverted (e.g. by `git checkout --`) without
    ///     removing the whitelist entry. Either re-promote the zip or
    ///     drop the whitelist entry.
    /// Stays green throughout Phase 3 mass-gen as the whitelist grows.
    func test_mainBundle_v5Coverage_matchesWhitelist() throws {
        var bundleV5: Set<String> = []
        var bundleNonV5: [(zipKey: String, exportVersion: String)] = []

        for id in SpeciesCatalog.allIDs {
            for stage in [PetLevel.baby, .adult, .elder] {
                let req = SpriteRequest(species: id, stage: stage, direction: .east)
                guard let url = SpriteAssetResolver.url(for: req, in: mainBundle) else { continue }
                let zipKey = "\(id.rawValue)-\(stage.assetSlug)"
                let metadata = try SpriteMetadata.parse(zipURL: url)
                if metadata.exportVersion == "3.0" {
                    bundleV5.insert(zipKey)
                } else {
                    bundleNonV5.append((zipKey, metadata.exportVersion))
                }
            }
        }

        let unexpectedV5 = bundleV5.subtracting(Self.expectedV5Coverage).sorted()
        let missingFromBundle = Self.expectedV5Coverage.subtracting(bundleV5).sorted()

        var problems: [String] = []
        if !unexpectedV5.isEmpty {
            problems.append(
                "Bundled as v5 but not in whitelist (add to expectedV5Coverage): "
                + unexpectedV5.joined(separator: ", "))
        }
        if !missingFromBundle.isEmpty {
            // Look up actual schema version for clearer diagnostics
            let bundledVersions = Dictionary(uniqueKeysWithValues: bundleNonV5)
            let detail = missingFromBundle.map { key in
                "\(key) [actual: v\(bundledVersions[key] ?? "missing")]"
            }
            problems.append(
                "Whitelisted as v5 but not actually v5 in bundle: "
                + detail.joined(separator: ", "))
        }

        XCTAssertEqual(problems, [], problems.joined(separator: " | "))
    }

    /// Phase 3 acceptance gate. SKIPPED while mass-gen is in flight so
    /// unrelated PRs don't get red-CI-blocked on Phase 3 progress. Flip
    /// `phase3Complete` to `true` (or delete this skip) when every
    /// multi-variety species × stage has a v5 zip — at that point this
    /// test enforces the contract going forward.
    private static let phase3Complete: Bool = false

    func test_mainBundle_phase3AcceptanceGate_everyMultiVarietyStageIsV5() throws {
        let multiVarietyCount = SpeciesCatalog.allIDs.filter {
            !Self.partialCoverageIDs.contains($0)
        }.count
        try XCTSkipIf(
            !Self.phase3Complete,
            "Phase 3 mass-gen still in progress (\(Self.expectedV5Coverage.count) v5 zips of "
            + "\(multiVarietyCount * 3) target). Flip phase3Complete=true when shipped.")

        var notV5: [String] = []
        for id in SpeciesCatalog.allIDs where !Self.partialCoverageIDs.contains(id) {
            for stage in [PetLevel.baby, .adult, .elder] {
                let req = SpriteRequest(species: id, stage: stage, direction: .east)
                guard let url = SpriteAssetResolver.url(for: req, in: mainBundle) else {
                    notV5.append("\(id.rawValue)-\(stage.assetSlug) [missing zip]")
                    continue
                }
                let metadata = try SpriteMetadata.parse(zipURL: url)
                if metadata.exportVersion != "3.0" {
                    notV5.append("\(id.rawValue)-\(stage.assetSlug) [v\(metadata.exportVersion)]")
                }
            }
        }

        XCTAssertEqual(
            notV5, [],
            "Phase 3 incomplete — \(notV5.count) zips not at v5: "
            + notV5.joined(separator: ", "))
    }
}
