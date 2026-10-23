import XCTest
@testable import PeerDropCore

final class ChatDisplayNameTests: XCTestCase {
    func testNilReturnsNil() {
        XCTAssertNil(ChatDisplayName.trimmed(nil))
    }

    func testEmptyReturnsNil() {
        XCTAssertNil(ChatDisplayName.trimmed(""))
    }

    func testWhitespaceOnlyReturnsNil() {
        XCTAssertNil(ChatDisplayName.trimmed("   "))
        XCTAssertNil(ChatDisplayName.trimmed("  \n\t "))
    }

    func testNormalNameIsTrimmed() {
        XCTAssertEqual(ChatDisplayName.trimmed("  小安 "), "小安")
    }

    func testLongNameIsNotTruncated() {
        let long = String(repeating: "a", count: 200)
        XCTAssertEqual(ChatDisplayName.trimmed(long), long)
    }
}

/// The chat should show the peer's CURRENT name, not the name each message
/// happened to be stored with (identity is fixed at handshake, so old messages
/// can carry an old or blank name).
final class ChatDisplayNamePreferredTests: XCTestCase {
    func test_firstNonBlankWins() {
        XCTAssertEqual(ChatDisplayName.preferred("小安", "舊名字"), "小安")
    }

    func test_blankLiveNameFallsThroughToStored() {
        XCTAssertEqual(ChatDisplayName.preferred(nil, "舊名字"), "舊名字")
        XCTAssertEqual(ChatDisplayName.preferred("  ", "舊名字"), "舊名字")
    }

    func test_allBlankReturnsNil() {
        XCTAssertNil(ChatDisplayName.preferred(nil, "", "  \n"))
        XCTAssertNil(ChatDisplayName.preferred())
    }
}
