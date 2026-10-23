import XCTest
@testable import PeerDrop

final class NearbyQuickActionsTests: XCTestCase {
    func testRelayOffOmitsInvite() {
        XCTAssertFalse(NearbyQuickAction.available(relayEnabled: false, hasScanner: true).contains(.invite))
    }

    func testNoScannerOmitsScan() {
        XCTAssertFalse(NearbyQuickAction.available(relayEnabled: true, hasScanner: false).contains(.scan))
    }

    func testAllEnabledKeepsFixedOrder() {
        XCTAssertEqual(NearbyQuickAction.available(relayEnabled: true, hasScanner: true),
                       [.qr, .manual, .invite, .scan])
    }

    func testMinimalIsQRAndManual() {
        XCTAssertEqual(NearbyQuickAction.available(relayEnabled: false, hasScanner: false), [.qr, .manual])
    }
}
