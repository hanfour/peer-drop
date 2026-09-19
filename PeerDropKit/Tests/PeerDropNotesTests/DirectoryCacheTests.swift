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
}
