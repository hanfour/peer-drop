import SwiftUI
import PeerDropCore

/// Why an exchange ended badly, in user terms.
enum ExchangeFailure: Equatable {
    /// Our own notes account was not ready when both sides had agreed.
    case localAccountUnavailable
    /// The other side's answer could not be confirmed (any other reason).
    case couldNotConfirm
}

/// What the toolbar button shows. Pure, see `ExchangeButtonPresentation`.
enum ExchangeButtonState: Equatable {
    /// Nothing to offer (not secure / relay / tailnet / no support here).
    case hidden
    /// The other app is too old to support the exchange (explained on tap).
    case unavailableOldPeer
    case idle
    case waitingForPeer
    case peerWantsExchange
    /// Both sides agreed; the account is being checked.
    case verifying
    case bound
    /// The link was cancelled on this connection; the finished session cannot restart, so reconnect first.
    case needsReconnect
    case peerUnavailable
    case expired
    case failed(ExchangeFailure)
}

enum ExchangeButtonPresentation {
    /// - Parameters:
    ///   - ui: the exchange session state for this connection, if any.
    ///   - bindingState: the contact's stored binding: the source of truth for "bound".
    ///   - gateDenial: why the CM would refuse an exchange right now (nil = allowed).
    static func state(
        from ui: NotesExchangeSession.UIState?,
        peerSupportsExchange: Bool,
        bindingState: BindingState,
        gateDenial: NotesExchangeGate.Reason?,
        peerIsHeadless: Bool = false
    ) -> ExchangeButtonState {
        // Headless peers (CLI) have no notes UI and never advertise the flag: not "needs an update".
        if peerIsHeadless && bindingState == .none { return .hidden }
        if ui == .bound {
            switch bindingState {
            case .verified: return .bound
            case .pending: return .verifying
            case .none: return .needsReconnect
            }
        }
        if let denial = gateDenial {
            // Without a usable direct connection nothing can be started, but an existing binding
            // (or a claim still being checked) stays visible so it can be reviewed or cancelled.
            switch bindingState {
            case .verified: return .bound
            case .pending: return .verifying
            case .none: return denial == .peerLacksSupport ? .unavailableOldPeer : .hidden
            }
        }
        if !peerSupportsExchange {
            return bindingState == .verified ? .bound : .unavailableOldPeer
        }
        guard let ui else { return fallback(bindingState) }
        switch ui {
        case .idle: return fallback(bindingState)
        case .waitingForPeer: return .waitingForPeer
        case .peerWantsExchange: return .peerWantsExchange
        case .exchanging, .verifying: return .verifying
        case .bound: return .bound   // unreachable: handled above
        case .peerUnavailable: return .peerUnavailable
        case .expired: return .expired
        case .failed(let reason):
            // A verified binding is the truth: a failed re-exchange must not hide it.
            if bindingState == .verified { return .bound }
            return .failed(reason == .localAccountUnavailable ? .localAccountUnavailable : .couldNotConfirm)
        }
    }

    private static func fallback(_ binding: BindingState) -> ExchangeButtonState {
        switch binding {
        case .verified: return .bound
        case .pending: return .verifying
        case .none: return .idle
        }
    }
}

extension ExchangeButtonState {
    enum Action: Equatable {
        case noAction
        /// Explanation only (alert on iOS).
        case showInfo
        /// Start: "if X also agrees".
        case confirmShare
        /// The peer already asked: agree or decline.
        case confirmAgree
        case confirmWithdraw
        case confirmUnbind
    }

    var isVisible: Bool { self != .hidden }

    /// What a tap does.
    var action: Action {
        switch self {
        case .idle, .expired: return .confirmShare
        case .peerWantsExchange: return .confirmAgree
        case .waitingForPeer: return .confirmWithdraw
        case .bound: return .confirmUnbind
        case .unavailableOldPeer, .verifying, .peerUnavailable, .needsReconnect, .failed: return .showInfo
        case .hidden: return .noAction
        }
    }

    var isEnabled: Bool { action != .noAction }

    var symbol: String {
        switch self {
        case .hidden: return "envelope"
        case .unavailableOldPeer: return "arrow.down.app"
        case .idle: return "envelope.badge"
        case .peerWantsExchange: return "envelope.badge.fill"
        case .waitingForPeer: return "clock"
        case .verifying: return "ellipsis.circle"
        case .bound: return "envelope.circle.fill"
        case .needsReconnect: return "envelope.arrow.triangle.branch"
        case .peerUnavailable: return "person.crop.circle.badge.questionmark"
        case .expired: return "clock.arrow.circlepath"
        case .failed: return "exclamationmark.triangle"
        }
    }

    /// VoiceOver label, tooltip and (for informational states) the alert text.
    /// Never claims the other person's identity is verified.
    func label(peerName: String) -> String {
        switch self {
        case .hidden: return ""
        case .unavailableOldPeer: return String(localized: "The other app needs an update to exchange notes")
        case .idle: return String(localized: "Exchange notes")
        case .waitingForPeer: return String(localized: "Waiting for the other person to agree. Tap to withdraw.")
        case .peerWantsExchange: return String(format: String(localized: "%@ wants to exchange notes. Tap to agree."), peerName)
        case .verifying: return String(localized: "Checking the notes account")
        case .bound: return String(localized: "Notes exchanged. Tap to cancel.")
        case .needsReconnect: return String(localized: "The notes link was cancelled. Reconnect with them to exchange notes again.")
        // The peer's "unavailable" cannot tell "no account" from a failed reveal, so the copy stays neutral.
        case .peerUnavailable: return String(localized: "The other person didn't continue the exchange")
        case .expired: return String(localized: "The request expired. Tap to try again.")
        case .failed(.localAccountUnavailable): return String(localized: "Your notes account isn't ready yet. Reconnect with them later to try again.")
        case .failed(.couldNotConfirm): return String(localized: "Couldn't exchange notes. Reconnect with them to try again.")
        }
    }

