import SwiftUI
import PeerDropCore
import PeerDropSecurity

// Project E, Task 6: the per-friend "always connected" toggle, its explainer, and the pure logic behind them.
//
// Product rules this file must keep (spec §4.3, §12.4, §12.6):
//  - Nothing here ever says or implies what the OTHER side did. "Nobody there yet", "they turned it off"
//    and "the connection was refused" all look the same: a waiting state.
//  - Turning it off is a quiet downgrade. The only text about it is about the user's own side.

/// Pure presentation logic. Views stay thin and only render what this returns.
enum AlwaysConnectedPresentation {

    /// How far a turned-on friend has got. `waiting` covers "not in the room yet" and "unreachable" alike.
    enum Link: Equatable { case waiting, connecting, online }

    enum State: Equatable {
        /// Not bound to a notes account (or a re-exchange is pending): guide to the notes exchange.
        case unavailableNotBound
        case off
        case on(Link)
        /// Off, and 5 other friends already use it.
        case limitReached
        /// The flag is on but the friend is not eligible right now (e.g. a re-exchange is pending): the only
        /// thing the toggle can do is turn it off, so a slot can never be stuck.
        case disableOnly
    }

    /// Result of trying to flip the toggle.
    enum Outcome: Equatable { case applied, limitReached, unavailable, unknownContact }

    /// What the chat's info button opens.
    enum InfoDestination: Equatable { case connectionView, alwaysConnectedSheet }

    static let limit = TrustedContactStore.maxRendezvousContacts

    // MARK: - State

    /// `eligible` is the store's own verdict (`TrustedContactStore.isRendezvousEligible`) when the caller has the
    /// whole contact list; otherwise the same binding rule applies on the single contact.
    static func state(contact: TrustedContact, enabledCount: Int, rendezvousState: RendezvousLinkState,
                      eligible: Bool? = nil) -> State {
        let isEligible = eligible ?? (contact.accountId != nil && contact.pendingAccountBinding == nil && !contact.isBlocked)
        guard isEligible else { return contact.isRendezvousEnabled ? .disableOnly : .unavailableNotBound }
        if contact.isRendezvousEnabled {
            switch rendezvousState {
            case .connected: return .on(.online)
            case .connecting: return .on(.connecting)
            // `unreachable` and `inactive` are deliberately the same: peer-off and refused look alike.
            case .inactive, .unreachable: return .on(.waiting)
            }
        }
        return enabledCount >= limit ? .limitReached : .off
    }

    static func isToggleInteractive(_ s: State) -> Bool {
        switch s {
        case .off, .on, .disableOnly: return true
        case .unavailableNotBound, .limitReached: return false
        }
    }

    static func toggleIsOn(_ s: State) -> Bool {
        switch s {
        case .on, .disableOnly: return true
        default: return false
        }
    }

    static func enabledCount(in store: TrustedContactStore) -> Int {
        store.contacts.filter { $0.isRendezvousEnabled }.count
    }

    // MARK: - Acting on the toggle

    /// Flips the opt-in. Turning ON goes through the store's typed errors (never a silent no-op); turning OFF
    /// is a quiet downgrade: store flag cleared, then any suspension lifted so a later re-enable starts clean.
    @MainActor
    static func apply(enabled: Bool, contactID: UUID, store: TrustedContactStore,
                      clearSuspension: (UUID) -> Void, contactsDidChange: () -> Void) -> Outcome {
        do {
            try store.setRendezvousEnabled(for: contactID, enabled)
            // The store's publisher fires before the new value is readable, so tell the manager explicitly:
            // joining / leaving the room happens now, not at the next tick.
            contactsDidChange()
            if !enabled { clearSuspension(contactID) }
            return .applied
        } catch RendezvousOptInError.limitExceeded {
            return .limitReached
        } catch RendezvousOptInError.notBound {
            return .unavailable
        } catch {
            return .unknownContact
        }
    }

    static func messageKey(for outcome: Outcome) -> String? {
        switch outcome {
        case .limitReached: return limitReachedKey
        case .unavailable: return unavailableKey
        case .unknownContact: return unavailableKey
        case .applied: return nil
        }
    }

    // MARK: - File / call / info

