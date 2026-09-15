import XCTest
@testable import PeerDropAccount

final class AccountIDTests: XCTestCase {
    func testParseNormalizes() {
        XCTAssertEqual(AccountID.parse("abcd-efgh")?.raw, "ABCDEFGH")
        XCTAssertEqual(AccountID.parse(" 0o1i lL2Z ")?.raw, "00111122".replacingOccurrences(of: "22", with: "2Z"))
        XCTAssertNil(AccountID.parse("ABCDEFG"))
        XCTAssertNil(AccountID.parse("ABCDEFGU"))
        XCTAssertNil(AccountID.parse(""))
    }
    func testDisplayInsertsHyphen() {
        XCTAssertEqual(AccountID(raw: "ABCDEFGH")?.display, "ABCD-EFGH")
        XCTAssertNil(AccountID(raw: "abcdefgh"), "init(raw:) is strict; use parse for user input")
    }
    func testCodableRoundTrip() throws {
        let id = AccountID(raw: "7K3MQ2ZD")!
        let data = try JSONEncoder().encode(id)
        XCTAssertEqual(String(decoding: data, as: UTF8.self), "\"7K3MQ2ZD\"")
        XCTAssertEqual(try JSONDecoder().decode(AccountID.self, from: data), id)
    }
}
