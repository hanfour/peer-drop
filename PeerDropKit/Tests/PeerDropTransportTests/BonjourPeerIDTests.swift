import XCTest
import Network
@testable import PeerDropTransport

/// Regression coverage for the peer-ID namespace split (audit round 15):
///
/// `connections` (ConnectionManager) is keyed by the peer's identity UUID,
/// but Bonjour's `DiscoveredPeer.id` was the service string
/// "name.type.domain". Every UI lookup that fed a DiscoveredPeer.id into
/// `connection(for:)` / `isConnected(to:)` missed, so on the acceptor side
/// (Mac) the chat input stayed `.disabled`, `lastConnectedPeer` never set,
/// and NearbyTab re-initiated connections to already-connected peers.
///
/// Fix: the advertiser publishes its identity UUID in the service TXT
/// record ("pid"); the browser prefers that as DiscoveredPeer.id and falls
/// back to the legacy service string for pre-v6 peers that don't send TXT.
final class BonjourPeerIDTests: XCTestCase {

    func testResolvedPeerIDPrefersTXTRecordPid() {
        var txt = NWTXTRecord()
        txt["pid"] = "ABC-123-UUID"
        let id = BonjourDiscovery.resolvedPeerID(
            name: "iPhone 16",
            type: "_peerdrop._tcp",
            domain: "local.",
            metadata: .bonjour(txt)
        )
        XCTAssertEqual(id, "ABC-123-UUID")
    }

    func testResolvedPeerIDFallsBackWithoutTXT() {
        let id = BonjourDiscovery.resolvedPeerID(
            name: "iPhone 16",
            type: "_peerdrop._tcp",
            domain: "local.",
            metadata: nil
        )
        XCTAssertEqual(id, "iPhone 16._peerdrop._tcp.local.")
    }

    func testResolvedPeerIDFallsBackWithEmptyPid() {
        var txt = NWTXTRecord()
        txt["pid"] = ""
        let id = BonjourDiscovery.resolvedPeerID(
            name: "iPhone 16",
            type: "_peerdrop._tcp",
            domain: "local.",
            metadata: .bonjour(txt)
        )
        XCTAssertEqual(id, "iPhone 16._peerdrop._tcp.local.", "empty pid must not become the peer ID")
    }

    func testResolvedPeerIDFallsBackWithUnrelatedTXTKeys() {
        var txt = NWTXTRecord()
        txt["other"] = "x"
        let id = BonjourDiscovery.resolvedPeerID(
            name: "Mac mini",
            type: "_peerdrop._tcp",
            domain: "local.",
            metadata: .bonjour(txt)
        )
        XCTAssertEqual(id, "Mac mini._peerdrop._tcp.local.")
    }
}
