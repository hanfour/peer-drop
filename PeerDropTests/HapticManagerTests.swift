import XCTest
@testable import PeerDrop

final class HapticManagerTests: XCTestCase {

    func testHapticMethodsDoNotCrash() {
        // Smoke test: calling every static method should not throw or crash.
        // On the simulator, haptic generators are no-ops.
        HapticManager.peerDiscovered()
        HapticManager.connectionAccepted()
        HapticManager.connectionRejected()
        HapticManager.transferComplete()
        HapticManager.transferFailed()
        HapticManager.incomingRequest()
        HapticManager.callStarted()
        HapticManager.callEnded()
        HapticManager.tap()
    }
}
