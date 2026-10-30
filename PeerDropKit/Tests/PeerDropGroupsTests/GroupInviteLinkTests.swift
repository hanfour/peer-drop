import Foundation
import XCTest
@testable import PeerDropGroups

final class GroupInviteLinkTests: XCTestCase {
    private let groupId = GroupTestFixtures.groupId

    func testInviteLinkRoundTrip() {
        let url = GroupInviteLink.make(groupId: groupId, code: "JOIN1234")
        let parsed = GroupInviteLink.parse(url)

        XCTAssertEqual(parsed?.groupId, groupId)
        XCTAssertEqual(parsed?.code, "JOIN1234")
    }

    func testWrongHostOrSchemeIsRejected() {
        XCTAssertNil(GroupInviteLink.parse(URL(string: "peerdrop://other/\(groupId)?code=JOIN1234")!))
        XCTAssertNil(GroupInviteLink.parse(URL(string: "https://group/\(groupId)?code=JOIN1234")!))
    }

    func testMissingOrEmptyCodeIsRejected() {
        XCTAssertNil(GroupInviteLink.parse(URL(string: "peerdrop://group/\(groupId)")!))
        XCTAssertNil(GroupInviteLink.parse(URL(string: "peerdrop://group/\(groupId)?code=")!))
    }

    func testInvalidGroupIdIsRejected() {
        XCTAssertNil(GroupInviteLink.parse(URL(string: "peerdrop://group/SHORT?code=JOIN1234")!))
    }

    func testLogSafeDescriptionOmitsGroupIdAndCode() {
        let url = GroupInviteLink.make(groupId: groupId, code: "SUPERSECRET")
        let description = GroupInviteLink.logSafeDescription(url)

        XCTAssertEqual(description, "peerdrop://group")
        XCTAssertFalse(description.contains(groupId))
        XCTAssertFalse(description.contains("SUPERSECRET"))
        XCTAssertFalse(description.contains("code="))
    }
}
