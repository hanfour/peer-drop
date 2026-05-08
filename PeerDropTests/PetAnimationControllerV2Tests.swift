import XCTest
@testable import PeerDrop

@MainActor
final class PetAnimationControllerV2Tests: XCTestCase {

    func testDefaultFrameRateIs6FPS() {
        let controller = PetAnimationController()
        XCTAssertEqual(controller.frameRate, 1.0 / 6.0, accuracy: 0.001)
    }

    func testSetActionUpdatesFrameCount() {
        let controller = PetAnimationController()
        controller.setAction(.idle, frameCount: 4)
        XCTAssertEqual(controller.currentFrame, 0)
        XCTAssertEqual(controller.totalFrames, 4)
    }

    func testFrameWrapsAround() {
        let controller = PetAnimationController()
        controller.setAction(.idle, frameCount: 2)
        controller.advanceFrame()
        XCTAssertEqual(controller.currentFrame, 1)
        controller.advanceFrame()
        XCTAssertEqual(controller.currentFrame, 0)
    }

    func testSetActionResetsFrame() {
        let controller = PetAnimationController()
        controller.setAction(.idle, frameCount: 4)
        controller.advanceFrame()
        controller.advanceFrame()
        XCTAssertEqual(controller.currentFrame, 2)
        controller.setAction(.walking, frameCount: 4)
        XCTAssertEqual(controller.currentFrame, 0)
    }

    // MARK: - v5 wiring (Phase 1.6)

    func test_v5SetAction_withFps_updatesFpsAndAutoStartsTimer() {
        let controller = PetAnimationController()
        XCTAssertFalse(controller.isAnimating, "no timer before setAction")

        controller.setAction(.walking, frameCount: 8, fps: 6)

        XCTAssertEqual(controller.totalFrames, 8)
        XCTAssertEqual(controller.fps, 6)
        XCTAssertEqual(controller.currentAction, .walking)
        XCTAssertEqual(controller.currentFrame, 0)
        XCTAssertTrue(controller.isAnimating, "v5 setAction auto-starts timer")
        controller.stopAnimation()
    }

    func test_v5SetAction_sameAction_isNoOp() {
        let controller = PetAnimationController()
        controller.setAction(.walking, frameCount: 8, fps: 6)
        controller.advanceFrame()
        controller.advanceFrame()
        XCTAssertEqual(controller.currentFrame, 2)

        controller.setAction(.walking, frameCount: 8, fps: 6)

        XCTAssertEqual(controller.currentFrame, 2,
                       "same-action setAction must preserve frameIndex (no reset)")
        controller.stopAnimation()
    }

    func test_v5SetAction_advancesFrameAtFpsRate() async throws {
        let controller = PetAnimationController()
        // 30 fps ≈ 33 ms/frame. After 200 ms expect ≥3 frames advanced.
        controller.setAction(.walking, frameCount: 8, fps: 30)
        try await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertGreaterThanOrEqual(controller.currentFrame, 3,
                                    "30 fps × 200 ms should produce ≥3 frame advances")
        controller.stopAnimation()
    }

    func test_v5_pauseAndResume_haltAndRestoreTimer() async throws {
        let controller = PetAnimationController()
        controller.setAction(.walking, frameCount: 8, fps: 30)
        try await Task.sleep(nanoseconds: 100_000_000)
        let frameBeforePause = controller.currentFrame
        XCTAssertGreaterThan(frameBeforePause, 0, "frame should have advanced before pause")

        controller.pause()
        XCTAssertFalse(controller.isAnimating)

        try await Task.sleep(nanoseconds: 150_000_000)
        XCTAssertEqual(controller.currentFrame, frameBeforePause,
                       "frame must not advance while paused")

        controller.resume()
        XCTAssertTrue(controller.isAnimating)
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertGreaterThan(controller.currentFrame, frameBeforePause,
                             "resume restarts frame advance")
        controller.stopAnimation()
    }
}
