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
