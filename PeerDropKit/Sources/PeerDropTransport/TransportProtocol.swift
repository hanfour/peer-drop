import Foundation
import PeerDropProtocol

/// Transport layer state.
public enum TransportState {
    case connecting
    case ready
    case failed(Error)
    case cancelled
}

/// Abstract transport layer for sending/receiving PeerMessages.
public protocol TransportProtocol: AnyObject {
    func send(_ message: PeerMessage) async throws
    func receive() async throws -> PeerMessage
    func close()
    var isReady: Bool { get }
    var onStateChange: ((TransportState) -> Void)? { get set }
}
