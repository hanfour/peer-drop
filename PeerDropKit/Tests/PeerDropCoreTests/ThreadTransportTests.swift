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
        // A permanently unavailable own account never queues: offline/nearby verified friends are locked,
        // online friends still chat live, and unbound/pending rows are unaffected.
        XCTAssertEqual(ThreadTransport.decide(presence: .offline, binding: .verified, account: .unavailable), .locked(reason: .accountUnavailable))
        XCTAssertEqual(ThreadTransport.decide(presence: .nearby, binding: .verified, account: .unavailable), .locked(reason: .accountUnavailable))
        XCTAssertEqual(ThreadTransport.decide(presence: .online, binding: .verified, account: .unavailable), .live)
        XCTAssertEqual(ThreadTransport.decide(presence: .offline, binding: .none, account: .unavailable), .locked(reason: .notExchanged))
        XCTAssertEqual(ThreadTransport.decide(presence: .offline, binding: .pending, account: .unavailable), .locked(reason: .verifying))
        for (p, b, a, expected) in rows {
            XCTAssertEqual(ThreadTransport.decide(presence: p, binding: b, account: a), expected, "\(p) \(b) \(a)")
        }
    }

    /// Project E: `.connecting` (waiting in the room / negotiating) is never live:
    /// it behaves like nearby/offline (note or locked).
    func testConnectingIsNeverLive() {
        let rows: [(BindingState, AccountAvailability, ThreadTransport.Decision)] = [
            (.none, .ready, .locked(reason: .notExchanged)), (.none, .notReady, .locked(reason: .notExchanged)),
            (.none, .unavailable, .locked(reason: .notExchanged)),
            (.pending, .ready, .locked(reason: .verifying)), (.pending, .notReady, .locked(reason: .verifying)),
            (.pending, .unavailable, .locked(reason: .verifying)),
            (.verified, .ready, .note(canSendNow: true)), (.verified, .notReady, .note(canSendNow: false)),
            (.verified, .unavailable, .locked(reason: .accountUnavailable)),
        ]
        for (b, a, expected) in rows {
            XCTAssertEqual(ThreadTransport.decide(presence: .connecting, binding: b, account: a), expected, "\(b) \(a)")
        }
    }

    /// Exhaustive: only `.online` is ever live.
    func testOnlyOnlineIsLiveForEveryPresence() {
        for p in PeerPresence.allCases {
            for b in [BindingState.none, .pending, .verified] {
                for a in [AccountAvailability.ready, .notReady, .unavailable] {
                    let live = ThreadTransport.decide(presence: p, binding: b, account: a) == .live
                    XCTAssertEqual(live, p == .online, "\(p) \(b) \(a)")
                }
            }
        }
    }
}
