import Foundation
import Combine
@testable import PeerDrop

final class MockDiscovery: DiscoveryBackend {
    private let peersSubject = CurrentValueSubject<[DiscoveredPeer], Never>([])
    var peersPublisher: AnyPublisher<[DiscoveredPeer], Never> {
        peersSubject.eraseToAnyPublisher()
    }

    var isDiscovering = false

    func startDiscovery() {
        isDiscovering = true
    }

    func stopDiscovery() {
        isDiscovering = false
        peersSubject.send([])
    }

    func simulatePeerFound(_ peer: DiscoveredPeer) {
        var current = peersSubject.value
        current.append(peer)
        peersSubject.send(current)
    }

    func simulatePeerLost(id: String) {
        var current = peersSubject.value
        current.removeAll { $0.id == id }
        peersSubject.send(current)
    }

    static func makePeer(name: String = "Test Peer") -> DiscoveredPeer {
        DiscoveredPeer(
            id: UUID().uuidString,
            displayName: name,
            endpoint: .manual(host: "127.0.0.1", port: 9000),
            source: .manual
        )
    }
}
