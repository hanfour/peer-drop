import XCTest
@testable import PeerDropCore

final class ThreadTransportTests: XCTestCase {
    func testLiteralTable() {
        typealias D = ThreadTransport.Decision
        let rows: [(PeerPresence, BindingState, AccountAvailability, D)] = [
            (.online, .none, .ready, .live), (.online, .none, .notReady, .live),
            (.online, .pending, .ready, .live), (.online, .pending, .notReady, .live),
            (.online, .verified, .ready, .live), (.online, .verified, .notReady, .live),
            (.nearby, .none, .ready, .locked(reason: .notExchanged)), (.nearby, .none, .notReady, .locked(reason: .notExchanged)),
            (.nearby, .pending, .ready, .locked(reason: .verifying)), (.nearby, .pending, .notReady, .locked(reason: .verifying)),
            (.nearby, .verified, .ready, .note(canSendNow: true)), (.nearby, .verified, .notReady, .note(canSendNow: false)),
            (.offline, .none, .ready, .locked(reason: .notExchanged)), (.offline, .none, .notReady, .locked(reason: .notExchanged)),
            (.offline, .pending, .ready, .locked(reason: .verifying)), (.offline, .pending, .notReady, .locked(reason: .verifying)),
            (.offline, .verified, .ready, .note(canSendNow: true)), (.offline, .verified, .notReady, .note(canSendNow: false)),
        ]
        XCTAssertEqual(rows.count, 18)
        for (p, b, a, expected) in rows {
            XCTAssertEqual(ThreadTransport.decide(presence: p, binding: b, account: a), expected, "\(p) \(b) \(a)")
        }
    }
}