    /// Cross-network connections carry chat frames only in v1.
    static func offersFileTransferAndCalls(isRendezvousConnection: Bool) -> Bool { !isRendezvousConnection }

    /// A cross-network friend has no manual "disconnect" (it would just reconnect), so the info button explains
    /// the status and offers the toggle instead of opening an empty connection screen.
    static func infoDestination(isRendezvousConnection: Bool) -> InfoDestination {
        isRendezvousConnection ? .alwaysConnectedSheet : .connectionView
    }

    /// The neutral "key may have changed" item: local diagnostics only, and only for the AUTHENTICATED
    /// contradiction (`helloMismatch`). `keyMismatch` / unauthenticated HELLO can be caused by anyone on the
    /// path, so they show nothing.
    static func showsKeyChangedItem(reason: RendezvousConnectionFailure?) -> Bool {
        reason == .helloMismatch
    }

    /// Chat toolbar button: whenever the thread has a verified binding, whatever the presence is.
    static func showsChatButton(bindingIsVerified: Bool) -> Bool { bindingIsVerified }

    /// A live non-cross-network connection to the friend exists.
    static func isDirectConnection(live: Bool, isRendezvous: Bool) -> Bool { live && !isRendezvous }

    // MARK: - Strings (English source text is the catalog key)

    static let titleKey = "Always connected"
    static let explanationKey = "The green dot shows only when your friend has also turned this on and is online."
    static let unavailableKey = "Always connected works with friends you have exchanged notes with. Exchange notes with this friend first."
    static let limitReachedKey = "You can keep up to 5 friends always connected. Turn one off to add another."
    static let chatOnlyKey = "For now, always connected carries chat only. Files and calls need a nearby connection."
    static let keyChangedKey = "This friend's key may have changed. Please re-pair in person."
    static let turnOffTitleKey = "Turn off always connected?"
    static let turnOffMessageKey = "After you turn it off, you will show as offline to them."
    static let turnOffButtonKey = "Turn Off"
    static let explainerTitleKey = "How always connected works"

    static let statusWaitingKey = "Not connected right now"
    static let statusConnectingKey = "Connecting right now"
    static let statusOnlineKey = "Connected across networks"

    /// Visible status line of a turned-on friend; nil when there is nothing to report.
    /// A friend connected nearby/direct is connected: the "not connected" line would be false, so it is hidden.
    static func statusKey(_ s: State, directlyConnected: Bool = false) -> String? {
        if directlyConnected, case .on(let l) = s, l != .online { return nil }
        switch s {
        case .on(.waiting): return statusWaitingKey
        case .on(.connecting): return statusConnectingKey
        case .on(.online): return statusOnlineKey
        case .off, .unavailableNotBound, .limitReached, .disableOnly: return nil
        }
    }

    /// SF Symbol for the status line, so the state is never colour-only.
    static func statusSymbol(_ s: State, directlyConnected: Bool = false) -> String? {
        if directlyConnected, case .on(let l) = s, l != .online { return nil }
        switch s {
        case .on(.waiting): return "clock"
        case .on(.connecting): return "arrow.triangle.2.circlepath"
        case .on(.online): return "checkmark.circle.fill"
        case .off, .unavailableNotBound, .limitReached, .disableOnly: return nil
        }
    }

    /// Footnote paragraphs under the toggle, in order. Never empty.
    static func footnoteKeys(_ s: State) -> [String] {
        switch s {
        case .unavailableNotBound, .disableOnly: return [unavailableKey]
        case .off: return [explanationKey, chatOnlyKey]
        case .limitReached: return [limitReachedKey, explanationKey, chatOnlyKey]
        case .on(.waiting), .on(.connecting): return [explanationKey, chatOnlyKey]
        case .on(.online): return [chatOnlyKey]
        }
    }

    static func voiceOverKey(_ s: State, directlyConnected: Bool = false) -> String {
        if directlyConnected, case .on(let l) = s, l != .online { return voiceOverKey(.off) }
        switch s {
        case .disableOnly: return "Always connected. Not available right now. You can turn it off."
        case .unavailableNotBound: return "Always connected. Not available yet. Exchange notes with this friend first."
        case .off: return "Always connected for this friend."
        case .limitReached: return "Always connected. The limit of 5 friends is reached."
        case .on(.waiting): return "Always connected. Not connected right now."
        case .on(.connecting): return "Always connected. Connecting right now."
        case .on(.online): return "Always connected. Connected across networks."
        }
    }

