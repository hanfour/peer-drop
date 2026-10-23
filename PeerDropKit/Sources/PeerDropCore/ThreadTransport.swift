import Foundation

/// How a friend's account binding stands, from the thread's point of view.
public enum BindingState: Equatable {
    case none
    case pending
    case verified
}

/// Whether our own notes account can send right now.
public enum AccountAvailability: Equatable {
    case ready
    case notReady
}

public enum LockReason: Equatable {
    /// Never exchanged accounts: only live chat is possible.
    case notExchanged
    /// An exchange happened but the directory has not verified it yet.
    case verifying
}

/// What the thread's composer may do (plan Task 5 table). Pure.
public enum ThreadTransport {
    public enum Decision: Equatable {
        /// Peer is connected: send as live chat. `showExchangeButton` is true
        /// while the binding is not yet verified, so the UI can offer the
        /// notes-account exchange. It is derived from the binding alone; the
        /// UI additionally hides the button when the peer does not support
        /// the exchange (a capability the UI already knows, kept out of this
        /// pure table so the table stays exactly `presence x binding x account`).
        case live(showExchangeButton: Bool)
        /// Peer not online, verified binding: send as a note. `canSendNow`
        /// is false when our own account is not ready (queue instead).
        case note(canSendNow: Bool)
        case locked(reason: LockReason)
    }

    public static func decide(presence: PeerPresence, binding: BindingState, account: AccountAvailability) -> Decision {
        if presence == .online { return .live(showExchangeButton: binding != .verified) }
        switch binding {
        case .verified: return .note(canSendNow: account == .ready)
        case .pending: return .locked(reason: .verifying)
        case .none: return .locked(reason: .notExchanged)
        }
    }
}