    /// Alert text for `.showInfo` states (same copy as the label).
    func infoMessage(peerName: String) -> String? {
        action == .showInfo ? label(peerName: peerName) : nil
    }

    /// Toast posted when the state changes into a final result.
    func transitionToast(peerName: String) -> String? {
        switch self {
        case .bound: return String(format: String(localized: "Notes exchanged with %@."), peerName)
        case .peerUnavailable, .failed: return label(peerName: peerName)
        default: return nil
        }
    }
}

/// Toolbar button of a friend chat (iOS and the Mac chat window).
struct ExchangeNotesButton: View, PaperThemed {
    @Environment(\.paperMode) var paperMode
    @EnvironmentObject var connectionManager: ConnectionManager
    let peerID: String
    let peerName: String
    let bindingState: BindingState
    let contactID: UUID?

    @State private var dialog: ExchangeButtonState.Action?
    @State private var infoText: String?

    private var connectionKey: String { connectionManager.connection(for: peerID)?.id ?? peerID }

    private var state: ExchangeButtonState {
        let pc = connectionManager.connection(for: peerID)
        var denial: NotesExchangeGate.Reason?
        if case .denied(let reason) = connectionManager.notesExchangeAvailability(with: peerID) { denial = reason }
        return ExchangeButtonPresentation.state(
            from: connectionManager.notesExchangeStates[connectionKey],
            peerSupportsExchange: pc?.peerIdentity.supportsNotesExchange ?? false,
            bindingState: bindingState,
            gateDenial: denial,
            peerIsHeadless: pc?.peerIdentity.isHeadless ?? false)
    }

    var body: some View {
        let current = state
        if current.isVisible {
            Button {
                if current.action == .showInfo {
                    infoText = current.infoMessage(peerName: peerName)
                } else {
                    dialog = current.action
                }
            } label: {
                if current == .verifying {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: current.symbol)
                        .foregroundStyle(iconColor(current))
                }
            }
            .help(current.label(peerName: peerName))
            .accessibilityLabel(Text(verbatim: current.label(peerName: peerName)))
            .onChange(of: current) { newState in
                if let toast = newState.transitionToast(peerName: peerName) { connectionManager.statusToast = toast }
            }
            .alert(Text("Notes"), isPresented: Binding(get: { infoText != nil }, set: { if !$0 { infoText = nil } })) {
                Button("OK") { infoText = nil }
            } message: {
                Text(verbatim: infoText ?? "")
            }
            .confirmationDialog(title(for: dialog), isPresented: Binding(get: { dialog != nil }, set: { if !$0 { dialog = nil } }), titleVisibility: .visible) {
                confirmButtons
            } message: {
                Text(verbatim: message(for: dialog))
            }
        }
    }

    private func iconColor(_ s: ExchangeButtonState) -> Color {
        switch s {
        case .bound: return paper(.noteBadge)
        case .peerWantsExchange: return paper(.noteBorder)
        default: return Color.accentColor
        }
    }

    @ViewBuilder
    private var confirmButtons: some View {
        switch dialog {
        case .confirmShare, .confirmAgree:
            Button("Share notes account") { press() }
            if dialog == .confirmAgree {
                Button("Decline", role: .destructive) { connectionManager.cancelExchangeNotes(with: peerID) }
            }
        case .confirmWithdraw:
            Button("Withdraw", role: .destructive) { connectionManager.cancelExchangeNotes(with: peerID) }
        case .confirmUnbind:
            Button("Cancel notes link", role: .destructive) {
                if let contactID { connectionManager.unbindNotes(contactID: contactID) }
            }
        default:
            EmptyView()
        }
        Button("Not now", role: .cancel) {}
    }

    private func title(for action: ExchangeButtonState.Action?) -> String {
        switch action {
        case .confirmShare, .confirmAgree: return String(localized: "Exchange notes?")
        case .confirmWithdraw: return String(localized: "Withdraw your request?")
        case .confirmUnbind: return String(localized: "Cancel the notes link?")
        default: return ""
        }
    }

    private func message(for action: ExchangeButtonState.Action?) -> String {
        switch action {
        case .confirmShare:
            return String(format: String(localized: "If %@ also agrees, your notes account will be shared with them."), peerName)
        case .confirmAgree:
            return String(format: String(localized: "%@ wants to exchange notes. Share your notes account with them?"), peerName)
        case .confirmWithdraw:
            return String(localized: "Nothing has been shared.")
        case .confirmUnbind:
            return String(format: String(localized: "You won't be able to send notes to %@ from this chat until you exchange again."), peerName)
        default:
            return ""
        }
    }

    private func press() {
        if case .denied = connectionManager.pressExchangeNotes(with: peerID) {
            connectionManager.statusToast = String(localized: "Notes can only be exchanged over a direct, secure connection.")
        }
    }
}
