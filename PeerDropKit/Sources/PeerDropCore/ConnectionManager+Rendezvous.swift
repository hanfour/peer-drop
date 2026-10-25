import Foundation
import Combine
import SwiftUI
#if os(iOS)
import UIKit
#endif
import PeerDropProtocol
import PeerDropSecurity
import PeerDropTransport

// Project E / Task 5 — the ConnectionManager seam for rendezvous ("always
// connected") connections.
//
// A rendezvous connection is a `PeerConnection` keyed by the friend's
// `TrustedContact.deviceId` with a pre-populated identity (pinned key). It is
// held in `rendezvousConnections`, NOT in `connections`, so it never counts
// against `maxConnections`, never changes `focusedPeerID` or the global
// `state`, and never reaches the TOFU / SAS / key-change dialogs. Strict
// secure-channel policy:
// - the LocalSecureChannel must be up within
//   `rendezvousSecureChannelTimeoutNanoseconds` of install; otherwise the
//   connection is closed (never `.fallbackPlaintext`);
// - it is `verified` (online, sendable, returned by `connection(for:)`) only
//   when `.secured` AND the handshake key == the pinned contact key AND the
//   contact is still opted in / eligible AND `FriendBinding.verifiedAccount
//   != nil` AND the peer's first envelope has decrypted (key confirmation:
//   the handshake is static-static DH over a CLAIMED key, so `.secured` alone
//   is reachable by someone who only knows the pinned PUBLIC key);
// - a HELLO whose claimed key differs (from the pinned or handshake key)
//   closes it; a HELLO never re-points the identity;
// - only chat frames, encrypted, from a verified connection are dispatched.
// Every close is quiet (`cancel()`: no farewell frame). Nothing here logs.
// Failure causes go to the manager as `RendezvousConnectionFailure` (local,
// in-memory diagnostics only).

/// Outcomes the connection layer reports to the rendezvous manager.
@MainActor
public protocol RendezvousConnectionEventSink: AnyObject {
    /// `reason` is set when `ok == false`.
    func secureChannelDidComplete(contactID: UUID, ok: Bool, reason: RendezvousConnectionFailure?)
    func connectionDidClose(contactID: UUID, reason: RendezvousConnectionFailure?)
}

extension RendezvousManager: RendezvousConnectionEventSink {}

/// The `DirectConnectionChecker` + `RendezvousConnectionInstaller` handed to
/// `RendezvousManager`. Holds the ConnectionManager weakly (the manager holds
/// this strongly), so there is no retain cycle.
@MainActor
public final class RendezvousConnectionBridge: DirectConnectionChecker, RendezvousConnectionInstaller {
    weak var owner: ConnectionManager?
    public var onDirectConnectionsChanged: (() -> Void)?

    init(owner: ConnectionManager) { self.owner = owner }

    public func hasDirectConnection(to contact: TrustedContact) -> Bool {
        owner?.hasDirectConnection(to: contact) ?? false
    }

    public func install(transport: TransportProtocol, contact: TrustedContact) -> Bool {
        owner?.installRendezvousConnection(transport: transport, contact: contact) != nil
    }

    public func uninstall(contact: TrustedContact) {
        owner?.uninstallRendezvousConnection(contact: contact)
    }
}

extension ConnectionManager {

    /// Frames a verified rendezvous connection may deliver (chat, plus the
    /// gated Project F2 status update). File transfer, calls, clipboard,
    /// NearbyInteraction, device-id exchange and the notes exchange are not
    /// carried cross-network (they would drive global state / UI, or are
    /// face-to-face only).
    static let rendezvousDispatchedTypes: Set<MessageType> = [
        .textMessage, .mediaMessage, .messageReceipt, .typingIndicator, .reaction,
        .chatReject, .messageEdit, .messageDelete, .ping, .pong,
        .statusUpdate,
    ]

    var rendezvousEvents: RendezvousConnectionEventSink? {
        rendezvousEventSinkForTesting ?? rendezvousManager
    }

    // MARK: - Direct connections (DirectConnectionChecker)

    /// A live direct (nearby / manual relay) connection to the contact's
    /// device id. Looks at `connections` only, so a rendezvous connection
    /// never counts; dead / failed members don't count either.
    func hasDirectConnection(to contact: TrustedContact) -> Bool {
        guard let id = contact.deviceId, !id.isEmpty else { return false }
        return hasActiveDirectConnection(peerID: id)
    }

