import Foundation
import PeerDropProtocol
import PeerDropSecurity

// Project F2 — the `.statusUpdate` frame (a friend's category status message).
//
// Capability-negotiated like Project C's notes exchange: an older build fails
// the connection on an unknown `MessageType`, so the frame is only ever sent
// when both HELLOs on THIS connection advertised `supportsStatusUpdate`, the
// channel is `.secured`, and it travels inside a `secureEnvelope`. It is
// deliberately NOT in `PeerConnection.unwrappedControlTypes`. Receiving goes
// through the same gate; anything else is dropped silently (no reply, no log
// of content).
//
// Sending: our effective status for the friend (their category's message, or
// nil) goes out when the channel is secured, when a rendezvous peer's
// encrypted HELLO teaches the capability, and after every category edit,
// but only when it differs from what this connection last got
// (`sentStatusTexts`). Receiving: the last frame received wins and is stored
// on every `DeviceRecord` of that person.

extension ConnectionManager {

    /// Largest accepted `.statusUpdate` payload, in bytes.
    static let statusUpdateMaxPayloadBytes = 1024

    // MARK: - Gate

    func statusUpdateFacts(for pc: PeerConnection) -> StatusUpdateFacts {
        let installed = (connections[pc.id] === pc && pc.state.isConnected)
            || (rendezvousConnections[pc.id] === pc && pc.rendezvousVerified)
        return StatusUpdateFacts(
            isInstalled: installed,
            isSecured: pc.secureChannelState == .secured && pc.secureChannel != nil,
            handshakeKey: pc.handshakePeerIdentityKey,
            helloKey: pc.peerIdentity.identityPublicKey,
            pinning: NotesExchangeFacts.Pinning(pc.pinningVerdict),
            peerSupports: pc.peerSupportsStatusUpdate,
            localAdvertised: pc.advertisedStatusUpdate ?? false)
    }

    // MARK: - Receive

    /// The payload of `m` if it may be honoured: from an envelope, gate open,
    /// small enough, decodable, and at most `maxStatusMessageLength`
    /// characters once cleaned. The returned text is the cleaned one.
    func acceptedStatusUpdate(_ m: PeerMessage, on pc: PeerConnection,
                              origin: PeerConnection.MessageOrigin) -> StatusUpdatePayload? {
        guard origin == .envelope, m.type == .statusUpdate,
              StatusUpdateGate.allows(statusUpdateFacts(for: pc)),
              let data = m.payload, data.count <= Self.statusUpdateMaxPayloadBytes,
              var payload = try? JSONDecoder().decode(StatusUpdatePayload.self, from: data) else { return nil }
        let cleaned = payload.text.flatMap(PresencePolicy.cleanStatusMessage)
        if let cleaned, cleaned.count > PresencePolicy.maxStatusMessageLength { return nil }
        payload.text = cleaned
        return payload
    }

    func handleStatusUpdateMessage(_ message: PeerMessage, on pc: PeerConnection,
                                   origin: PeerConnection.MessageOrigin) {
        guard let payload = acceptedStatusUpdate(message, on: pc, origin: origin) else { return }
        statusUpdateAcceptedForTesting?(payload, pc)
        applyReceivedStatus(payload, from: pc)
    }

    /// Stores the friend's status on every record of that person. The last
    /// frame received wins; `updatedAt` is not compared (one connection is
    /// ordered and replay-free, and a peer's clock going back must not block
    /// an update).
    func applyReceivedStatus(_ payload: StatusUpdatePayload, from pc: PeerConnection) {
        let ids = notificationAliasIDs(for: friendAliasIDs(forIdentity: pc.peerIdentity, extraIDs: [pc.id]))
        deviceStore.setStatus(payload.text, updatedAt: payload.updatedAt, forRecordIDs: Set(ids))
    }

    // MARK: - Send

    /// What the friend on `pc` should see: their category's message if shown, else nil.
    func effectiveStatusText(for pc: PeerConnection) -> String? {
        PresencePolicy.statusText(
            aliases: notificationAliasIDs(for: friendAliasIDs(
                forIdentity: pc.peerIdentity, extraIDs: [pc.id, ChatStorageKey.key(forConnection: pc)])),
            categories: categoryStore.categories)
    }

    /// Sends our effective status on `pc` when it differs from the last one
    /// sent there (or `force`). Never without the gate (both flags, secured,
    /// trusted, installed) and never to a friend who may not see us.
    func sendStatusUpdateIfNeeded(to pc: PeerConnection, force: Bool = false) {
        guard StatusUpdateGate.allows(statusUpdateFacts(for: pc)), isFriendVisible(connection: pc) else { return }
        let key = ObjectIdentifier(pc)
        let text = effectiveStatusText(for: pc)
        if !force, let sent = sentStatusTexts[key], sent == text { return }
        sentStatusTexts.updateValue(text, forKey: key)
        guard let message = try? PeerMessage.statusUpdate(
            StatusUpdatePayload(text: text, updatedAt: presenceClock()), senderID: localIdentity.id) else { return }
        Task { @MainActor [weak pc] in try? await pc?.sendMessage(message) }
    }

    /// After a category edit: every live connection whose text changed.
    func broadcastStatusUpdates() {
        for pc in Array(connections.values) + Array(rendezvousConnections.values) {
            sendStatusUpdateIfNeeded(to: pc)
        }
    }

    /// A rendezvous connection learned (or lost) the peer's capability from
    /// its encrypted HELLO. This fires on EVERY such HELLO: the first one with
    /// the flag sends (nothing recorded yet), later ones only on a change. A
    /// lost flag forgets what was sent so a re-advertisement sends again. If
    /// our own HELLO is still in flight the gate is closed here, and
    /// `sendRendezvousCapabilityHello` sends once it is on the wire.
    func statusUpdateCapabilityLearned(_ pc: PeerConnection) {
        guard pc.peerSupportsStatusUpdate else { forgetSentStatus(for: pc); return }
        sendStatusUpdateIfNeeded(to: pc)
    }

    /// The connection is gone (or replaced): drop what it was sent.
    func forgetSentStatus(for pc: PeerConnection) {
        sentStatusTexts.removeValue(forKey: ObjectIdentifier(pc))
    }
}
