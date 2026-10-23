import XCTest
@testable import PeerDrop

final class AppTabTests: XCTestCase {
    func testRawValuesAreStable() {
        XCTAssertEqual(AppTab.home.rawValue, 0)
        XCTAssertEqual(AppTab.notes.rawValue, 1)
        XCTAssertEqual(AppTab.nearby.rawValue, 2)
        XCTAssertEqual(AppTab.diaries.rawValue, 3)
    }

    func testAllCasesOrder() {
        XCTAssertEqual(AppTab.allCases, [.home, .notes, .nearby, .diaries])
    }

    func testDeepLinkTargets() {
        XCTAssertEqual(AppTab.tab(forDeepLink: .openNote), .notes)
        XCTAssertEqual(AppTab.tab(forDeepLink: .openDiary), .diaries)
        XCTAssertNil(AppTab.tab(forDeepLink: Notification.Name("other")))
    }

    func testInboxDeepLinkActions() {
        XCTAssertEqual(InboxDeepLink.action(inboxShowing: false, chatShowing: false), .push)
        XCTAssertEqual(InboxDeepLink.action(inboxShowing: true, chatShowing: false), .none)
        XCTAssertEqual(InboxDeepLink.action(inboxShowing: false, chatShowing: true), .dismissChatThenPush)
        XCTAssertEqual(InboxDeepLink.action(inboxShowing: true, chatShowing: true), .none)
    }

    func testNoMagicNumbersRemain() throws {
        let dir = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let regex = try NSRegularExpression(pattern: #"selectedTab\s*=\s*\d"#)
        let tagRegex = try NSRegularExpression(pattern: #"\.tag\(\d"#)
        let cv = try String(contentsOf: dir.appendingPathComponent("PeerDrop/UI/ContentView.swift"), encoding: .utf8)
        XCTAssertEqual(tagRegex.numberOfMatches(in: cv, range: NSRange(cv.startIndex..., in: cv)), 0, "ContentView still has a numeric .tag")
        for rel in ["PeerDrop/UI/ContentView.swift", "PeerDrop/UI/Discovery/NearbyTab.swift"] {
            let src = try String(contentsOf: dir.appendingPathComponent(rel), encoding: .utf8)
            let n = regex.numberOfMatches(in: src, range: NSRange(src.startIndex..., in: src))
            XCTAssertEqual(n, 0, "\(rel) still assigns a numeric selectedTab")
        }
    }
}
