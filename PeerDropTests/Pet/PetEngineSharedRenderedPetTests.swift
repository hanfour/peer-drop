import XCTest
import CoreGraphics
@testable import PeerDrop

@MainActor
final class PetEngineSharedRenderedPetTests: XCTestCase {

    private var bridge: SharedRenderedPet!

    override func setUp() {
        super.setUp()
        bridge = SharedRenderedPet(suiteName: nil)  // tempdir fallback per process
    }

    override func tearDown() {
        bridge.clear()
        bridge = nil
        super.tearDown()
    }

    /// Builds a PetEngine wired to a renderer that finds the M0 fixture
    /// (cat-tabby-adult.zip) in the test bundle, and the test's tempdir
    /// SharedRenderedPet bridge.
    private func makeEngine(pet: PetState) -> PetEngine {
        let testBundle = Bundle(for: type(of: self))
        let service = SpriteService(cache: SpriteCache(countLimit: 30), bundle: testBundle)
        let renderer = PetRendererV3(service: service)
        return PetEngine(pet: pet, rendererV3: renderer, sharedRenderedPet: bridge)
    }

    func test_updateRenderedImage_writesToSharedRenderedPet_whenRenderSucceeds() async throws {
        var pet = PetState.newEgg()
        pet.level = .adult
        pet.genome.body = .cat
        pet.genome.subVariety = "tabby"
        let engine = makeEngine(pet: pet)

        engine.updateRenderedImage()

        // Wait for the async render Task to complete.
        try await waitForRenderedImage(engine: engine, timeout: 2.0)

        XCTAssertNotNil(engine.renderedImage, "renderedImage should be populated")

        let shared = bridge.read()
        XCTAssertNotNil(shared, "SharedRenderedPet should contain the rendered CGImage")
        XCTAssertEqual(shared?.width, engine.renderedImage?.width)
        XCTAssertEqual(shared?.height, engine.renderedImage?.height)
    }

    func test_updateRenderedImage_writesPlaceholder_whenSpeciesAssetMissing() async throws {
        // The test bundle only ships cat-tabby-adult.zip. Any other species
        // hits PetRendererV3.loadBasePNG's catch branch and falls back to
        // cat-tabby (ultimateFallback) so the user sees a placeholder pet
        // instead of nothing — UX preference is "show placeholder" over
        // "show nothing".
        //
        // body=.dragon chosen because dragon-western-adult.zip is NOT in the
        // test bundle, so the fallback path fires.
        var pet = PetState.newEgg()
        pet.level = .adult
        pet.genome.body = .dragon
        pet.genome.subVariety = nil
        pet.genome.seed = nil
        let engine = makeEngine(pet: pet)

        engine.updateRenderedImage()
        try await waitForRenderedImage(engine: engine, timeout: 2.0)

        XCTAssertNotNil(engine.renderedImage, "missing-asset render should fall back to placeholder")
        XCTAssertNotNil(bridge.read(), "Bridge should get the placeholder image")
        XCTAssertEqual(bridge.read()?.width, 68, "placeholder is cat-tabby 68×68")
    }

    func test_consecutiveRenders_overwriteSharedRenderedPet() async throws {
        var pet = PetState.newEgg()
        pet.level = .adult
        pet.genome.body = .cat
        pet.genome.subVariety = "tabby"
        let engine = makeEngine(pet: pet)

        engine.updateRenderedImage()
        try await waitForRenderedImage(engine: engine, timeout: 2.0)
        let firstBytes = pngBytes(bridge.read()!)

        // Same input → same composited output (UIGraphicsImageRenderer is
        // deterministic; PetRendererV3.lastComposite memoization may even
        // short-circuit).
        engine.updateRenderedImage()
        try await Task.sleep(nanoseconds: 200_000_000)
        let secondBytes = pngBytes(bridge.read()!)

        XCTAssertEqual(firstBytes, secondBytes,
                       "Same render inputs should produce identical PNG bytes via the bridge")
    }

    // MARK: - helpers

    private func waitForRenderedImage(engine: PetEngine, timeout: TimeInterval) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while engine.renderedImage == nil && Date() < deadline {
            try await Task.sleep(nanoseconds: 20_000_000)   // 20 ms
        }
    }

    private func pngBytes(_ image: CGImage) -> Data {
        let data = NSMutableData()
        let dest = CGImageDestinationCreateWithData(
            data as CFMutableData, "public.png" as CFString, 1, nil)!
        CGImageDestinationAddImage(dest, image, nil)
        CGImageDestinationFinalize(dest)
        return data as Data
    }
}