    func hasActiveDirectConnection(peerID id: String) -> Bool {
        connections.contains { key, pc in (key == id || pc.peerIdentity.id == id) && pc.state.isActive }
    }

    /// Called whenever `connections` changes. Always async: the manager's
    /// reconcile must never run inside `addConnection` / `removeConnection`.
    func notifyDirectConnectionsChanged() {
        Task { @MainActor [weak self] in
            self?.rendezvousBridge.onDirectConnectionsChanged?()
        }
    }

    // MARK: - Lifecycle

    /// Start (or resume) rendezvous if the app is in the foreground; never in
    /// the background. Idempotent. For launch paths that miss the first
    /// `.active` scene phase (Mac `onAppear`) and for wake from sleep.
    public func startRendezvousIfForeground() {
        guard rendezvousAppIsForeground else { return }
        // Project F2: the clock may have crossed a schedule boundary while
        // asleep (Mac wake comes through here).
        reevaluatePresence()
        rendezvousAppDidBecomeActive()
    }

    var rendezvousAppIsForeground: Bool {
        if lastScenePhase == .background { return false }
        #if canImport(UIKit) && os(iOS)
        return UIApplication.shared.applicationState != .background
        #else
        return true
        #endif
    }

    /// Foreground: start (or resume) the rendezvous manager.
    func rendezvousAppDidBecomeActive() {
        guard !ScreenshotModeProvider.shared.isActive else { return }
        ensureRendezvousManager()?.appDidBecomeActive()
    }

    /// Background (iOS only; the Mac stays connected): leave every room and
    /// close every cross-network connection without sending anything.
    func rendezvousAppDidEnterBackground() {
        guard rendezvousClosesOnBackground else { return }
        rendezvousManager?.appDidEnterBackground()
        for pc in Array(rendezvousConnections.values) { removeRendezvousConnection(pc) }
    }

    /// The manager, created if needed (not started). Used by the opt-in
    /// toggle, which must work even before the first foreground start.
    @discardableResult
    public func ensureRendezvousManager() -> RendezvousManager? {
        if let m = rendezvousManager { return m }
        guard !ScreenshotModeProvider.shared.isActive else { return nil }
        if let make = rendezvousManagerFactoryForTesting {
            let m = make()
            attachRendezvousManager(m)
            return m
        }
        #if canImport(WebRTC)
        let m = RendezvousManager.live(
            contacts: { [weak self] in self?.trustedContactStore.contacts ?? [] },
            direct: rendezvousBridge,
            installer: rendezvousBridge,
            visible: { [weak self] c in self?.isFriendVisible(contact: c) ?? true })
        attachRendezvousManager(m)
        return m
        #else
        return nil
        #endif
    }

