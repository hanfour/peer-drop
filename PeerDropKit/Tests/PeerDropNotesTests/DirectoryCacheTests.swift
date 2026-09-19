import XCTest
@testable import PeerDropNotes

final class DirectoryCacheTests: XCTestCase {
    func testEntriesExpireAfterTTL() {
        var now = Date(timeIntervalSince1970: 1_000)
        let cache = DirectoryCache(ttl: 60, now: { now })
        XCTAssertNil(cache.get("A1"))
        cache.set("A1", signingKey: Data([1]), nickname: "n")
        XCTAssertEqual(cache.get("A1")?.signingKey, Data([1]))
        XCTAssertEqual(cache.get("A1")?.nickname, "n")
        now = now.addingTimeInterval(61)
        XCTAssertNil(cache.get("A1"))
    }

    func testSecondSetReplacesEntryAndRefreshesFetchedAt() {
        var now = Date(timeIntervalSince1970: 1_000)
        let cache = DirectoryCache(ttl: 60, now: { now })
        cache.set("A1", signingKey: Data([1]), nickname: "n")
        now = now.addingTimeInterval(30)
        cache.set("A1", signingKey: Data([2]), nickname: "n2")
        XCTAssertEqual(cache.get("A1")?.signingKey, Data([2]))
        XCTAssertEqual(cache.get("A1")?.nickname, "n2")
        // fetchedAt was refreshed by the second set: 61s after the FIRST set
        // (i.e. 31s after the second) is still within the 60s TTL.
        now = now.addingTimeInterval(31)
        XCTAssertNotNil(cache.get("A1"))
        now = now.addingTimeInterval(30)
        XCTAssertNil(cache.get("A1"))
    }
}
