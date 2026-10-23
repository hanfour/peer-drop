import XCTest
import PeerDropCore
@testable import PeerDrop

final class ChatPresenceModeTests: XCTestCase {
    func testOnlineIsLive() { XCTAssertEqual(ChatPresenceMode.mode(for: .online), .live) }
    func testNearbyIsNote() { XCTAssertEqual(ChatPresenceMode.mode(for: .nearby), .note) }
    func testOfflineIsNote() { XCTAssertEqual(ChatPresenceMode.mode(for: .offline), .note) }
}
