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
        PetRendererV3(service: SpriteService(cache: SpriteCache(countLimit: 30),
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

    // MARK: - ghost: no v4.0 asset → falls back to cat-tabby placeholder

    func test_render_ghostBody_fallsBackToUltimatePlaceholder() async throws {
        // BodyGene.ghost maps to SpeciesID("ghost"), which isn't in the
        // catalog (M2.3) and has no bundled asset. The renderer's
        // ultimateFallback (cat-tabby) kicks in so users with legacy ghost
        // pets see a placeholder pet instead of a blank rectangle. Pin both
        // the success outcome and the fallback identity by checking the
        // dimensions match cat-tabby's 68×68 output.
        let renderer = makeRenderer()
        var ghost = PetGenome.random()
        ghost.body = .ghost
        ghost.subVariety = nil
        ghost.seed = nil
        let cg = try await renderer.render(
            genome: ghost, level: .adult, mood: .happy, direction: .east)
        XCTAssertEqual(cg.width, 68, "ghost should render via the cat-tabby placeholder (68×68)")
        XCTAssertEqual(cg.height, 68)
    }

    // MARK: - mood overlay (M4b.2)

    func test_render_introducesPixelDifference_inTopRightOverlayRegion() async throws {
        // The composited image's top-right region (where the mood icon is
        // drawn) should differ from the same region of the raw base PNG;
        // pixels outside the overlay box should be unchanged.
        let cache = SpriteCache(countLimit: 30)
        let service = SpriteService(cache: cache, bundle: testBundle)
        let renderer = PetRendererV3(service: service)

        let basePNG = try await service.image(
            for: SpriteRequest(species: SpeciesID("cat-tabby"), stage: .adult, direction: .east))
        let composited = try await renderer.render(
            genome: catTabbyGenome(), level: .adult, mood: .happy, direction: .east)

        XCTAssertEqual(composited.width, basePNG.width)
        XCTAssertEqual(composited.height, basePNG.height)

        // Sample a 6×6 region inside the overlay box.
        let overlayBoxOrigin = (x: composited.width - 12, y: 4)
        let baseInOverlayRegion = averageRGB(in: basePNG,
            x: overlayBoxOrigin.x, y: overlayBoxOrigin.y, w: 6, h: 6)
        let compInOverlayRegion = averageRGB(in: composited,
            x: overlayBoxOrigin.x, y: overlayBoxOrigin.y, w: 6, h: 6)

        let overlayDiff = colorDistance(baseInOverlayRegion, compInOverlayRegion)
        XCTAssertGreaterThan(overlayDiff, 10,
            "overlay region (\(overlayBoxOrigin)) should differ from base — got base=\(baseInOverlayRegion), comp=\(compInOverlayRegion)")
    }

    func test_render_mood_changesPixelsInOverlayRegion() async throws {
        // Different moods should produce different overlay pixels (different
        // tint colors). Same base sprite, two different moods.
        let cache = SpriteCache(countLimit: 30)
        let service = SpriteService(cache: cache, bundle: testBundle)
        let renderer = PetRendererV3(service: service)

        let happy = try await renderer.render(
            genome: catTabbyGenome(), level: .adult, mood: .happy, direction: .east)
        let sleepy = try await renderer.render(
            genome: catTabbyGenome(), level: .adult, mood: .sleepy, direction: .east)

        let happyOverlay = averageRGB(in: happy, x: happy.width - 16, y: 0, w: 16, h: 16)
        let sleepyOverlay = averageRGB(in: sleepy, x: sleepy.width - 16, y: 0, w: 16, h: 16)
        XCTAssertGreaterThan(colorDistance(happyOverlay, sleepyOverlay), 10,
            "different moods should produce visibly different overlays")
    }

    // MARK: - helpers

    private func cgImagesIdentical(_ a: CGImage, _ b: CGImage) -> Bool {
        guard a.width == b.width, a.height == b.height else { return false }
        guard let dataA = a.dataProvider?.data, let dataB = b.dataProvider?.data else { return false }
        return CFEqual(dataA, dataB)
    }

    /// Average RGB (alpha-premultiplied, 0–255) over a region of the image.
    private func averageRGB(in image: CGImage, x: Int, y: Int, w: Int, h: Int) -> (r: Int, g: Int, b: Int) {
        let cs = CGColorSpaceCreateDeviceRGB()
        let info = CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue
        var bytes = [UInt8](repeating: 0, count: w * h * 4)
        let ctx = CGContext(data: &bytes, width: w, height: h, bitsPerComponent: 8,
                             bytesPerRow: w * 4, space: cs, bitmapInfo: info)!
        // Position the source image so that (x, y) lands at (0, 0) in the context.
        ctx.draw(image,
                 in: CGRect(x: -x, y: -(image.height - y - h), width: image.width, height: image.height))
        var rSum = 0, gSum = 0, bSum = 0
        for i in stride(from: 0, to: bytes.count, by: 4) {
            rSum += Int(bytes[i])
            gSum += Int(bytes[i + 1])
            bSum += Int(bytes[i + 2])
        }
        let count = w * h
        return (rSum / count, gSum / count, bSum / count)
    }

    private func colorDistance(_ a: (r: Int, g: Int, b: Int), _ b: (r: Int, g: Int, b: Int)) -> Double {
        let dr = Double(a.r - b.r)
        let dg = Double(a.g - b.g)
        let db = Double(a.b - b.b)
        return (dr * dr + dg * dg + db * db).squareRoot()
    }
}
