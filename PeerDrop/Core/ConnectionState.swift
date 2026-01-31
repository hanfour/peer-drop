import Foundation

enum ConnectionState: Equatable {
    case idle
    case discovering
    case peerFound
    case requesting
    case incomingRequest
    case connecting
    case connected
    case transferring(progress: Double)
    case voiceCall
    case disconnected
    case rejected
    case failed(reason: String)

    static func == (lhs: ConnectionState, rhs: ConnectionState) -> Bool {
        switch (lhs, rhs) {
        case (.idle, .idle),
             (.discovering, .discovering),
             (.peerFound, .peerFound),
             (.requesting, .requesting),
             (.incomingRequest, .incomingRequest),
             (.connecting, .connecting),
             (.connected, .connected),
             (.voiceCall, .voiceCall),
             (.disconnected, .disconnected),
             (.rejected, .rejected):
            return true
        case (.transferring(let a), .transferring(let b)):
            return a == b
        case (.failed(let a), .failed(let b)):
            return a == b
        default:
            return false
        }
    }

    /// Valid transitions from this state.
    var validTransitions: Set<TransitionTarget> {
        switch self {
        case .idle:
            return [.discovering]
        case .discovering:
            return [.peerFound, .idle, .incomingRequest]
        case .peerFound:
            return [.requesting, .discovering, .incomingRequest]
        case .requesting:
            return [.connecting, .rejected, .failed, .disconnected]
        case .incomingRequest:
            return [.connecting, .rejected, .disconnected]
        case .connecting:
            return [.connected, .failed, .disconnected]
        case .connected:
            return [.transferring, .voiceCall, .disconnected, .failed]
        case .transferring:
            return [.connected, .failed, .disconnected]
        case .voiceCall:
            return [.connected, .disconnected, .failed]
        case .disconnected, .rejected, .failed:
            return [.idle, .discovering]
        }
    }

    func canTransition(to target: TransitionTarget) -> Bool {
        validTransitions.contains(target)
    }
}

/// Simplified targets for transition validation (ignores associated values).
enum TransitionTarget: Hashable {
    case idle, discovering, peerFound, requesting, incomingRequest
    case connecting, connected, transferring, voiceCall
    case disconnected, rejected, failed

    init(from state: ConnectionState) {
        switch state {
        case .idle: self = .idle
        case .discovering: self = .discovering
        case .peerFound: self = .peerFound
        case .requesting: self = .requesting
        case .incomingRequest: self = .incomingRequest
        case .connecting: self = .connecting
        case .connected: self = .connected
        case .transferring: self = .transferring
        case .voiceCall: self = .voiceCall
        case .disconnected: self = .disconnected
        case .rejected: self = .rejected
        case .failed: self = .failed
        }
    }
}
