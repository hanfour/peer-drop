import XCTest
import Network
@testable import PeerDropTransport

/// The advertiser publishes whether it's a headless CLI/agent peer in the
/// service TXT record ("role"), so a browsing peer can tell app-vs-headless
/// BEFORE connecting (isHeadless is otherwise only known post-handshake via
/// PeerIdentity). Absent/unknown role → not headless (legacy peers).
final class BonjourRoleTXTTests: XCTestCase {

    func testResolvedIsHeadlessTrueForHeadlessRole() {
        var txt = NWTXTRecord()
        txt["role"] = "headless"
        XCTAssertTrue(BonjourDiscovery.resolvedIsHeadless(metadata: .bonjour(txt)))
    }

    func testResolvedIsHeadlessFalseForAppRole() {
        var txt = NWTXTRecord()
        txt["role"] = "app"
        XCTAssertFalse(BonjourDiscovery.resolvedIsHeadless(metadata: .bonjour(txt)))
    }

    func testResolvedIsHeadlessFalseWhenAbsent() {
        var txt = NWTXTRecord()
        txt["pid"] = "some-uuid"
        XCTAssertFalse(BonjourDiscovery.resolvedIsHeadless(metadata: .bonjour(txt)))
        XCTAssertFalse(BonjourDiscovery.resolvedIsHeadless(metadata: nil))
    }
}
