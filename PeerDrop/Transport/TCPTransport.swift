import Foundation
import Network

/// TCP transport wrapping NWConnection with optional TLS and message framing.
final class TCPTransport: TransportProtocol {
    private let connection: NWConnection
    private let queue = DispatchQueue(label: "com.peerdrop.transport")

    init(connection: NWConnection) {
        self.connection = connection
    }

    convenience init(endpoint: NWEndpoint, tlsOptions: NWProtocolTLS.Options? = nil) {
        let params = NWParameters.peerDrop(tls: tlsOptions)
        let connection = NWConnection(to: endpoint, using: params)
        self.init(connection: connection)
    }

    var nwConnection: NWConnection { connection }

    func start() async throws {
        connection.start(queue: queue)
        try await connection.waitReady()
    }

    func send(_ message: PeerMessage) async throws {
        try await connection.sendMessage(message)
    }

    func receive() async throws -> PeerMessage {
        try await connection.receiveMessage()
    }

    func close() {
        connection.cancel()
    }
}
