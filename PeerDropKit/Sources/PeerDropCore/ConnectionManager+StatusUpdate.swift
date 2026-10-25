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
// of content). Sending and applying the status are Task 4.

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

    /// Records the friend's status message (Task 4).
    func applyReceivedStatus(_ payload: StatusUpdatePayload, from pc: PeerConnection) {}

    /// A rendezvous connection learned (or lost) the peer's capability from
    /// its encrypted HELLO; Task 4 sends our current status from here.
    func statusUpdateCapabilityLearned(_ pc: PeerConnection) {}
}