    static func localized(_ key: String) -> String { String(localized: String.LocalizationValue(key)) }

    static func voiceOverText(_ s: State, directlyConnected: Bool = false) -> String {
        localized(voiceOverKey(s, directlyConnected: directlyConnected))
    }

    // MARK: - Explainer

    struct ExplainerSection: Equatable {
        let headerKey: String
        let bodyKeys: [String]
    }

    static let explainerSections: [ExplainerSection] = [
        ExplainerSection(headerKey: "Three ways to connect", bodyKeys: [
            "Strangers send a one-way note. They can leave you a note, and that is all.",
            "Nearby friends chat live while you share a network. Leave the network and it ends.",
            "Always connected is for friends you pick one by one. It works across networks, and only once you have both turned it on.",
        ]),
        ExplainerSection(headerKey: "Good to know", bodyKeys: [
            "You can keep up to 5 friends always connected at a time.",
            "Turning it off is quiet. Nothing is announced to your friend; you simply stop showing as online to them.",
            "When the app is not open, you fall back to notes.",
            chatOnlyKey,
        ]),
        ExplainerSection(headerKey: "What we can see", bodyKeys: [
            "We don't store who your friends are, and chats are end-to-end encrypted. But we (or anyone who can watch our servers' live traffic, such as Cloudflare) could notice that two devices join at the same moment and infer that they are in touch.",
        ]),
    ]

    /// Every localized key this feature adds (the test scans them in all five languages).
    static var allLocalizedKeys: [String] {
        var keys: [String] = [titleKey, explanationKey, unavailableKey, limitReachedKey, chatOnlyKey, keyChangedKey,
                              turnOffTitleKey, turnOffMessageKey, turnOffButtonKey, explainerTitleKey,
                              statusWaitingKey, statusConnectingKey, statusOnlineKey]
        let states: [State] = [.unavailableNotBound, .off, .on(.waiting), .on(.connecting), .on(.online), .limitReached, .disableOnly]
        keys += states.map { voiceOverKey($0) }
        for section in explainerSections { keys.append(section.headerKey); keys += section.bodyKeys }
        var seen = Set<String>()
        return keys.filter { seen.insert($0).inserted }
    }
}

// MARK: - Toggle section

/// The toggle, its status line and its footnotes, as Form content. Host it inside a `Form` / `List`.
struct AlwaysConnectedToggleSection: View {
    typealias P = AlwaysConnectedPresentation

    @ObservedObject var store: TrustedContactStore
    @EnvironmentObject var connectionManager: ConnectionManager
    /// The chat key / device id the friend is known by.
    let peerID: String

    @State private var confirmOff = false
    @State private var failureKey: String?

    /// Live non-cross-network connection to this friend (nearby / direct).
    private var directlyConnected: Bool {
        let pc = connectionManager.connection(for: peerID)
        return P.isDirectConnection(live: pc != nil, isRendezvous: pc?.isRendezvousConnection == true)
    }

    private var contact: TrustedContact? {
        FriendBinding(connectionManager: connectionManager).contact(forChatPeerID: peerID)
    }

    private var state: P.State {
        guard let contact else { return .unavailableNotBound }
        let eligible = TrustedContactStore.isRendezvousEligible(contact, among: store.contacts)
        let link = connectionManager.rendezvousManager?.linkState(for: contact.id) ?? .inactive
        return P.state(contact: contact, enabledCount: P.enabledCount(in: store), rendezvousState: link, eligible: eligible)
    }

