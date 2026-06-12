import XCTest
import PeerDropPet

/// Regression coverage for the Mac-side animation stall (2026-06-12):
/// PetAnimationController has no internal clock — on iOS the host
/// CADisplayLink (FloatingPetView.physicsStep) feeds advance(dt:), but the
/// Mac app had no tick source at all, so the sidebar/menu-bar sprite froze
/// on frame 0 forever. PetTickDriver supplies a hostless clock for
/// platforms without a display-link host.
@MainActor
final class PetTickDriverTests: XCTestCase {

    func testStartAdvancesAnimatorFrames() async throws {
        let animator = PetAnimationController()
        // 30 fps so a short sleep is guaranteed to cross frame boundaries.
        animator.setAction(.walking, frameCount: 8, fps: 30)
        let driver = PetTickDriver(animator: animator)
        driver.start()
        defer { driver.stop() }

        // Poll rather than fixed-sleep so the test passes as fast as the
        // first advancement and survives slow CI hosts (up to ~2s).
        for _ in 0..<40 {
            if animator.currentFrame > 0 { break }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        XCTAssertGreaterThan(
            animator.currentFrame, 0,
            "driver should feed advance(dt:) so frames progress without a CADisplayLink host")
    }

    func testStopHaltsFrameAdvancement() async throws {
        let animator = PetAnimationController()
        animator.setAction(.walking, frameCount: 8, fps: 30)
        let driver = PetTickDriver(animator: animator)
        driver.start()
        for _ in 0..<40 {
            if animator.currentFrame > 0 { break }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        driver.stop()

        // Allow any in-flight tick to land before sampling the frozen frame.
        try await Task.sleep(nanoseconds: 100_000_000)
        let frozen = animator.currentFrame
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertEqual(animator.currentFrame, frozen, "no frames should advance after stop()")
    }

    func testStartIsIdempotent() async throws {
        let animator = PetAnimationController()
        animator.setAction(.idle, frameCount: 4, fps: 30)
        let driver = PetTickDriver(animator: animator)
        driver.start()
        driver.start() // second start must not double-tick (would 2x the fps)
        defer { driver.stop() }

        // Sample the wall-clock pace: after ~0.5s at 30 fps a single clock
        // yields ≲ 15 advancements; a doubled clock would yield ~30. The
        // modulo wrap makes exact counting impossible via currentFrame, so
        // assert via the driver's own tick accounting instead.
        try await Task.sleep(nanoseconds: 500_000_000)
        XCTAssertEqual(driver.activeTickTaskCount, 1, "start() twice must keep a single clock")
    }

    func testDriverDoesNotRetainAnimatorBeyondDeinit() async throws {
        var animator: PetAnimationController? = PetAnimationController()
        weak var weakAnimator = animator
        let driver = PetTickDriver(animator: animator!)
        driver.start()
        animator = nil
        // Driver holds the animator weakly — releasing the last strong ref
        // must deallocate it even while the clock is running.
        XCTAssertNil(weakAnimator, "driver must not keep the animator alive")
        driver.stop()
    }
}
