import XCTest
import CoreGraphics
@testable import PeerDrop

@MainActor
final class PetRendererV3Tests: XCTestCase {

    private var testBundle: Bundle { Bundle(for: type(of: self)) }

    /// Builds a genome that pins to cat-tabby (the only species with a bundled
    /// fixture in the test target).
    private func catTabbyGenome() -> PetGenome {
        var g = PetGenome.random()
        g.body = .cat
        g.subVariety = "tabby"
        return g
    }

    private func makeRenderer() -> PetRendererV3 {
        PetRendererV3(service: SpriteService(cache: PNGSpriteCache(countLimit: 30),
                                              bundle: testBundle))
    }

    // MARK: - basic call

    func test_render_returnsCGImage_forBundledSpecies() async throws {
        let renderer = makeRenderer()
        let cg = try await renderer.render(
            genome: catTabbyGenome(),
            level: .adult,
            mood: .happy,
            direction: .east
        )
        XCTAssertEqual(cg.width, 68)
        XCTAssertEqual(cg.height, 68)
    }

    // MARK: - direction-aware (M4.2)

    func test_render_distinctDirections_returnDistinctImages() async throws {
        let renderer = makeRenderer()
        let east = try await renderer.render(
            genome: catTabbyGenome(), level: .adult, mood: .happy, direction: .east)
        let west = try await renderer.render(
            genome: catTabbyGenome(), level: .adult, mood: .happy, direction: .west)
        XCTAssertFalse(cgImagesIdentical(east, west),
                       "east and west should be distinct PNG frames")
    }

    // MARK: - stage as cache key (M4.3)

    func test_stage_isPartOfRenderKey_andCachesAreStable() async throws {
        // Two renders with the same stage return identical (cached) bytes —
        // proves the renderer doesn't re-decode or re-composite for stable
        // inputs. UIGraphicsImageRenderer's determinism is load-bearing here.
        let renderer = makeRenderer()
        let first = try await renderer.render(
            genome: catTabbyGenome(), level: .adult, mood: .happy, direction: .east)
        let second = try await renderer.render(
            genome: catTabbyGenome(), level: .adult, mood: .happy, direction: .east)
        XCTAssertTrue(cgImagesIdentical(first, second), "same request → cached identical CGImage")

        // A different stage with no bundled asset throws assetNotFound,
        // proving stage is part of the resolution key (otherwise the .adult
        // cache hit would mask the missing .baby asset).
        do {
            _ = try await renderer.render(
                genome: catTabbyGenome(), level: .baby, mood: .happy, direction: .east)
            XCTFail("expected assetNotFound for unbundled stage")
        } catch SpriteServiceError.assetNotFound {
            // expected
        } catch {
            XCTFail("expected assetNotFound, got \(error)")
        }
    }

    // MARK: - ghost: no v4.0 asset

    func test_render_ghostBody_throwsAssetNotFound() async {
        // BodyGene.ghost maps to SpeciesID("ghost"), which isn't in the
        // catalog (M2.3) and has no bundled asset. Pinning this contract so
        // any future change (e.g. someone adds ghost to the catalog without
        // also bundling assets) trips the assertion instead of silently
        // shipping nil-image pets.
        let renderer = makeRenderer()
        var ghost = PetGenome.random()
        ghost.body = .ghost
        ghost.subVariety = nil
        ghost.seed = nil
        do {
            _ = try await renderer.render(
                genome: ghost, level: .adult, mood: .happy, direction: .east)
            XCTFail("expected assetNotFound for ghost (no v4.0 asset)")
        } catch SpriteServiceError.assetNotFound {
            // expected
        } catch {
            XCTFail("expected assetNotFound, got \(error)")
        }
    }

    // MARK: - helpers

    private func cgImagesIdentical(_ a: CGImage, _ b: CGImage) -> Bool {
        guard a.width == b.width, a.height == b.height else { return false }
        guard let dataA = a.dataProvider?.data, let dataB = b.dataProvider?.data else { return false }
        return CFEqual(dataA, dataB)
    }
}
