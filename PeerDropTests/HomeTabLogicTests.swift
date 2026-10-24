import XCTest
import PeerDropCore
@testable import PeerDrop

final class HomeTabLogicTests: XCTestCase {
    private func rec(_ id: String, _ name: String) -> DeviceRecord {
        DeviceRecord(id: id, displayName: name, sourceType: "bonjour", lastConnected: Date(), connectionCount: 1)
    }

    private func presence(online: Set<String>) -> (DeviceRecord) -> PeerPresence {
        { online.contains($0.id) ? .online : .offline }
    }

    func testSectionsDoNotOverlapAndAreSorted() {
        let all = [rec("1", "Zed"), rec("2", "Amy"), rec("3", "Mika"), rec("4", "Bob")]
        let r = HomeListLogic.sections(records: all, presence: presence(online: ["1", "3"]), query: "")
        XCTAssertEqual(r.connected.map(\.displayName), ["Mika", "Zed"])
        XCTAssertEqual(r.friends.map(\.displayName), ["Amy", "Bob"])
        XCTAssertTrue(Set(r.connected.map(\.id)).isDisjoint(with: r.friends.map(\.id)))
    }

    func testNearbyCountsAsFriendNotConnected() {
        let r = HomeListLogic.sections(records: [rec("1", "Amy")], presence: { _ in .nearby }, query: "")
        XCTAssertTrue(r.connected.isEmpty)
        XCTAssertEqual(r.friends.count, 1)
    }

    func testSearchMatchesNameCaseInsensitive() {
        let all = [rec("1", "Mika"), rec("2", "Jordan")]
        let r = HomeListLogic.sections(records: all, presence: presence(online: []), query: "mi")
        XCTAssertEqual(r.friends.map(\.displayName), ["Mika"])
        let none = HomeListLogic.sections(records: all, presence: presence(online: []), query: "xyz")
        XCTAssertTrue(none.friends.isEmpty && none.connected.isEmpty)
    }

    func testSearchFullWidth() {
        let all = [rec("1", "Mika"), rec("2", "Jordan")]
        let r = HomeListLogic.sections(records: all, presence: presence(online: []), query: "ＭＩ")
        XCTAssertEqual(r.friends.map(\.displayName), ["Mika"])
        let r2 = HomeListLogic.sections(records: [rec("3", "ＭＩＫＡ")], presence: presence(online: []), query: "mi")
        XCTAssertEqual(r2.friends.count, 1)
    }

    func testSearchIgnoresSurroundingWhitespaceAndFiltersConnectedToo() {
        let all = [rec("1", "Mika"), rec("2", "Mia")]
        let r = HomeListLogic.sections(records: all, presence: presence(online: ["1"]), query: "  mik ")
        XCTAssertEqual(r.connected.map(\.displayName), ["Mika"])
        XCTAssertTrue(r.friends.isEmpty)
    }

    func testEmptyQueryListsAll() {
        let all = [rec("1", "A"), rec("2", "B")]
        let r = HomeListLogic.sections(records: all, presence: presence(online: ["1"]), query: "")
        XCTAssertEqual(r.connected.count + r.friends.count, 2)
    }

    // MARK: FriendSubtitle

    func testSubtitleOnlineLocalAndRelay() {
        XCTAssertEqual(FriendSubtitle.text(presence: .online, lastConnected: Date(), connectionCount: 3, source: "bonjour"),
                       String(localized: "Connected · Local network"))
        XCTAssertEqual(FriendSubtitle.text(presence: .online, lastConnected: Date(), connectionCount: 3, source: "relay"),
                       String(localized: "Connected · Relay"))
    }

    func testSubtitleNearby() {
        XCTAssertEqual(FriendSubtitle.text(presence: .nearby, lastConnected: Date(), connectionCount: 0, source: "bonjour"),
                       String(localized: "Nearby · ready to connect"))
    }

    func testSubtitleOfflineWithHistory() {
        let now = Date()
        let past = now.addingTimeInterval(-3 * 3600)
        let f = RelativeDateTimeFormatter(); f.unitsStyle = .short
        let rel = f.localizedString(for: past, relativeTo: now)
        let text = FriendSubtitle.text(presence: .offline, lastConnected: past, connectionCount: 2, source: "bonjour", now: now)
        XCTAssertTrue(text.contains(rel), text)
    }

    /// Project E: a cross-network friend waiting / negotiating shows "Connecting...", no Connect pill.
    func testSubtitleAndPillForCrossNetworkConnecting() {
        XCTAssertEqual(FriendSubtitle.text(presence: .connecting, lastConnected: Date(), connectionCount: 4, source: "bonjour"),
                       String(localized: "Connecting..."))
        XCTAssertFalse(HomeListLogic.showsConnectPill(presence: .connecting, isConnecting: false))
    }

    func testSubtitleOfflineNeverConnected() {
        XCTAssertEqual(FriendSubtitle.text(presence: .offline, lastConnected: Date(), connectionCount: 0, source: "bonjour"),
                       String(localized: "Not connected yet"))
    }

    func testEqualNamesTieBreakById() {
        let all = [rec("b", "Sam"), rec("a", "Sam"), rec("c", "sam")]
        let r = HomeListLogic.sections(records: all, presence: presence(online: []), query: "")
        XCTAssertEqual(r.friends.map(\.id), ["a", "b", "c"])
    }

    func testConnectPillHiddenWhileConnecting() {
        XCTAssertTrue(HomeListLogic.showsConnectPill(presence: .nearby, isConnecting: false))
        XCTAssertFalse(HomeListLogic.showsConnectPill(presence: .nearby, isConnecting: true))
        XCTAssertFalse(HomeListLogic.showsConnectPill(presence: .offline, isConnecting: false))
        XCTAssertFalse(HomeListLogic.showsConnectPill(presence: .online, isConnecting: false))
    }

    func testSubtitleConnectingIsNeutral() {
        XCTAssertEqual(FriendSubtitle.text(presence: .nearby, lastConnected: Date(), connectionCount: 1, source: "bonjour", isConnecting: true),
                       String(localized: "Connecting..."))
        XCTAssertEqual(FriendSubtitle.text(presence: .online, lastConnected: Date(), connectionCount: 1, source: "bonjour", isConnecting: true),
                       String(localized: "Connected · Local network"))
    }

    func testSectionsUseResolvedNameForSearchAndSort() {
        let all = [rec("1", "relay-ab12"), rec("2", "Zed")]
        let names = ["1": "Amy", "2": "Zed"]
        let r = HomeListLogic.sections(records: all, presence: { _ in .offline }, query: "am", name: { names[$0.id] ?? $0.displayName })
        XCTAssertEqual(r.friends.map(\.id), ["1"])
        let sorted = HomeListLogic.sections(records: all, presence: { _ in .offline }, query: "", name: { names[$0.id] ?? $0.displayName })
        XCTAssertEqual(sorted.friends.map(\.id), ["1", "2"])
    }
}
