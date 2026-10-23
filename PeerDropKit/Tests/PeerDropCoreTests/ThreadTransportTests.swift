import XCTest
@testable import PeerDropCore

final class ThreadTransportTests: XCTestCase {
    func testFullTable() {
        let presences: [PeerPresence] = [.online, .nearby, .offline]
        let bindings: [BindingState] = [.none, .pending, .verified]
        let accounts: [AccountAvailability] = [.ready, .notReady]
        for p in presences { for b in bindings { for a in accounts {
            let d = ThreadTransport.decide(presence: p, binding: b, account: a)
            let expected: ThreadTransport.Decision
            if p == .online { expected = .live(showExchangeButton: b != .verified) }
            else if b == .verified { expected = .note(canSendNow: a == .ready) }
            else if b == .pending { expected = .locked(reason: .verifying) }
            else { expected = .locked(reason: .notExchanged) }
            XCTAssertEqual(d, expected, "\(p) \(b) \(a)")
        } } }
    }

    func testSpotChecks() {
        XCTAssertEqual(ThreadTransport.decide(presence: .online, binding: .none, account: .notReady), .live(showExchangeButton: true))
        XCTAssertEqual(ThreadTransport.decide(presence: .online, binding: .verified, account: .ready), .live(showExchangeButton: false))
        XCTAssertEqual(ThreadTransport.decide(presence: .offline, binding: .verified, account: .ready), .note(canSendNow: true))
        XCTAssertEqual(ThreadTransport.decide(presence: .nearby, binding: .verified, account: .notReady), .note(canSendNow: false))
        XCTAssertEqual(ThreadTransport.decide(presence: .offline, binding: .pending, account: .ready), .locked(reason: .verifying))
        XCTAssertEqual(ThreadTransport.decide(presence: .offline, binding: .none, account: .ready), .locked(reason: .notExchanged))
    }
}
