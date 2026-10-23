import Foundation

/// Whether a chat should present its peer as disconnected.
public enum ChatPeerPresence {
    /// - Parameters:
    ///   - connectionState: this peer's own connection state, or nil if
    ///     `ConnectionManager` has no connection for it. A dropped peer's
    ///     connection is *removed*, so nil is the normal post-disconnect case.
    ///   - globalState: the manager-wide state, used only to tell a dial in
    ///     progress apart from a lost connection.
    public static func isDisconnected(connectionState: PeerConnectionState?, globalState: ConnectionState) -> Bool {
        if let connectionState {
            switch connectionState {
            case .disconnected, .failed: return true
            case .connecting, .connected: return false
            }
        }
        switch globalState {
        case .connecting, .requesting, .incomingRequest: return false
        default: return true
        }
    }
}
