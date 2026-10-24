import Foundation
import PeerDropCore

/// How the shell reports a `.failed` connection state.
///
/// A connection that was already live and then drops is not an error the person has to act on: the
/// chat already says "下線了，上線後再聊" with a reconnect button, so the shell shows a quiet toast and
/// stays where it is. Only a failed *attempt* (the person asked to connect and it did not work) gets
/// the modal alert.
enum ConnectionErrorPolicy {
    enum Presentation: Equatable {
        case alert(String)
        case toast(String)
        case none
    }

    /// Message key shown (localized) when a live connection drops.
    static let droppedToastKey = "Connection lost"

    static func presentation(from old: ConnectionState, to new: ConnectionState, suppressAlert: Bool) -> Presentation {
        guard case .failed(let reason) = new else { return .none }
        if isLive(old) { return .toast(droppedToastKey) }
        return suppressAlert ? .none : .alert(reason)
    }

    private static func isLive(_ state: ConnectionState) -> Bool {
        switch state {
        case .connected, .transferring, .voiceCall: return true
        default: return false
        }
    }
}
