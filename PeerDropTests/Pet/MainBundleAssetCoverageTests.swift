import XCTest
@testable import PeerDrop

/// Audits the M5-bundled species assets against the M2.2 SpeciesCatalog.
/// Catches asset-gen regressions early — if a species ID is added to the
/// catalog but the corresponding zip isn't bundled (or vice versa), these
/// tests fail at the next CI run rather than at first user render.
final class MainBundleAssetCoverageTests: XCTestCase {

    private var mainBundle: Bundle { Bundle.main }

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

    // MARK: - single-stage species (v4.0.2)

    /// Single-stage species (`SpriteAssetResolver.singleStageSpecies`) ship one
    /// zip total — the bare family ID, no stage suffix — and the same asset is
    /// returned for every PetLevel. v4.0.2 added ghost; this test pins the
    /// expectation that the bundle contains `<id>.zip` for each entry, since
    /// the resolver's shortcut would otherwise silently drop a missing zip
    /// onto the renderer's ultimateFallback (cat-tabby) — exactly the v4.0.1
    /// "ghost shows as cat" bug we're fixing.
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
        XCTAssertEqual(cg.width, 68)
        XCTAssertEqual(cg.height, 68)
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
        // ghost is a single-stage species (`SpriteAssetResolver.singleStageSpecies`)
        // that resolves all 3 PetLevel stage requests to the same ghost.zip file.
        // The test loop produces 3 zipKeys per ghost — all v5 because they share
        // one v5 zip. Multi-stage flip (separate ghost-baby/ghost-adult/ghost-elder
        // assets) is the operator follow-up tracked in STATUS.md §0.4.1.
        "ghost-baby",
        "ghost-adult",
        "ghost-elder",
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
