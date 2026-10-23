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

    func testNoMagicNumbersRemain() throws {
        let dir = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let regex = try NSRegularExpression(pattern: #"selectedTab\s*=\s*\d"#)
        for rel in ["PeerDrop/UI/ContentView.swift", "PeerDrop/UI/Discovery/NearbyTab.swift"] {
            let src = try String(contentsOf: dir.appendingPathComponent(rel), encoding: .utf8)
            let n = regex.numberOfMatches(in: src, range: NSRange(src.startIndex..., in: src))
            XCTAssertEqual(n, 0, "\(rel) still assigns a numeric selectedTab")
        }
    }
}
