import Foundation

/// Represents a manually-entered peer (e.g., over Tailscale VPN).
struct TailscalePeer {
    let host: String
    let port: UInt16
    let displayName: String?

    var endpoint: PeerEndpoint {
        .manual(host: host, port: port)
    }

    func toDiscoveredPeer() -> DiscoveredPeer {
        DiscoveredPeer(
            id: "\(host):\(port)",
            displayName: displayName ?? host,
            endpoint: endpoint,
            source: .manual
        )
    }
}
