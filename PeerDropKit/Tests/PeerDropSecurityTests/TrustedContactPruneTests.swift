import XCTest
@testable import PeerDropSecurity

/// `staleContactIDs` backs the CLI `--prune` command: it selects trusted
/// contacts whose last activity (lastVerified, else firstConnected) is
/// older than the cutoff. Pure + deterministic so the CLI stays testable.
final class TrustedContactPruneTests: XCTestCase {

    private func contact(name: String, firstConnected: Date, lastVerified: Date? = nil) -> TrustedContact {
        TrustedContact(displayName: name, identityPublicKey: Data([1, 2, 3]),
                       trustLevel: .verified, firstConnected: firstConnected, lastVerified: lastVerified)
    }

    func test_selectsContactsStaleByLastVerified() {
        let now = Date(timeIntervalSince1970: 1_000_000_000)
        let day: TimeInterval = 86400
        let fresh = contact(name: "fresh", firstConnected: now - 100 * day, lastVerified: now - 5 * day)
        let stale = contact(name: "stale", firstConnected: now - 100 * day, lastVerified: now - 40 * day)

        let ids = TrustedContactStore.staleContactIDs(in: [fresh, stale], olderThanDays: 30, now: now)
        XCTAssertEqual(ids, [stale.id])
    }

    func test_fallsBackToFirstConnectedWhenNeverVerified() {
        let now = Date(timeIntervalSince1970: 1_000_000_000)
        let day: TimeInterval = 86400
        let neverVerifiedOld = contact(name: "old", firstConnected: now - 40 * day, lastVerified: nil)
        let neverVerifiedNew = contact(name: "new", firstConnected: now - 10 * day, lastVerified: nil)

        let ids = TrustedContactStore.staleContactIDs(in: [neverVerifiedOld, neverVerifiedNew], olderThanDays: 30, now: now)
        XCTAssertEqual(ids, [neverVerifiedOld.id])
    }

    func test_emptyWhenAllFresh() {
        let now = Date(timeIntervalSince1970: 1_000_000_000)
        let c = contact(name: "c", firstConnected: now - 1 * 86400, lastVerified: now - 1 * 86400)
        XCTAssertTrue(TrustedContactStore.staleContactIDs(in: [c], olderThanDays: 30, now: now).isEmpty)
    }
}
