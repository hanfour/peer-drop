import Foundation
import Combine

/// A discovered peer on the network.
struct DiscoveredPeer: Identifiable, Hashable {
    let id: String
    let displayName: String
    let endpoint: PeerEndpoint
    let source: DiscoverySource
}

enum PeerEndpoint: Hashable {
    case bonjour(name: String, type: String, domain: String)
    case manual(host: String, port: UInt16)
}

enum DiscoverySource: Hashable {
    case bonjour
    case manual
}

/// Protocol for discovery backends.
protocol DiscoveryBackend: AnyObject {
    var peersPublisher: AnyPublisher<[DiscoveredPeer], Never> { get }
    func startDiscovery()
    func stopDiscovery()
}

/// Coordinator that merges peers from all discovery backends.
final class DiscoveryCoordinator: ObservableObject {
    @Published private(set) var peers: [DiscoveredPeer] = []

    private let backends: [DiscoveryBackend]
    private var cancellables = Set<AnyCancellable>()

    init(backends: [DiscoveryBackend]) {
        self.backends = backends
        mergeBackends()
    }

    func start() {
        backends.forEach { $0.startDiscovery() }
    }

    func stop() {
        backends.forEach { $0.stopDiscovery() }
    }

    func addManualPeer(host: String, port: UInt16, name: String? = nil) {
        let peer = DiscoveredPeer(
            id: "\(host):\(port)",
            displayName: name ?? host,
            endpoint: .manual(host: host, port: port),
            source: .manual
        )
        if !peers.contains(where: { $0.id == peer.id }) {
            peers.append(peer)
        }
    }

    private func mergeBackends() {
        for backend in backends {
            backend.peersPublisher
                .receive(on: DispatchQueue.main)
                .sink { [weak self] discoveredPeers in
                    self?.mergePeers(discoveredPeers)
                }
                .store(in: &cancellables)
        }
    }

    private func mergePeers(_ newPeers: [DiscoveredPeer]) {
        var merged = peers.filter { $0.source == .manual }
        for peer in newPeers {
            if !merged.contains(where: { $0.id == peer.id }) {
                merged.append(peer)
            }
        }
        peers = merged
    }
}
