import XCTest
import PeerDropGroups
@testable import PeerDrop

@MainActor
final class GroupWiringTests: XCTestCase {
    private let groupId = "01ARZ3NDEKTSV4RRFFQ69G5FAV"

    func testGroupInviteLinkSetsPendingInvite() {
        let store = GroupStore(mock: [], states: [:])
        let url = URL(string: "peerdrop://group/\(groupId)?code=invite-code")!

        store.setPendingInvite(from: url)

        XCTAssertEqual(store.pendingInvite?.groupId, groupId)
        XCTAssertEqual(store.pendingInvite?.code, "invite-code")
    }

    func testDiaryLinkDoesNotSetPendingInvite() {
        let store = GroupStore(mock: [], states: [:])
        let url = URL(string: "peerdrop://diary/\(groupId)?code=diary-code")!

        store.setPendingInvite(from: url)

        XCTAssertNil(store.pendingInvite)
    }

    func testGroupMessageLocalizationExistsInAllLanguages() throws {
        let localizationURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("PeerDrop/App/Localizable.xcstrings")
        let data = try Data(contentsOf: localizationURL)
        let document = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let strings = try XCTUnwrap(document["strings"] as? [String: Any])
        let entry = try XCTUnwrap(strings["GROUP_MESSAGE"] as? [String: Any])
        let localizations = try XCTUnwrap(entry["localizations"] as? [String: Any])
        let expected = [
            "en": "New message",
            "zh-Hant": "有新訊息",
            "zh-Hans": "有新消息",
            "ja": "新着メッセージがあります",
            "ko": "새 메시지가 있습니다",
        ]

        for (language, value) in expected {
            let localization = try XCTUnwrap(localizations[language] as? [String: Any], language)
            let unit = try XCTUnwrap(localization["stringUnit"] as? [String: Any], language)
            XCTAssertEqual(unit["value"] as? String, value, language)
            if ["ja", "ko", "zh-Hans"].contains(language) {
                XCTAssertEqual(unit["state"] as? String, "needs_review", language)
            }
        }
    }
}
