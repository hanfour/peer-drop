import Foundation
@testable import PeerDrop

final class MockTransport: TransportProtocol {
    var sentMessages: [PeerMessage] = []
    var messagesToReceive: [PeerMessage] = []
    var isClosed = false

    func send(_ message: PeerMessage) async throws {
        sentMessages.append(message)
    }

    func receive() async throws -> PeerMessage {
        guard !messagesToReceive.isEmpty else {
            throw MockTransportError.noMessages
        }
        return messagesToReceive.removeFirst()
    }

    func close() {
        isClosed = true
    }
}

enum MockTransportError: Error {
    case noMessages
}