    var body: some View {
        let s = state
        Section {
            Toggle(isOn: Binding(
                get: { P.toggleIsOn(s) },
                set: { wantsOn in
                    if wantsOn { turnOn() } else { confirmOff = true }
                })) {
                Text(LocalizedStringKey(P.titleKey))
            }
            .disabled(!P.isToggleInteractive(s))
            .accessibilityLabel(Text(verbatim: P.voiceOverText(s, directlyConnected: directlyConnected)))
            .accessibilityIdentifier("always-connected-toggle")

            if let key = P.statusKey(s, directlyConnected: directlyConnected), let symbol = P.statusSymbol(s, directlyConnected: directlyConnected) {
                Label {
                    Text(LocalizedStringKey(key)).fixedSize(horizontal: false, vertical: true)
                } icon: {
                    Image(systemName: symbol)
                }
                .font(.subheadline)
                .accessibilityHidden(true) // already part of the toggle's spoken label
            }
        } footer: {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(P.footnoteKeys(s), id: \.self) { key in
                    Text(LocalizedStringKey(key)).fixedSize(horizontal: false, vertical: true)
                }
                if let failureKey, !P.footnoteKeys(s).contains(failureKey) {
                    Text(LocalizedStringKey(failureKey)).fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .onChange(of: s) { _ in failureKey = nil }
        .confirmationDialog(Text(LocalizedStringKey(P.turnOffTitleKey)), isPresented: $confirmOff, titleVisibility: .visible) {
            Button(role: .destructive) { turnOff() } label: { Text(LocalizedStringKey(P.turnOffButtonKey)) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(LocalizedStringKey(P.turnOffMessageKey))
        }

        if let contact, P.showsKeyChangedItem(reason: connectionManager.rendezvousManager?.lastFailureReason(for: contact.id)) {
            Section {
                Label {
                    Text(LocalizedStringKey(P.keyChangedKey)).fixedSize(horizontal: false, vertical: true)
                } icon: {
                    Image(systemName: "key")
                }
            }
        }
    }

    private func turnOn() {
        guard let contact else { return }
        let outcome = P.apply(enabled: true, contactID: contact.id, store: store,
                              clearSuspension: { connectionManager.rendezvousManager?.clearSuspension(contactID: $0) },
                              contactsDidChange: { connectionManager.rendezvousManager?.contactsDidChange() })
        failureKey = P.messageKey(for: outcome)
    }

    private func turnOff() {
        guard let contact else { return }
        _ = P.apply(enabled: false, contactID: contact.id, store: store,
                    clearSuspension: { connectionManager.rendezvousManager?.clearSuspension(contactID: $0) },
                    contactsDidChange: { connectionManager.rendezvousManager?.contactsDidChange() })
        failureKey = nil
    }
}

// MARK: - Per-friend sheet

/// Opened from a friend row or from the chat's info button: the toggle plus a link to the explainer.
struct AlwaysConnectedFriendSheet: View {
    @EnvironmentObject var connectionManager: ConnectionManager
    @Environment(\.dismiss) private var dismiss
    let peerID: String
    let name: String

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text(verbatim: name).font(.headline).accessibilityAddTraits(.isHeader)
                }
                AlwaysConnectedToggleSection(store: connectionManager.trustedContactStore, peerID: peerID)
                Section {
                    NavigationLink {
                        AlwaysConnectedExplainerView()
                    } label: {
                        Text(LocalizedStringKey(AlwaysConnectedPresentation.explainerTitleKey))
                    }
                }
            }
            .navigationTitle(Text(LocalizedStringKey(AlwaysConnectedPresentation.titleKey)))
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
        #if os(macOS)
        .frame(minWidth: 380, minHeight: 420)
        #endif
    }
}

// MARK: - Explainer

/// Plain-language explainer (Settings -> "How always connected works").
struct AlwaysConnectedExplainerView: View {
    var body: some View {
        Form {
            ForEach(AlwaysConnectedPresentation.explainerSections, id: \.headerKey) { section in
                Section {
                    ForEach(section.bodyKeys, id: \.self) { key in
                        Text(LocalizedStringKey(key)).fixedSize(horizontal: false, vertical: true)
                    }
                } header: {
                    Text(LocalizedStringKey(section.headerKey)).accessibilityAddTraits(.isHeader)
                }
            }
        }
        .navigationTitle(Text(LocalizedStringKey(AlwaysConnectedPresentation.explainerTitleKey)))
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
    }
}

/// Peer the friend sheet is shown for (identifiable for `.sheet(item:)`).
struct AlwaysConnectedTarget: Identifiable, Equatable {
    let peerID: String
    let name: String
    var id: String { peerID }
}
