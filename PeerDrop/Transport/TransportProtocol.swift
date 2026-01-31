import Foundation

/// Abstract transport layer for sending/receiving PeerMessages.
protocol TransportProtocol: AnyObject {
    func send(_ message: PeerMessage) async throws
    func receive() async throws -> PeerMessage
    func close()
}
