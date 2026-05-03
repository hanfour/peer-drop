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

    // MARK: - end-to-end render via main bundle

    func test_mainBundle_endToEnd_decodesCatTabbyAdultEast() async throws {
        let service = SpriteService(cache: PNGSpriteCache(countLimit: 30), bundle: mainBundle)
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
        let service = SpriteService(cache: PNGSpriteCache(countLimit: 8), bundle: mainBundle)
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
}
