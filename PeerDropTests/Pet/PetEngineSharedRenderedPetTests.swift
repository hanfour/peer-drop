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
        let service = SpriteService(cache: PNGSpriteCache(countLimit: 30), bundle: testBundle)
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

    func test_updateRenderedImage_doesNotWrite_whenRenderFails() async throws {
        // Body=.ghost has no v4.0 asset → renderer throws → renderedImage nil
        // → bridge skipped.
        var pet = PetState.newEgg()
        pet.level = .adult
        pet.genome.body = .ghost
        pet.genome.subVariety = nil
        pet.genome.seed = nil
        let engine = makeEngine(pet: pet)

        engine.updateRenderedImage()
        // Give the Task a chance to complete (failure path is fast — no decode).
        try await Task.sleep(nanoseconds: 200_000_000)

        XCTAssertNil(engine.renderedImage)
        XCTAssertNil(bridge.read(), "Bridge should not get a stale write when render fails")
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
