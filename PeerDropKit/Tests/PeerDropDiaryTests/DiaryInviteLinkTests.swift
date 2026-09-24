import XCTest
@testable import PeerDropDiary

final class DiaryInviteLinkTests: XCTestCase {
    private func did(_ label: String) -> String {
        precondition(label.count <= 26)
        precondition(label.allSatisfy { "0123456789ABCDEFGHJKMNPQRSTVWXYZ".contains($0) }, "'\(label)' isn't a valid diary-id label")
        return label + String(repeating: "0", count: 26 - label.count)
    }

    func testParsesAWellFormedLink() {
        let diaryId = did("PRSCK1")
        let url = URL(string: "peerdrop://diary/\(diaryId)?code=CODE1234#k=QUJDRA")!
        let parsed = DiaryInviteLink.parse(url)
        XCTAssertEqual(parsed?.diaryId, diaryId)
        XCTAssertEqual(parsed?.code, "CODE1234")
        XCTAssertNotNil(parsed?.key)
    }

    func testWrongHostReturnsNil() {
        XCTAssertNil(DiaryInviteLink.parse(URL(string: "peerdrop://notdiary/\(did("X1"))?code=C")!))
    }

    func testMissingIdReturnsNil() {
        XCTAssertNil(DiaryInviteLink.parse(URL(string: "peerdrop://diary/?code=C")!))
    }

    func testMissingCodeReturnsNil() {
        XCTAssertNil(DiaryInviteLink.parse(URL(string: "peerdrop://diary/\(did("X1"))")!))
    }

    func testEmptyCodeReturnsNil() {
        XCTAssertNil(DiaryInviteLink.parse(URL(string: "peerdrop://diary/\(did("X1"))?code=")!))
    }

    func testMissingOrMalformedKeyFragmentStillParsesWithNilKey() {
        let diaryId = did("PRSNKEY1")
        let noFragment = DiaryInviteLink.parse(URL(string: "peerdrop://diary/\(diaryId)?code=CODE1234")!)
        XCTAssertEqual(noFragment?.diaryId, diaryId)
        XCTAssertNil(noFragment?.key)

        let malformedFragment = DiaryInviteLink.parse(URL(string: "peerdrop://diary/\(diaryId)?code=CODE1234#k=not*valid*base64url")!)
        XCTAssertEqual(malformedFragment?.diaryId, diaryId)
        XCTAssertNil(malformedFragment?.key)
    }

    // MARK: - Review round 1, minor: log-safe description never includes query/fragment

    func testLogSafeDescriptionNeverIncludesQueryOrFragment() {
        let diaryId = did("PRSDESC1")
        let url = URL(string: "peerdrop://diary/\(diaryId)?code=SUPERSECRETCODE#k=SUPERSECRETKEYBASE64")!
        let description = DiaryInviteLink.logSafeDescription(url)

        XCTAssertEqual(description, "peerdrop://diary")
        XCTAssertFalse(description.contains("SUPERSECRETCODE"))
        XCTAssertFalse(description.contains("SUPERSECRETKEYBASE64"))
        XCTAssertFalse(description.contains("code="))
        XCTAssertFalse(description.contains("k="))
        XCTAssertFalse(description.contains(diaryId))
    }
}
