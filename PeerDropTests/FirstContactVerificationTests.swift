import XCTest
import CryptoKit
@testable import PeerDrop

/// Tests for the first-contact consent gate (Task A.2).
///
/// When an unknown peer sends an initial X3DH message via the relay, the
/// previous behaviour was to auto-create a TrustedContact and immediately
/// respond to the session — giving Mallory free reign to establish a session
/// without the user ever seeing the fingerprint. These tests assert the new
/// gated behaviour:
///
///  1. Unknown peer + initial message → queue for consent, do NOT create
///     contact.
///  2. Reject discards the envelope without creating a contact.
///  3. Approve creates the contact at `.linked` trust.
///  4. Duplicate envelopes from the same unknown peer don't thrash the UI.
///  5. Known peers skip the gate entirely.
@MainActor
final class FirstContactVerificationTests: XCTestCase {

    // MARK: - Cleanup

    /// Identity keys created during a test. We delete the corresponding
    /// TrustedContact entries on tearDown so tests don't leak into the
    /// default-keyed `TrustedContactStore` on disk.
    private var createdIdentityKeys: [Data] = []
    private weak var managerForCleanup: ConnectionManager?

    override func tearDown() {
        if let manager = managerForCleanup {
            for key in createdIdentityKeys {
                if let contact = manager.trustedContactStore.find(byPublicKey: key) {
                    manager.trustedContactStore.remove(contact.id)
                }
            }
            manager.trustedContactStore.flushPendingSave()
        }
        createdIdentityKeys.removeAll()
        super.tearDown()
    }

    private func makeManager() -> ConnectionManager {
        let cm = ConnectionManager()
        managerForCleanup = cm
        return cm
    }

    // MARK: - Tests

    func test_unknownPeerFirstMessage_queuesForConsent() {
        let cm = makeManager()
        let envelope = makeInitialEnvelope(displayName: "Alice")
        let msg = makeMailboxMessage(envelope: envelope)
        createdIdentityKeys.append(envelope.senderIdentityKey)

        cm.handleRemoteMessageForTesting(msg)

        XCTAssertNotNil(cm.pendingFirstContact, "Unknown peer must queue for consent")
        XCTAssertEqual(cm.pendingFirstContact?.senderDisplayName, "Alice")
        XCTAssertEqual(cm.pendingFirstContact?.senderIdentityKey, envelope.senderIdentityKey)
        XCTAssertNil(cm.trustedContactStore.find(byPublicKey: envelope.senderIdentityKey),
                     "Contact must not be created until user approves")
    }

    func test_rejectFirstContact_discardsEnvelopeWithoutContact() {
        let cm = makeManager()
        let envelope = makeInitialEnvelope(displayName: "Mallory")
        createdIdentityKeys.append(envelope.senderIdentityKey)

        cm.handleRemoteMessageForTesting(makeMailboxMessage(envelope: envelope))
        guard let fp = cm.pendingFirstContact?.fingerprint else {
            XCTFail("Expected a queued pending contact"); return
        }

        cm.rejectFirstContact(fingerprint: fp)

        XCTAssertNil(cm.pendingFirstContact)
        XCTAssertNil(cm.trustedContactStore.find(byPublicKey: envelope.senderIdentityKey),
                     "Rejected peers must not appear in the trusted store")
    }

    func test_approveFirstContact_createsContactAtLinkedTrust() {
        let cm = makeManager()
        let envelope = makeInitialEnvelope(displayName: "Bob")
        createdIdentityKeys.append(envelope.senderIdentityKey)

        cm.handleRemoteMessageForTesting(makeMailboxMessage(envelope: envelope))
        guard let fp = cm.pendingFirstContact?.fingerprint else {
            XCTFail("Expected a queued pending contact"); return
        }

        cm.approveFirstContact(fingerprint: fp)

        XCTAssertNil(cm.pendingFirstContact, "pendingFirstContact must clear on approval")
        let stored = cm.trustedContactStore.find(byPublicKey: envelope.senderIdentityKey)
        XCTAssertNotNil(stored, "Approval must create the trusted contact")
        XCTAssertEqual(stored?.trustLevel, .linked,
                       "Approval without QR-verify should be .linked, not .verified")
        XCTAssertEqual(stored?.displayName, "Bob")
        XCTAssertEqual(stored?.mailboxId, envelope.senderMailboxId)
    }

