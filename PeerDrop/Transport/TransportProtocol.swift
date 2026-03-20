import Foundation

/// Transport layer state.
enum TransportState {
    case connecting
    case ready
    case failed(Error)
    case cancelled
}

/// Abstract transport layer for sending/receiving PeerMessages.
protocol TransportProtocol: AnyObject {
    func send(_ message: PeerMessage) async throws
    func receive() async throws -> PeerMessage
    func close()
    var isReady: Bool { get }
    var onStateChange: ((TransportState) -> Void)? { get set }
}
