import XCTest
@testable import PeerDrop

/// PeerDropTests is an iOS bundle and cannot import PeerDropMac types, so the Mac sidebar
/// contract is pinned two ways: the shared `AppTab.sidebarKey` mapping (compiled by both
/// targets) and a source check of the `MacSidebarSection` enum in MacSidebar.swift.
final class MacSidebarSectionTests: XCTestCase {
    private func macSidebarSource() throws -> String {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        return try String(contentsOf: root.appendingPathComponent("PeerDropMac/Views/MacSidebar.swift"), encoding: .utf8)
    }

    private func enumBlock(_ src: String) throws -> String {
        let start = try XCTUnwrap(src.range(of: "enum MacSidebarSection"))
        let end = try XCTUnwrap(src.range(of: "var id: Self", range: start.upperBound..<src.endIndex))
        return String(src[start.lowerBound..<end.lowerBound])
    }

    func testSectionOrderAndCount() throws {
        XCTAssertEqual(AppTab.allCases.map(\.sidebarKey), ["home", "notes", "nearby", "diaries"])
        let block = try enumBlock(try macSidebarSource())
        let cases = block.split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { $0.hasPrefix("case ") }
            .flatMap { $0.dropFirst(5).split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) } }
        XCTAssertEqual(cases, ["home", "notes", "nearby", "diaries"])
    }

    func testEveryCaseHasNameAndIcon() throws {
        let src = try macSidebarSource()
        for (name, icon) in [("Home", "house"), ("Notes", "envelope.fill"), ("Nearby", "wifi"), ("Diaries", "book.closed")] {
            XCTAssertTrue(src.contains("NSLocalizedString(\"\(name)\""), "missing localizedName for \(name)")
            XCTAssertTrue(src.contains("\"\(icon)\""), "missing icon \(icon)")
        }
    }

    func testNoRetiredSections() throws {
        let src = try macSidebarSource()
        XCTAssertFalse(src.contains("case trusted"))
        XCTAssertFalse(src.contains("case relay"))
        XCTAssertNil(AppTab(sidebarKey: "trusted"))
        XCTAssertNil(AppTab(sidebarKey: "relay"))
    }

    func testSidebarKeyRoundTrip() {
        for tab in AppTab.allCases { XCTAssertEqual(AppTab(sidebarKey: tab.sidebarKey), tab) }
    }
}
