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
    /// The other app is too old to support the exchange (disabled, explained).
    case unavailableOldPeer
    case idle
    case waitingForPeer
    case peerWantsExchange
    /// Both sides agreed; the account is being checked.
    case verifying
    case bound
    case peerUnavailable
    case expired
    case failed(ExchangeFailure)
}

enum ExchangeButtonPresentation {
    /// - Parameters:
    ///   - ui: the exchange session state for this connection, if any.
    ///   - gateDenial: why the CM would refuse an exchange right now (nil = allowed).
    static func state(
        from ui: NotesExchangeSession.UIState?,
        peerSupportsExchange: Bool,
        bindingState: BindingState,
        gateDenial: NotesExchangeGate.Reason?
    ) -> ExchangeButtonState {
        if ui == .bound { return .bound }
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
        case .bound: return .bound
        case .peerUnavailable: return .peerUnavailable
        case .expired: return .expired
        case .failed(let reason):
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
    enum Action: Equatable { case noAction, confirmShare, confirmWithdraw, confirmUnbind }

    var isVisible: Bool { self != .hidden }

    /// What a tap does. `.noAction` = informational only (disabled).
    var action: Action {
        switch self {
        case .idle, .peerWantsExchange, .expired: return .confirmShare
        case .waitingForPeer: return .confirmWithdraw
        case .bound: return .confirmUnbind
        case .hidden, .unavailableOldPeer, .verifying, .peerUnavailable, .failed: return .noAction
        }
    }

    var isEnabled: Bool { action != .noAction }

    var symbol: String {
        switch self {
        case .hidden: return "envelope"
        case .unavailableOldPeer: return "arrow.down.app"
        case .idle, .peerWantsExchange: return "envelope.badge"
        case .waitingForPeer: return "clock"
        case .verifying: return "ellipsis.circle"
        case .bound: return "envelope.circle.fill"
        case .peerUnavailable: return "envelope.badge.fill"
        case .expired: return "clock.arrow.circlepath"
        case .failed: return "exclamationmark.triangle"
        }
    }

    /// VoiceOver label and tooltip. Never claims the other person's identity is verified.
    func label(peerName: String) -> String {
        switch self {
        case .hidden: return ""
        case .unavailableOldPeer: return String(localized: "The other app needs an update to exchange notes")
        case .idle: return String(localized: "Exchange notes")
        case .waitingForPeer: return String(localized: "Waiting for the other person to agree. Tap to withdraw.")
        case .peerWantsExchange: return String(format: String(localized: "%@ wants to exchange notes. Tap to agree."), peerName)
        case .verifying: return String(localized: "Checking the notes account")
        case .bound: return String(localized: "Notes exchanged. Tap to cancel.")
        case .peerUnavailable: return String(localized: "The other person hasn't set up notes yet")
        case .expired: return String(localized: "The request expired. Tap to try again.")
        case .failed(.localAccountUnavailable): return String(localized: "Your notes account isn't ready yet. Try again in a moment.")
        case .failed(.couldNotConfirm): return String(localized: "Couldn't exchange notes. Try again.")
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

    private var connectionKey: String { connectionManager.connection(for: peerID)?.id ?? peerID }

    private var state: ExchangeButtonState {
        let pc = connectionManager.connection(for: peerID)
        var denial: NotesExchangeGate.Reason?
        if case .denied(let reason) = connectionManager.notesExchangeAvailability(with: peerID) { denial = reason }
        return ExchangeButtonPresentation.state(
            from: connectionManager.notesExchangeStates[connectionKey],
            peerSupportsExchange: pc?.peerIdentity.supportsNotesExchange ?? false,
            bindingState: bindingState,
            gateDenial: denial)
    }

    var body: some View {
        let current = state
        if current.isVisible {
            Button {
                dialog = current.action
            } label: {
                if current == .verifying {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: current.symbol)
                        .foregroundStyle(current == .bound ? paper(.noteBadge) : Color.accentColor)
                }
            }
            .disabled(!current.isEnabled)
            .help(current.label(peerName: peerName))
            .accessibilityLabel(Text(verbatim: current.label(peerName: peerName)))
            .confirmationDialog(title(for: dialog), isPresented: Binding(get: { dialog != nil && dialog != .some(.noAction) }, set: { if !$0 { dialog = nil } }), titleVisibility: .visible) {
                confirmButtons
            } message: {
                Text(verbatim: message(for: dialog))
            }
        }
    }

    @ViewBuilder
    private var confirmButtons: some View {
        switch dialog {
        case .confirmShare:
            Button("Share notes account") { press() }
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
        case .confirmShare: return String(localized: "Exchange notes?")
        case .confirmWithdraw: return String(localized: "Withdraw your request?")
        case .confirmUnbind: return String(localized: "Cancel the notes link?")
        default: return ""
        }
    }

    private func message(for action: ExchangeButtonState.Action?) -> String {
        switch action {
        case .confirmShare:
            return String(format: String(localized: "If %@ also agrees, your notes account will be shared with them."), peerName)
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
