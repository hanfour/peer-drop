import XCTest
@testable import PeerDrop

final class SpriteServiceAnimationTests: XCTestCase {

    private var testBundle: Bundle { Bundle(for: type(of: self)) }

    private func url(forFixture name: String) -> URL {
        testBundle.url(forResource: name, withExtension: "zip", subdirectory: "Pets")!
    }

    func test_decode_v3Zip_returns8WalkFramesAtSouthWithFps6() async throws {
        let service = SpriteService(bundle: testBundle)
        let request = AnimationRequest(
            species: SpeciesID("test-anim"),
            stage: .baby,
            direction: .south,
            action: .walking
        )

        let frames = try await service.framesInternal(
            at: url(forFixture: "test-anim-v3"),
            for: request
        )

        XCTAssertEqual(frames.images.count, 8, "walk has 8 frames")
        XCTAssertEqual(frames.fps, 6)
        XCTAssertTrue(frames.loops)
    }

    func test_decode_v3Zip_returns4IdleFramesAtSouthWithFps2() async throws {
        let service = SpriteService(bundle: testBundle)
        let request = AnimationRequest(
            species: SpeciesID("test-anim"),
            stage: .baby,
            direction: .south,
            action: .idle
        )

        let frames = try await service.framesInternal(
            at: url(forFixture: "test-anim-v3"),
            for: request
        )

        XCTAssertEqual(frames.images.count, 4, "idle has 4 frames")
        XCTAssertEqual(frames.fps, 2)
    }

    func test_decode_v2Zip_returnsRotationAsSingleFrameStatic() async throws {
        // Existing v4 cat-tabby-adult.zip has empty animations dict; expected to
        // degrade gracefully — single rotation PNG returned as a 1-frame "animation"
        // so v5 callers don't have to special-case v2 zips.
        let service = SpriteService(bundle: testBundle)
        let request = AnimationRequest(
            species: SpeciesID("cat-tabby"),
            stage: .adult,
            direction: .south,
            action: .walking
        )

        let frames = try await service.framesInternal(
            at: url(forFixture: "cat-tabby-adult"),
            for: request
        )

        XCTAssertEqual(frames.images.count, 1, "v2 zip degrades to 1-frame static")
        XCTAssertEqual(frames.fps, 1)
        XCTAssertFalse(frames.loops, "static fallback doesn't loop")
    }
}
