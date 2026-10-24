import XCTest
@testable import PeerDropSecurity
@testable import PeerDropCore

/// Fix 1: the 1 Hz ticker must keep firing while iOS scroll tracking runs the
/// main run loop in a non-default mode (pings stop ⇒ the Worker cuts at 90 s),
/// and must be invalidated when stopped or deallocated.
@MainActor
final class RendezvousTickerTests: XCTestCase {

    /// A custom mode registered as a common mode stands in for
    /// `UITrackingRunLoopMode`: timers in `.common` fire there, default-mode timers do not.
    func testFiresWhileRunLoopIsInATrackingLikeCommonMode() async {
        let mode = RunLoop.Mode("peerdrop.rv.test.tracking")
        CFRunLoopAddCommonMode(CFRunLoopGetMain(), CFRunLoopMode(mode.rawValue as CFString))
        let ticker = TimerRendezvousTicker()
        var fired = 0
        ticker.start { fired += 1 }
        let fireCount = { ticker.timerFireCountForTesting }
        let end = Date().addingTimeInterval(1.6)
        while Date() < end { _ = RunLoop.main.run(mode: mode, before: end) }
        let firedInTracking = fireCount()
        ticker.stop()
        XCTAssertGreaterThanOrEqual(firedInTracking, 1, "timer must fire in tracking-like modes")
        try? await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertGreaterThanOrEqual(fired, 1)
    }

    func testStopInvalidates() {
        let ticker = TimerRendezvousTicker()
        ticker.start {}
        weak var timer = ticker.timerForTesting
        XCTAssertEqual(timer?.isValid, true)
        ticker.stop()
        XCTAssertFalse(timer?.isValid ?? false)
        XCTAssertNil(ticker.timerForTesting)
    }

    func testDeinitInvalidates() {
        var ticker: TimerRendezvousTicker? = TimerRendezvousTicker()
        ticker?.start {}
        weak var timer = ticker?.timerForTesting
        XCTAssertEqual(timer?.isValid, true)
        ticker = nil
        XCTAssertFalse(timer?.isValid ?? false)
    }

    func testManagerDeinitInvalidatesItsTicker() {
        final class NoDirect: DirectConnectionChecker {
            var onDirectConnectionsChanged: (() -> Void)?
            func hasDirectConnection(to contact: TrustedContact) -> Bool { false }
        }
        // The ticker only runs while a contact is active (final review).
        var c = TrustedContact(deviceId: "dev-t", displayName: "T", identityPublicKey: RendezvousTestIdentity().raw,
                               trustLevel: .verified, accountId: "acct-t")
        c.rendezvousEnabled = true
        let contact = c
        var manager: RendezvousManager? = RendezvousManager(
            contacts: { [contact] }, secrets: IdentityRendezvousSecretProvider(identity: RendezvousTestIdentity()),
            direct: NoDirect(), installer: FakeInstaller(), signaling: FakeSignalingFactory(),
            negotiators: FakeNegotiatorFactory())
        manager?.appDidBecomeActive()
        weak var timer = (manager?.tickerForTesting as? TimerRendezvousTicker)?.timerForTesting
        XCTAssertEqual(timer?.isValid, true)
        manager = nil
        XCTAssertFalse(timer?.isValid ?? false)
    }
}
