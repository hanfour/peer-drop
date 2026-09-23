import XCTest
@testable import PeerDropAccount

final class NicknameTests: XCTestCase {
    func testRules() {
        XCTAssertEqual(Nickname.validate("mo"), .tooShort)
        XCTAssertEqual(Nickname.validate(String(repeating: "a", count: 21)), .tooLong)
        XCTAssertEqual(Nickname.validate("mo chi"), .invalidCharacters)
        XCTAssertEqual(Nickname.validate("mo-chi"), .invalidCharacters)
        XCTAssertEqual(Nickname.validate("Admin"), .reserved)
        XCTAssertEqual(Nickname.validate("麻糬_01"), .ok("麻糬_01"))
        XCTAssertEqual(Nickname.validate("e\u{0301}clair"), .ok("éclair"))
    }
}
