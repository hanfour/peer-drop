import XCTest
@testable import PeerDrop
import PeerDropCore

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

    func testInboxRequestConsumedOnlyWhilePending() {
        XCTAssertTrue(InboxDeepLink.shouldConsume(pending: 1))
        XCTAssertTrue(InboxDeepLink.shouldConsume(pending: 3))
        // Once the tab resets the counter to 0, a rebuilt view must not replay it.
        XCTAssertFalse(InboxDeepLink.shouldConsume(pending: 0))
    }

    func testRefreshGateOnlyWhileOnScreen() {
        var gate = ConversationsRefreshGate()
        XCTAssertFalse(gate.shouldRefreshOnChange)
        gate.appear()
        XCTAssertTrue(gate.shouldRefreshOnChange)
        gate.disappear()
        XCTAssertFalse(gate.shouldRefreshOnChange)
    }

    func testInfoButtonOnlyForOnlinePeer() {
        XCTAssertTrue(ChatPresenceMode.showsInfoButton(presence: .online))
        XCTAssertFalse(ChatPresenceMode.showsInfoButton(presence: .nearby))
        XCTAssertFalse(ChatPresenceMode.showsInfoButton(presence: .offline))
    }

    func testConnectingVoiceOverLabelSkipsPresence() {
        XCTAssertEqual(FriendRowAccessibility.label(name: "Amy", presenceLabel: "Nearby, not connected", subtitle: "Connecting...", isConnecting: true), "Amy, Connecting...")
        XCTAssertEqual(FriendRowAccessibility.label(name: "Amy", presenceLabel: "Online", subtitle: "Connected", isConnecting: false), "Amy, Online, Connected")
    }

    // MARK: tabAfterConnectionChange

    func testNewConnectionFromNearbyGoesHome() {
        for old: ConnectionState in [.idle, .discovering, .peerFound, .requesting, .connecting] {
            XCTAssertEqual(AppTab.tabAfterConnectionChange(from: old, to: .connected, current: .nearby), .home, "\(old)")
        }
    }

    func testNeverSwitchesAwayFromNotesOrDiaries() {
        for tab in [AppTab.notes, .diaries, .home] {
            XCTAssertEqual(AppTab.tabAfterConnectionChange(from: .connecting, to: .connected, current: tab), tab)
        }
    }

    func testTransitionsAmongLiveStatesNeverSwitch() {
        let live: [ConnectionState] = [.connected, .transferring(progress: 0.5), .voiceCall]
        for a in live { for b in live {
            XCTAssertEqual(AppTab.tabAfterConnectionChange(from: a, to: b, current: .nearby), .nearby)
            XCTAssertEqual(AppTab.tabAfterConnectionChange(from: a, to: b, current: .notes), .notes)
        } }
    }

    func testNonConnectedTargetsNeverSwitch() {
        XCTAssertEqual(AppTab.tabAfterConnectionChange(from: .connected, to: .disconnected, current: .nearby), .nearby)
        XCTAssertEqual(AppTab.tabAfterConnectionChange(from: .idle, to: .failed(reason: "x"), current: .nearby), .nearby)
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
