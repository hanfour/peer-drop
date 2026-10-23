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
        /// Peer is connected: send as live chat. The exchange button is owned
        /// by the UI (UI state + peer capability + binding state), not by this table.
        case live
        /// Peer not online, verified binding: send as a note. `canSendNow`
        /// is false when our own account is not ready (queue instead).
        case note(canSendNow: Bool)
        case locked(reason: LockReason)
    }

    public static func decide(presence: PeerPresence, binding: BindingState, account: AccountAvailability) -> Decision {
        if presence == .online { return .live }
        switch binding {
        case .verified: return .note(canSendNow: account == .ready)
        case .pending: return .locked(reason: .verifying)
        case .none: return .locked(reason: .notExchanged)
        }
    }
}
