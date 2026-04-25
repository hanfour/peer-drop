import XCTest
@testable import PeerDrop

@MainActor
final class PetAnimationLifecycleTests: XCTestCase {

    func test_initialState_isNotAnimating() {
        let controller = PetAnimationController()
        XCTAssertFalse(controller.isAnimating)
    }

    func test_startAnimation_setsIsAnimatingTrue() {
        let controller = PetAnimationController()
        controller.startAnimation()
        XCTAssertTrue(controller.isAnimating)
        controller.stopAnimation() // cleanup
    }

    func test_stopAnimation_setsIsAnimatingFalse() {
        let controller = PetAnimationController()
        controller.startAnimation()
        XCTAssertTrue(controller.isAnimating)
        controller.stopAnimation()
        XCTAssertFalse(controller.isAnimating)
    }

    func test_stopAnimation_isIdempotent() {
        let controller = PetAnimationController()
        controller.startAnimation()
        controller.stopAnimation()
        controller.stopAnimation() // second call must not crash
        XCTAssertFalse(controller.isAnimating)
    }

    func test_startAnimation_isIdempotent() {
        let controller = PetAnimationController()
        controller.startAnimation()
        controller.startAnimation() // re-arms timer; existing impl invalidates first
        XCTAssertTrue(controller.isAnimating)
        controller.stopAnimation() // cleanup
    }

    func test_stopThenStart_reactivates() {
        let controller = PetAnimationController()
        controller.startAnimation()
        controller.stopAnimation()
        XCTAssertFalse(controller.isAnimating)
        controller.startAnimation()
        XCTAssertTrue(controller.isAnimating)
        controller.stopAnimation()
    }
}
