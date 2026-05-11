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

    func test_v5SetAction_withFps_unpausesController() {
        let controller = PetAnimationController()
        XCTAssertFalse(controller.isAnimating, "initial state is paused")

        controller.setAction(.walking, frameCount: 8, fps: 6)

        XCTAssertEqual(controller.totalFrames, 8)
        XCTAssertEqual(controller.fps, 6)
        XCTAssertEqual(controller.currentAction, .walking)
        XCTAssertEqual(controller.currentFrame, 0)
        XCTAssertTrue(controller.isAnimating, "v5 setAction unpauses")
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

    // MARK: - v5.1 dt-driven advancement (deferred design #4)

    func test_advance_accumulatesDt_thenAdvancesFrame() {
        let controller = PetAnimationController()
        controller.setAction(.walking, frameCount: 8, fps: 6)  // frameInterval ≈ 0.1667s

        controller.advance(dt: 0.10)  // below interval
        XCTAssertEqual(controller.currentFrame, 0, "below interval: no advance")

        controller.advance(dt: 0.10)  // accumulated 0.20 → 1 step
        XCTAssertEqual(controller.currentFrame, 1)

        controller.advance(dt: 0.20)  // accumulated ~0.23 → another step
        XCTAssertEqual(controller.currentFrame, 2)
    }

    func test_advance_withZeroDt_doesNotChangeFrame() {
        let controller = PetAnimationController()
        controller.setAction(.walking, frameCount: 8, fps: 6)
        controller.advance(dt: 0)
        XCTAssertEqual(controller.currentFrame, 0)
    }

    func test_advance_whilePaused_doesNotAdvance() {
        let controller = PetAnimationController()
        controller.setAction(.walking, frameCount: 8, fps: 6)
        controller.pause()
        // dt large enough for several frame intervals
        controller.advance(dt: 1.0)
        XCTAssertEqual(controller.currentFrame, 0,
                       "paused controller must not advance regardless of dt")
    }

    func test_advance_largeDt_dropsFramesProportionally() {
        // Thermal throttle scenario: physics tick delivers one huge dt instead
        // of many small ones. Animation should catch up by jumping multiple
        // frames in a single advance call so wall-clock animation stays
        // in sync.
        let controller = PetAnimationController()
        controller.setAction(.walking, frameCount: 8, fps: 6)  // 6 fps = 0.167s/frame

        controller.advance(dt: 1.0)  // 1s × 6fps = 6 frames

        XCTAssertEqual(controller.currentFrame, 6,
                       "1 second @ 6 fps must advance exactly 6 frames in one call")
    }

    func test_advance_wrapsAroundTotalFrames() {
        let controller = PetAnimationController()
        controller.setAction(.walking, frameCount: 4, fps: 10)  // 0.1s/frame
        // Advance enough for 7 steps → 7 % 4 = 3
        controller.advance(dt: 0.7)
        XCTAssertEqual(controller.currentFrame, 3)
    }

    func test_advance_accumulatorPreservedBetweenCalls() {
        // Two sub-interval calls must still produce a frame advance when the
        // sum crosses the boundary — the controller carries debt across ticks.
        let controller = PetAnimationController()
        controller.setAction(.walking, frameCount: 8, fps: 10)  // 0.1s/frame
        controller.advance(dt: 0.06)
        controller.advance(dt: 0.06)
        XCTAssertEqual(controller.currentFrame, 1, "0.06 + 0.06 = 0.12 > 0.1 → 1 frame")
    }

    func test_setAction_clearsAccumulator() {
        // Switching action mid-debt must not carry leftover dt into the new
        // action — otherwise a sub-interval debt could cause an immediate
        // first-frame skip when transitioning idle → walk.
        let controller = PetAnimationController()
        controller.setAction(.walking, frameCount: 8, fps: 10)
        controller.advance(dt: 0.09)  // 0.09 < 0.1, accumulator has 0.09
        XCTAssertEqual(controller.currentFrame, 0)

        controller.setAction(.idle, frameCount: 4, fps: 2)
        controller.advance(dt: 0.05)  // tiny dt; old accumulator would have triggered
        XCTAssertEqual(controller.currentFrame, 0,
                       "setAction must clear accumulator so new action starts at 0 with no debt")
    }

    func test_pauseResume_restartsClean() {
        let controller = PetAnimationController()
        controller.setAction(.walking, frameCount: 8, fps: 10)
        controller.advance(dt: 0.15)  // 1 frame, 0.05s debt
        XCTAssertEqual(controller.currentFrame, 1)

        controller.pause()
        XCTAssertFalse(controller.isAnimating)

        // While paused, dt is ignored
        controller.advance(dt: 5.0)
        XCTAssertEqual(controller.currentFrame, 1)

        controller.resume()
        XCTAssertTrue(controller.isAnimating)

        // Resume clears accumulator — first dt of 0.05 alone should NOT
        // advance (otherwise the pre-pause 0.05 debt would resurface).
        controller.advance(dt: 0.05)
        XCTAssertEqual(controller.currentFrame, 1,
                       "resume must start with a fresh accumulator")
    }
}