    private func attachRendezvousManager(_ m: RendezvousManager) {
        rendezvousManager = m
        rendezvousLinkStatesCancellable = m.$linkStates
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.objectWillChange.send() }
    }

    /// Test-only: use `manager` (built with fakes over `rendezvousBridge`).
    func _setRendezvousManagerForTesting(_ manager: RendezvousManager) {
        attachRendezvousManager(manager)
    }

    // MARK: - Presence / lookup

    /// Device ids of contacts whose room is waiting or negotiating.
    /// `unreachable` maps to nothing (offline): peer-off and refused look alike.
    func rendezvousConnectingDeviceIDs() -> Set<String> {
        guard let m = rendezvousManager, !m.linkStates.isEmpty else { return [] }
        var ids: Set<String> = []
        for contact in trustedContactStore.contacts where m.linkState(for: contact.id) == .connecting {
            if let id = contact.deviceId, !id.isEmpty { ids.insert(id) }
        }
        return ids
    }

    /// The verified rendezvous connection for `peerID`, if any.
    func verifiedRendezvousConnection(for peerID: String) -> PeerConnection? {
        if let pc = rendezvousConnections[peerID] { return pc.rendezvousVerified ? pc : nil }
        return rendezvousConnections.values.first { $0.rendezvousVerified && $0.peerIdentity.id == peerID }
    }

    // MARK: - Install (RendezvousConnectionInstaller)

    /// The store's current copy of `contact`, if it may be auto-connected now:
    /// opted in and eligible (bound account, no pending claim, not blocked,
    /// unique key, device id), with the same key and device id the manager saw.
    /// Eligibility includes a device id unique among contacts (I-3). Project
    /// F2: the friend's category must also show us online right now (checked
    /// live, so a schedule boundary racing a negotiation still refuses).
    private func currentRendezvousContact(id: UUID, key: Data?, deviceId: String?) -> TrustedContact? {
        let all = trustedContactStore.contacts
        guard let c = all.first(where: { $0.id == id }),
              c.identityPublicKey == key,
              c.deviceId == deviceId,
              c.isRendezvousEnabled,
              TrustedContactStore.isRendezvousEligible(c, among: all),
              isFriendVisible(contact: c) else { return nil }
        return c
    }

    /// Install an open data channel for `contact` under the strict policy.
    /// Returns nil (nothing sent, transport untouched) when refused: contact
    /// not eligible, a direct connection with the same key exists, one is
    /// already installed for it, or the cross-network cap is reached. Never
    /// calls back synchronously; the outcome is reported later, exactly once,
    /// through `secureChannelDidComplete`.
    @discardableResult
    public func installRendezvousConnection(transport: TransportProtocol, contact: TrustedContact) -> PeerConnection? {
        guard let c = currentRendezvousContact(id: contact.id, key: contact.identityPublicKey, deviceId: contact.deviceId),
              let deviceID = c.deviceId,
              !deviceID.hasPrefix("relay-"),
              !hasActiveDirectConnection(peerID: deviceID),
              rendezvousConnections[deviceID] == nil,
              !rendezvousConnections.values.contains(where: { $0.rendezvousContactID == c.id }),
              rendezvousConnections.count < maxRendezvousConnections else { return nil }

        let identity = PeerIdentity(id: deviceID, displayName: c.displayName, identityPublicKey: c.identityPublicKey,
                                    supportsSecureChannel: true,
                                    secureChannelVersion: PeerIdentity.currentSecureChannelVersion)
        let pc = PeerConnection(peerID: deviceID, transport: transport, peerIdentity: identity,
                                localIdentity: localIdentity.withoutNotesExchange(), state: .connected)
        pc.isRendezvous = true
        pc.rendezvousContactID = c.id
        pc.isRelayTransport = true          // not face to face: Project C's gate refuses it
        pc.advertisedNotesExchange = false
        // Project F2: nothing advertised until the encrypted HELLO goes out
        // after key confirmation (`confirmRendezvousConnection`).
        pc.advertisedStatusUpdate = false
        pc.requiresStrictSecureChannel = true
        pc.handshakeFallbackNanoseconds = rendezvousSecureChannelTimeoutNanoseconds

        // NOTE: `transport.onStateChange` belongs to the negotiator; never set here.
        pc.onStateChange = { [weak self] _ in self?.objectWillChange.send() }
        pc.onMessageReceived = { [weak self, weak pc] message in
            guard let self, let pc else { return }
            self.dispatchRendezvous(message, on: pc, origin: .plaintext)
        }
        pc.onMessageReceivedWithOrigin = { [weak self, weak pc] message, origin in
            guard let self, let pc else { return }
            self.dispatchRendezvous(message, on: pc, origin: origin)
        }
        pc.onDisconnected = { [weak self, weak pc] in
            guard let self, let pc else { return }
            self.closeRendezvousConnection(pc, reason: pc.envelopeDecryptFailed ? .decryptFailed : .connectionClosed)
        }
        pc.onSecureChannelEstablished = { [weak self, weak pc] _ in
            guard let self, let pc else { return }
            self.rendezvousSecureChannelUp(pc)
        }
        pc.onStrictSecureChannelFailure = { [weak self, weak pc] in
            guard let self, let pc else { return }
            self.closeRendezvousConnection(pc, reason: pc.strictSecureChannelTimedOut ? .timeout : .channelFailed)
        }

        rendezvousConnections[deviceID] = pc
        objectWillChange.send()
        pc.startReceiving()

        // Deadline from install, independent of the handshake's own timer.
        // Covers key confirmation too: no confirmed channel in time ⇒ closed.
        let timeout = rendezvousSecureChannelTimeoutNanoseconds
        Task { @MainActor [weak self, weak pc] in
            try? await Task.sleep(nanoseconds: timeout)
            guard let self, let pc, !pc.rendezvousVerified else { return }
            self.closeRendezvousConnection(pc, reason: .timeout)
        }
        Task { @MainActor [weak pc] in
            await pc?.startSecureChannelNegotiation(peerSupportsSecureChannel: true)
        }
        return pc
    }

    /// Manager-initiated removal (downgrade, background, direct wins, retire).
    /// Idempotent; sends nothing and reports nothing back.
    func uninstallRendezvousConnection(contact: TrustedContact) {
        let matches = rendezvousConnections.values.filter { $0.rendezvousContactID == contact.id }
        for pc in matches { removeRendezvousConnection(pc) }
    }

    // MARK: - Verification

    /// Why `pc` may not (or no longer) be trusted, or nil when it may.
    /// Re-checked at channel-up AND at key confirmation (m-1).
    private func rendezvousVerificationFailure(_ pc: PeerConnection) -> RendezvousConnectionFailure? {
        guard let contactID = pc.rendezvousContactID, let pinned = pc.peerIdentity.identityPublicKey else {
            return .bindingFailed
        }
        guard pc.secureChannelState == .secured, let handshakeKey = pc.handshakePeerIdentityKey else {
            return .channelFailed
        }
        let all = trustedContactStore.contacts
        // The contact itself changed (re-keyed, removed): a contact change,
        // not a contradiction of the pinned identity.
        guard let stored = all.first(where: { $0.id == contactID }), stored.identityPublicKey == pinned else {
            return .bindingFailed
        }
        guard handshakeKey == pinned else { return .keyMismatch }
        guard currentRendezvousContact(id: contactID, key: pinned, deviceId: pc.id) != nil,
              let account = FriendBinding(contacts: { all }, live: { _ in .secured(handshakeKey) })
                .verifiedAccount(forChatPeerID: pc.id),
              account.contactID == contactID else { return .bindingFailed }
        return nil
    }

    /// Runs synchronously when the LocalSecureChannel comes up (before the
    /// receive loop reads the next frame). Passing the checks only makes the
    /// connection AWAIT CONFIRMATION; it is not verified yet.
    private func rendezvousSecureChannelUp(_ pc: PeerConnection) {
        guard rendezvousConnections[pc.id] === pc, !pc.rendezvousVerified,
              !pc.rendezvousAwaitingConfirmation else { return }
        if let failure = rendezvousVerificationFailure(pc) {
            closeRendezvousConnection(pc, reason: failure)
            return
        }
        pc.rendezvousAwaitingConfirmation = true

        // Double-Ratchet bootstrap (see `handleSecureChannelEstablished`): the
        // initiator sends one encrypted no-op so either side can send first.
        // It is also the responder's key confirmation; the responder's own
        // no-op (`sendResponderNoOpIfNeeded`) is the initiator's.
        if pc.secureChannel?.isInitiator == true {
            let senderID = localIdentity.id
            Task { @MainActor [weak pc] in
                guard let pc,
                      let msg = try? PeerMessage.typingIndicator(
                        TypingIndicatorPayload(isTyping: false, timestamp: Date()), senderID: senderID)
                else { return }
                try? await pc.sendMessage(msg)
            }
        }
    }

    /// The peer's first envelope decrypted: it holds the pinned key's private
    /// half. Only now is the connection verified (online, sendable).
    private func confirmRendezvousConnection(_ pc: PeerConnection) {
        if let failure = rendezvousVerificationFailure(pc) {
            closeRendezvousConnection(pc, reason: failure)
            return
        }
        pc.rendezvousAwaitingConfirmation = false
        pc.setPinningVerdict(.matched)
        pc.rendezvousVerified = true
        reportRendezvousOutcome(pc, ok: true, reason: nil)
        bumpSecurityEpoch()
        objectWillChange.send()
        sendRendezvousCapabilityHello(pc)
    }

    /// Project F2: the install-time identity is pinned and Project E peers
    /// never send a HELLO, so capabilities are exchanged in one ENCRYPTED HELLO
    /// once the connection is verified. A Project E peer only runs its key
    /// check on it (same key ⇒ harmless). Never sent in plaintext: the strict
    /// channel wraps every business frame.
    private func sendRendezvousCapabilityHello(_ pc: PeerConnection) {
        let identity = localIdentity.withoutNotesExchange()
        guard let hello = try? PeerMessage.hello(identity: identity) else { return }
        pc.advertisedStatusUpdate = identity.supportsStatusUpdate
        Task { @MainActor [weak pc] in
            guard let pc else { return }
            try? await pc.sendMessage(hello)
        }
    }

    // MARK: - Dispatch

    private func dispatchRendezvous(_ message: PeerMessage, on pc: PeerConnection,
                                    origin: PeerConnection.MessageOrigin) {
        guard rendezvousConnections[pc.id] === pc else { return }
        // Key confirmation: the first decrypted envelope is consumed here
        // (not processed), except a HELLO / disconnect, which keep their checks.
        if pc.rendezvousAwaitingConfirmation, origin == .envelope {
            confirmRendezvousConnection(pc)
            guard rendezvousConnections[pc.id] === pc,
                  message.type == .hello || message.type == .disconnect else { return }
        }
        switch message.type {
        case .hello:
            // The claimed key must equal the pinned key (and the handshake key
            // once known). Never re-points the identity.
            guard let payload = message.payload,
                  let claimed = try? JSONDecoder().decode(PeerIdentity.self, from: payload),
                  let claimedKey = claimed.identityPublicKey,
                  claimedKey == pc.peerIdentity.identityPublicKey,
                  pc.handshakePeerIdentityKey.map({ $0 == claimedKey }) ?? true else {
                // Only an encrypted HELLO is the friend's own word; a
                // plaintext one may be anyone's (never suspends).
                closeRendezvousConnection(pc, reason: origin == .envelope ? .helloMismatch : .helloMismatchUnauthenticated)
                return
            }
            // Project F2: only the friend's own (encrypted, verified) word sets
            // the capability; `peerIdentity` stays pinned.
            if origin == .envelope, pc.rendezvousVerified {
                pc.rendezvousPeerSupportsStatusUpdate = claimed.supportsStatusUpdate
                statusUpdateCapabilityLearned(pc)
            }
            return
        case .disconnect:
            // Peer hung up: close quietly; a direct connection with the same
            // key (if any) is never touched.
            closeRendezvousConnection(pc, reason: .connectionClosed)
            return
        default:
            break
        }
        guard pc.rendezvousVerified,
              Self.rendezvousDispatchedTypes.contains(message.type),
              origin == .envelope || PeerConnection.unwrappedControlTypes.contains(message.type) else { return }
        handleMessageForPeer(message, peerConnection: pc, origin: origin)
    }

    // MARK: - Teardown

    /// Connection-layer close (failure, peer drop, timeout, user disconnect):
    /// quiet, then reported once — `secureChannelDidComplete(ok: false)` if it
    /// never verified, else `connectionDidClose`.
    func closeRendezvousConnection(_ pc: PeerConnection, reason: RendezvousConnectionFailure = .connectionClosed) {
        guard rendezvousConnections[pc.id] === pc else { return }
        let wasVerified = pc.rendezvousVerified
        removeRendezvousConnection(pc)
        if wasVerified {
            guard let id = pc.rendezvousContactID else { return }
            Task { @MainActor [weak self] in self?.rendezvousEvents?.connectionDidClose(contactID: id, reason: reason) }
        } else {
            reportRendezvousOutcome(pc, ok: false, reason: reason)
        }
    }

    /// Exactly once per install, always async.
    private func reportRendezvousOutcome(_ pc: PeerConnection, ok: Bool, reason: RendezvousConnectionFailure?) {
        guard !pc.rendezvousOutcomeReported, let id = pc.rendezvousContactID else { return }
        pc.rendezvousOutcomeReported = true
        Task { @MainActor [weak self] in
            self?.rendezvousEvents?.secureChannelDidComplete(contactID: id, ok: ok, reason: ok ? nil : reason)
        }
    }

    /// Remove and close without any frame (`cancel()`, never `disconnect()`).
    /// Reports nothing to the manager (also used by Project F2's presence
    /// enforcement: a friend hidden on purpose is not a link failure).
    func removeRendezvousConnection(_ pc: PeerConnection) {
        guard rendezvousConnections[pc.id] === pc else { return }
        rendezvousConnections[pc.id] = nil
        pc.onDisconnected = nil
        pc.onMessageReceived = nil
        pc.onMessageReceivedWithOrigin = nil
        pc.onSecureChannelEstablished = nil
        pc.onStrictSecureChannelFailure = nil
        pc.rendezvousVerified = false
        pc.rendezvousAwaitingConfirmation = false
        pc.cancel()
        pc.updateState(.disconnected)
        chatManager.setTyping(false, for: pc.id)
        bumpSecurityEpoch()
        objectWillChange.send()
    }
}
