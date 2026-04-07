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
        XCTAssertEqual(controller.currentFrame, 0) // wraps
    }

    func testSetActionResetsFrame() {
        let controller = PetAnimationController()
        controller.setAction(.idle, frameCount: 4)
        controller.advanceFrame()
        controller.advanceFrame()
        XCTAssertEqual(controller.currentFrame, 2)
        controller.setAction(.walking, frameCount: 4)
        XCTAssertEqual(controller.currentFrame, 0) // reset on action change
    }
}
