import Foundation
import PeerDropProtocol
import Network

/// TCP transport wrapping NWConnection with optional TLS and message framing.
public final class TCPTransport: TransportProtocol {
    public let connection: NWConnection
    private let queue = DispatchQueue(label: "com.peerdrop.transport")

    public var onStateChange: ((TransportState) -> Void)?

    public init(connection: NWConnection) {
        self.connection = connection
    }

    public convenience init(endpoint: NWEndpoint, tlsOptions: NWProtocolTLS.Options? = nil) {
        let params = NWParameters.peerDrop(tls: tlsOptions)
        let connection = NWConnection(to: endpoint, using: params)
        self.init(connection: connection)
    }

    public var nwConnection: NWConnection { connection }

    public var isReady: Bool {
        connection.state == .ready
    }

    public func start() async throws {
        connection.start(queue: queue)
        try await connection.waitReady()
        onStateChange?(.ready)
    }

    public func send(_ message: PeerMessage) async throws {
        try await connection.sendMessage(message)
    }

    public func receive() async throws -> PeerMessage {
        try await connection.receiveMessage()
    }

    public func close() {
        connection.cancel()
        onStateChange?(.cancelled)
    }
}
