import XCTest
import CoreGraphics
@testable import PeerDrop

final class SpriteServiceTests: XCTestCase {

    private var testBundle: Bundle { Bundle(for: type(of: self)) }
    private var catTabbyAdultEast: SpriteRequest {
        SpriteRequest(species: SpeciesID("cat-tabby"), stage: .adult, direction: .east)
    }

    // MARK: - happy path

    func test_image_returnsCGImage_forBundledZip() async throws {
        let service = SpriteService(cache: PNGSpriteCache(countLimit: 30), bundle: testBundle)
        let cg = try await service.image(for: catTabbyAdultEast)
        XCTAssertEqual(cg.width, 68)
        XCTAssertEqual(cg.height, 68)
    }

    // MARK: - bulk fill (1 decode populates all 8 directions)

    func test_decodeOnce_populatesAll8Directions_inCache() async throws {
        let cache = PNGSpriteCache(countLimit: 30)
        let service = SpriteService(cache: cache, bundle: testBundle)

        // First request decodes the zip and bulk-fills 8 entries.
        _ = try await service.image(for: catTabbyAdultEast)
        let firstCount = await service.decodeCount
        XCTAssertEqual(firstCount, 1)

        // Subsequent requests for other directions of the same species×stage
        // hit cache — no additional decodes.
        for direction in SpriteDirection.allCases where direction != .east {
            let req = SpriteRequest(species: SpeciesID("cat-tabby"), stage: .adult, direction: direction)
            _ = try await service.image(for: req)
        }
        let finalCount = await service.decodeCount
        XCTAssertEqual(finalCount, 1, "all 8 directions should resolve from one decode")
    }

    // MARK: - concurrent dedup

    func test_concurrent_sameRequest_decodedOnce() async throws {
        let service = SpriteService(cache: PNGSpriteCache(countLimit: 30), bundle: testBundle)

        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<10 {
                group.addTask {
                    _ = try? await service.image(for: self.catTabbyAdultEast)
                }
            }
            await group.waitForAll()
        }

        let count = await service.decodeCount
        XCTAssertEqual(count, 1, "10 parallel requests for the same key should trigger exactly one decode")
    }

    // MARK: - catalog fallback

    func test_unknownVariant_resolvesToFamilyDefault() async throws {
        let service = SpriteService(cache: PNGSpriteCache(countLimit: 30), bundle: testBundle)
        // cat-imaginary not in catalog → falls back to cat-tabby (which IS bundled)
        let req = SpriteRequest(species: SpeciesID("cat-imaginary"), stage: .adult, direction: .east)
        let cg = try await service.image(for: req)
        XCTAssertEqual(cg.width, 68)
    }

    func test_unresolvedID_repeatedDirections_decodeOnce() async throws {
        // Regression: an unresolved SpeciesID (e.g. typo'd subVariety pin)
        // requested across multiple directions used to re-decode per direction
        // because bulk-fill only cached the first direction under the original
        // ID. Now bulk-fill iterates all 8 under both resolved and original.
        let service = SpriteService(cache: PNGSpriteCache(countLimit: 30), bundle: testBundle)
        for direction in SpriteDirection.allCases {
            let req = SpriteRequest(species: SpeciesID("cat-imaginary"),
                                    stage: .adult, direction: direction)
            _ = try await service.image(for: req)
        }
        let count = await service.decodeCount
        XCTAssertEqual(count, 1, "8 directions of an unresolved ID should share one decode")
    }

    // MARK: - error paths

    func test_unknownFamily_throwsAssetNotFound() async {
        let service = SpriteService(cache: PNGSpriteCache(countLimit: 30), bundle: testBundle)
        let req = SpriteRequest(species: SpeciesID("madeup-anything"), stage: .adult, direction: .east)
        do {
            _ = try await service.image(for: req)
            XCTFail("expected SpriteServiceError.assetNotFound")
        } catch SpriteServiceError.assetNotFound {
            // expected
        } catch {
            XCTFail("expected assetNotFound, got \(error)")
        }
    }

    func test_knownSpeciesButMissingStage_throwsAssetNotFound() async {
        let service = SpriteService(cache: PNGSpriteCache(countLimit: 30), bundle: testBundle)
        // cat-tabby is in catalog, only adult zip is bundled in tests.
        let req = SpriteRequest(species: SpeciesID("cat-tabby"), stage: .baby, direction: .east)
        do {
            _ = try await service.image(for: req)
            XCTFail("expected SpriteServiceError.assetNotFound")
        } catch SpriteServiceError.assetNotFound {
            // expected
        } catch {
            XCTFail("expected assetNotFound, got \(error)")
        }
    }
}
