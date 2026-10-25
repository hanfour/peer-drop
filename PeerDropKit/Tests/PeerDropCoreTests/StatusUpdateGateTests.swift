import XCTest
@testable import PeerDropCore

/// Project F2: the pure gate for `.statusUpdate`. Fails closed: every
/// condition must hold, so flipping any one of them denies.
final class StatusUpdateGateTests: XCTestCase {
    private let key = Data(repeating: 7, count: 32)

    private func facts() -> StatusUpdateFacts {
        StatusUpdateFacts(isInstalled: true, isSecured: true, handshakeKey: key, helloKey: key,
                          pinning: .trusted, peerSupports: true, localAdvertised: true)
    }

    func testAllConditionsAllow() {
        XCTAssertTrue(StatusUpdateGate.allows(facts()))
    }

    func testNotInstalledDenied() {
        var f = facts(); f.isInstalled = false
        XCTAssertFalse(StatusUpdateGate.allows(f))
    }

    func testNotSecuredDenied() {
        var f = facts(); f.isSecured = false
        XCTAssertFalse(StatusUpdateGate.allows(f))
    }

    func testPinningNotEvaluatedDenied() {
        var f = facts(); f.pinning = .notEvaluated
        XCTAssertFalse(StatusUpdateGate.allows(f))
    }

    func testPinningMismatchDenied() {
        var f = facts(); f.pinning = .mismatch
        XCTAssertFalse(StatusUpdateGate.allows(f))
    }

    func testHandshakeKeyDifferentFromHelloKeyDenied() {
        var f = facts(); f.handshakeKey = Data(repeating: 8, count: 32)
        XCTAssertFalse(StatusUpdateGate.allows(f))
    }

    func testHandshakeKeyMissingDenied() {
        var f = facts(); f.handshakeKey = nil
        XCTAssertFalse(StatusUpdateGate.allows(f))
    }

    func testHelloKeyMissingDenied() {
        var f = facts(); f.helloKey = nil
        XCTAssertFalse(StatusUpdateGate.allows(f))
    }

    func testPeerWithoutFlagDenied() {
        var f = facts(); f.peerSupports = false
        XCTAssertFalse(StatusUpdateGate.allows(f))
    }

    func testLocalNotAdvertisedDenied() {
        var f = facts(); f.localAdvertised = false
        XCTAssertFalse(StatusUpdateGate.allows(f))
    }
}
