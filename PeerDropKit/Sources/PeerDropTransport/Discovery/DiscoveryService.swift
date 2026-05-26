import Foundation
import Combine

/// A discovered peer on the network.
public struct DiscoveredPeer: Identifiable, Hashable {
    public let id: String
    public let displayName: String
    public let endpoint: PeerEndpoint
    public let source: DiscoverySource
    public var lastSeen: Date = Date()
    public var rssi: Int?              // BLE signal strength (dBm)
    public var distance: Float?        // Nearby Interaction distance (metres)
    public var direction: SIMD3<Float>? // Nearby Interaction direction vector

    public init(
        id: String,
        displayName: String,
        endpoint: PeerEndpoint,
        source: DiscoverySource,
        lastSeen: Date = Date(),
        rssi: Int? = nil,
        distance: Float? = nil,
        direction: SIMD3<Float>? = nil
    ) {
        self.id = id
        self.displayName = displayName
        self.endpoint = endpoint
        self.source = source
        self.lastSeen = lastSeen
        self.rssi = rssi
        self.distance = distance
        self.direction = direction
    }

    public static func == (lhs: DiscoveredPeer, rhs: DiscoveredPeer) -> Bool {
        lhs.id == rhs.id && lhs.displayName == rhs.displayName &&
        lhs.endpoint == rhs.endpoint && lhs.source == rhs.source &&
        lhs.lastSeen == rhs.lastSeen && lhs.rssi == rhs.rssi &&
        lhs.distance == rhs.distance
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(id)
        hasher.combine(displayName)
        hasher.combine(endpoint)
        hasher.combine(source)
        hasher.combine(rssi)
    }
}

public enum PeerEndpoint: Hashable {
    case bonjour(name: String, type: String, domain: String)
    case manual(host: String, port: UInt16)
    case bleOnly(peripheralIdentifier: String)
    case relay(roomCode: String)
}

public enum DiscoverySource: Hashable {
    case bonjour
    case manual
    case bluetooth
    case relay
}

/// Protocol for discovery backends.
public protocol DiscoveryBackend: AnyObject {
    var source: DiscoverySource { get }
    var peersPublisher: AnyPublisher<[DiscoveredPeer], Never> { get }
    func startDiscovery()
    func stopDiscovery()
}

/// Coordinator that merges peers from all discovery backends.
public final class DiscoveryCoordinator: ObservableObject {
    @Published public private(set) var peers: [DiscoveredPeer] = []

    private let backends: [DiscoveryBackend]
    private var cancellables = Set<AnyCancellable>()
    private var peersBySource: [DiscoverySource: [DiscoveredPeer]] = [:]

    public init(backends: [DiscoveryBackend]) {
        self.backends = backends
        mergeBackends()
    }

    public func start() {
        backends.forEach { $0.startDiscovery() }
    }

    public func stop() {
        backends.forEach { $0.stopDiscovery() }
    }

    public func addManualPeer(host: String, port: UInt16, name: String? = nil) {
        let peer = DiscoveredPeer(
            id: "\(host):\(port)",
            displayName: name ?? host,
            endpoint: .manual(host: host, port: port),
            source: .manual,
            lastSeen: Date()
        )
        if !peers.contains(where: { $0.id == peer.id }) {
            peers.append(peer)
        }
    }

    /// Remove a specific manual peer by ID.
    public func removeManualPeer(id: String) {
        peers.removeAll { $0.id == id && $0.source == .manual }
    }

    /// Remove manual peers that haven't been seen within the specified interval.
    /// - Parameter interval: Time interval in seconds (default: 24 hours).
    public func cleanupStalePeers(olderThan interval: TimeInterval = 86400) {
        let cutoff = Date().addingTimeInterval(-interval)
        peers.removeAll { peer in
            peer.source == .manual && peer.lastSeen < cutoff
        }
    }

    /// Update Nearby Interaction proximity data for a connected peer.
    public func updateProximity(peerDisplayName: String, distance: Float?, direction: SIMD3<Float>?) {
        if let idx = peers.firstIndex(where: { $0.displayName == peerDisplayName }) {
            peers[idx].distance = distance
            peers[idx].direction = direction
        }
    }

    private func mergeBackends() {
        for backend in backends {
            let backendSource = backend.source
            backend.peersPublisher
                .receive(on: DispatchQueue.main)
                .sink { [weak self] discoveredPeers in
                    guard let self else { return }
                    self.mergePeers(discoveredPeers, source: backendSource)
                }
                .store(in: &cancellables)
        }
    }

    private func mergePeers(_ newPeers: [DiscoveredPeer], source: DiscoverySource) {
        peersBySource[source] = newPeers

        // Keep manual peers
        var merged = peers.filter { $0.source == .manual }

        // Add Bonjour peers first
        if let bonjourPeers = peersBySource[.bonjour] {
            merged.append(contentsOf: bonjourPeers)
        }

        // Add BLE peers, merging RSSI into Bonjour peers with same name
        if let blePeers = peersBySource[.bluetooth] {
            for blePeer in blePeers {
                if let idx = merged.firstIndex(where: { $0.displayName == blePeer.displayName && $0.source == .bonjour }) {
                    // Peer already found via Bonjour — enrich with BLE RSSI
                    merged[idx].rssi = blePeer.rssi
                } else {
                    // BLE-only peer (not on same WiFi)
                    merged.append(blePeer)
                }
            }
        }

        peers = merged
    }
}
