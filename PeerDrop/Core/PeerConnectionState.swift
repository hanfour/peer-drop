import Foundation

/// Represents the connection state of a single peer connection.
enum PeerConnectionState: Equatable {
    case connecting
    case connected
    case disconnected
    case failed(reason: String)

    static func == (lhs: PeerConnectionState, rhs: PeerConnectionState) -> Bool {
        switch (lhs, rhs) {
        case (.connecting, .connecting),
             (.connected, .connected),
             (.disconnected, .disconnected):
            return true
        case (.failed(let a), .failed(let b)):
            return a == b
        default:
            return false
        }
    }

    var isActive: Bool {
        switch self {
        case .connecting, .connected:
            return true
        case .disconnected, .failed:
            return false
        }
    }

    var isConnected: Bool {
        if case .connected = self {
            return true
        }
        return false
    }
}