    func test_sameUnknownPeer_doesNotDoubleQueueConsent() {
        let cm = makeManager()
        let envelope = makeInitialEnvelope(displayName: "Charlie")
        createdIdentityKeys.append(envelope.senderIdentityKey)

        cm.handleRemoteMessageForTesting(makeMailboxMessage(envelope: envelope))
        let firstFingerprint = cm.pendingFirstContact?.fingerprint
        cm.handleRemoteMessageForTesting(makeMailboxMessage(envelope: envelope))

        // Still just one pending state — fingerprint is stable, no UI thrash.
        XCTAssertNotNil(cm.pendingFirstContact)
        XCTAssertEqual(cm.pendingFirstContact?.fingerprint, firstFingerprint)
    }

    func test_knownPeer_skipsConsent() {
        let cm = makeManager()
        let envelope = makeInitialEnvelope(displayName: "Dave")
        createdIdentityKeys.append(envelope.senderIdentityKey)

        // Pre-trust the peer.
        cm.trustedContactStore.add(TrustedContact(
            displayName: "Dave",
            identityPublicKey: envelope.senderIdentityKey,
            trustLevel: .verified
        ))

        cm.handleRemoteMessageForTesting(makeMailboxMessage(envelope: envelope))

        XCTAssertNil(cm.pendingFirstContact, "Known peer must skip consent gate")
    }

    func test_fingerprint_matchesTrustedContactKeyFingerprint() {
        // The fingerprint shown in the consent sheet must equal the value the
        // user sees on the verified-contacts screen, otherwise users can't
        // compare them to confirm a previously-paired peer.
        let cm = makeManager()
        let envelope = makeInitialEnvelope(displayName: "Eve")
        createdIdentityKeys.append(envelope.senderIdentityKey)

        cm.handleRemoteMessageForTesting(makeMailboxMessage(envelope: envelope))
        let pendingFingerprint = cm.pendingFirstContact?.fingerprint

        let referenceContact = TrustedContact(
            displayName: "Eve",
            identityPublicKey: envelope.senderIdentityKey,
            trustLevel: .linked
        )
        XCTAssertEqual(pendingFingerprint, referenceContact.keyFingerprint)
    }

    func test_rejectWithMismatchedFingerprint_isNoOp() {
        // The UI passes the fingerprint back so a stale/expired sheet doesn't
        // act on a different pending contact. Test that mismatched fingerprints
        // are ignored.
        let cm = makeManager()
        let envelope = makeInitialEnvelope(displayName: "Frank")
        createdIdentityKeys.append(envelope.senderIdentityKey)

        cm.handleRemoteMessageForTesting(makeMailboxMessage(envelope: envelope))
        XCTAssertNotNil(cm.pendingFirstContact)

        cm.rejectFirstContact(fingerprint: "WRONG FINGERPRINT")

        XCTAssertNotNil(cm.pendingFirstContact, "Mismatched fingerprint must not clear pending state")
    }

    // MARK: - Helpers

    /// Build an initial X3DH envelope from a fresh, unique identity. Each call
    /// returns an envelope with new random keys so tests don't collide on the
    /// shared on-disk TrustedContactStore.
    private func makeInitialEnvelope(displayName: String) -> RemoteMessageEnvelope {
        let identity = Curve25519.KeyAgreement.PrivateKey()
        let ephemeral = Curve25519.KeyAgreement.PrivateKey()
        let ratchet = RatchetMessage(
            ratchetKey: Data(repeating: 0x01, count: 32),
            counter: 0,
            previousCounter: 0,
            ciphertext: Data(repeating: 0x02, count: 64)
        )
        return RemoteMessageEnvelope(
            senderIdentityKey: identity.publicKey.rawRepresentation,
            senderMailboxId: "mbx-\(UUID().uuidString.prefix(8))",
            senderDisplayName: displayName,
            ephemeralKey: ephemeral.publicKey.rawRepresentation,
            usedSignedPreKeyId: 1,
            usedOneTimePreKeyId: nil,
            ratchetMessage: ratchet
        )
    }

    /// Wrap an envelope as a `MailboxMessage` exactly the way the relay does:
    /// JSON-encode then base64-encode into `ciphertext`.
    private func makeMailboxMessage(envelope: RemoteMessageEnvelope) -> MailboxMessage {
        let data = try! JSONEncoder().encode(envelope)
        return MailboxMessage(
            id: UUID().uuidString,
            ciphertext: data.base64EncodedString(),
            timestamp: ISO8601DateFormatter().string(from: Date())
        )
    }
}
