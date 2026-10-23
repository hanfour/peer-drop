import XCTest
@testable import PeerDropCore

final class NotesExchangeGateTests: XCTestCase {

    private let key = Data(repeating: 0x42, count: 32)

    private func allowedFacts() -> NotesExchangeFacts {
        NotesExchangeFacts(isSecured: true, handshakeKey: key, helloKey: key,
                           pinningVerdictIsMismatch: false, isLocalDirect: true,
                           peerSupportsExchange: true, localSupportsExchange: true)
    }

    func testAllowedWhenEveryConditionHolds() {
        XCTAssertEqual(NotesExchangeGate.evaluate(allowedFacts()), .allowed)
    }

    func testFirstTrustIsAllowed() {
        // `firstTrust` (and `matched`, `notChecked`) map to pinningVerdictIsMismatch == false.
        let facts = NotesExchangeFacts(verdict: .firstTrust, isSecured: true, handshakeKey: key, helloKey: key,
                                       isLocalDirect: true, peerSupportsExchange: true, localSupportsExchange: true)
        XCTAssertFalse(facts.pinningVerdictIsMismatch)
        XCTAssertEqual(NotesExchangeGate.evaluate(facts), .allowed)
    }

    func testMismatchVerdictMapsToMismatchFact() {
        let facts = NotesExchangeFacts(verdict: .mismatch(stored: "aa", received: "bb"),
                                       isSecured: true, handshakeKey: key, helloKey: key,
                                       isLocalDirect: true, peerSupportsExchange: true, localSupportsExchange: true)
        XCTAssertTrue(facts.pinningVerdictIsMismatch)
        XCTAssertEqual(NotesExchangeGate.evaluate(facts), .denied(.pinningMismatch))
    }

    func testDeniedWhenNotSecured() {
        var f = allowedFacts(); f.isSecured = false
        XCTAssertEqual(NotesExchangeGate.evaluate(f), .denied(.notSecured))
    }

    func testDeniedWhenHandshakeKeyMissing() {
        var f = allowedFacts(); f.handshakeKey = nil
        XCTAssertEqual(NotesExchangeGate.evaluate(f), .denied(.handshakeKeyMissing))
        f.handshakeKey = Data()
        XCTAssertEqual(NotesExchangeGate.evaluate(f), .denied(.handshakeKeyMissing))
        f.handshakeKey = Data(repeating: 0x42, count: 31)
        XCTAssertEqual(NotesExchangeGate.evaluate(f), .denied(.handshakeKeyMissing))
    }

    func testDeniedWhenHelloKeyMissing() {
        var f = allowedFacts(); f.helloKey = nil
        XCTAssertEqual(NotesExchangeGate.evaluate(f), .denied(.helloKeyMissing))
        f.helloKey = Data()
        XCTAssertEqual(NotesExchangeGate.evaluate(f), .denied(.helloKeyMissing))
    }

    func testDeniedWhenHandshakeKeyDiffersFromHello() {
        var f = allowedFacts(); f.helloKey = Data(repeating: 0x43, count: 32)
        XCTAssertEqual(NotesExchangeGate.evaluate(f), .denied(.handshakeKeyMismatch))
    }

    func testDeniedWhenPinningMismatch() {
        var f = allowedFacts(); f.pinningVerdictIsMismatch = true
        XCTAssertEqual(NotesExchangeGate.evaluate(f), .denied(.pinningMismatch))
    }

    func testDeniedWhenNotLocalDirect() {
        var f = allowedFacts(); f.isLocalDirect = false
        XCTAssertEqual(NotesExchangeGate.evaluate(f), .denied(.notLocalDirect))
    }

    func testDeniedWhenPeerLacksFlag() {
        var f = allowedFacts(); f.peerSupportsExchange = false
        XCTAssertEqual(NotesExchangeGate.evaluate(f), .denied(.peerLacksSupport))
    }

    func testDeniedWhenLocalLacksFlag() {
        var f = allowedFacts(); f.localSupportsExchange = false
        XCTAssertEqual(NotesExchangeGate.evaluate(f), .denied(.localLacksSupport))
    }

    func testEveryCombinationOfFailuresIsDenied() {
        // Exhaustive: allowed iff all seven conditions hold.
        for mask in 0..<(1 << 7) {
            var f = allowedFacts()
            if mask & 1 != 0 { f.isSecured = false }
            if mask & 2 != 0 { f.handshakeKey = nil }
            if mask & 4 != 0 { f.helloKey = Data(repeating: 9, count: 32) }
            if mask & 8 != 0 { f.pinningVerdictIsMismatch = true }
            if mask & 16 != 0 { f.isLocalDirect = false }
            if mask & 32 != 0 { f.peerSupportsExchange = false }
            if mask & 64 != 0 { f.localSupportsExchange = false }
            let r = NotesExchangeGate.evaluate(f)
            if mask == 0 { XCTAssertEqual(r, .allowed) } else { XCTAssertNotEqual(r, .allowed, "mask \(mask)") }
        }
    }
}
