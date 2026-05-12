import XCTest
import CryptoKit
@testable import PeerDrop

/// Tests for the local-Wi-Fi first-trust consent gate (Item #14 Stage 1).
///
/// `LocalSecureChannel` completes with `pinningVerdict == .firstTrust` when
/// the peer's identity key is unknown to `TrustedContactStore`. v5.1 only
/// logged this; v5.2 surfaces it as `pendingLocalFirstTrust` for the user
/// to explicitly approve (elevate to `.linked`) or block (mark blocked +
/// disconnect).
///
/// These tests drive `pendingLocalFirstTrust` directly (the surfacing path
/// inside `handleSecureChannelEstablished` requires a live `PeerConnection`
/// which the integration tests cover). Approve/block routes are pure state
/// transitions over `TrustedContactStore`, so unit coverage at this layer
/// pins their contract.
@MainActor
final class LocalFirstTrustTests: XCTestCase {

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

    /// Build a synthetic peer identity + matching `pendingLocalFirstTrust`,
    /// optionally seeding `TrustedContactStore` with a pre-existing record
    /// (the `.unknown` row that `checkPeerTrust` writes during hello).
    private func makePending(
        cm: ConnectionManager,
        displayName: String = "Alice",
        seedExistingUnknown: Bool = true
    ) -> PendingFirstContact {
        let identityKey = Curve25519.KeyAgreement.PrivateKey().publicKey.rawRepresentation
        createdIdentityKeys.append(identityKey)
        let hash = SHA256.hash(data: identityKey)
        let hex = hash.prefix(10).map { String(format: "%02X", $0) }.joined()
        let fingerprint = stride(from: 0, to: 20, by: 4).map { i in
            let s = hex.index(hex.startIndex, offsetBy: i)
            let e = hex.index(s, offsetBy: 4)
            return String(hex[s..<e])
        }.joined(separator: " ")
        if seedExistingUnknown {
            cm.trustedContactStore.add(TrustedContact(
                deviceId: "test-device-\(UUID().uuidString.prefix(8))",
                displayName: displayName,
                identityPublicKey: identityKey,
                trustLevel: .unknown
            ))
        }
        return PendingFirstContact(
            fingerprint: fingerprint,
            senderDisplayName: displayName,
            senderIdentityKey: identityKey
        )
    }

    // MARK: - Approve

    func test_approve_elevatesUnknownToLinked_andClearsPrompt() {
        let cm = makeManager()
        let pending = makePending(cm: cm)
        cm.pendingLocalFirstTrust = pending

        cm.approveLocalFirstTrust(fingerprint: pending.fingerprint)

        XCTAssertNil(cm.pendingLocalFirstTrust, "approve clears the prompt")
        let stored = cm.trustedContactStore.find(byPublicKey: pending.senderIdentityKey)
        XCTAssertEqual(stored?.trustLevel, .linked,
                       "approve elevates .unknown → .linked")
        XCTAssertEqual(stored?.isBlocked, false)
    }

    func test_approve_createsContactAtLinked_whenPriorRecordMissing() {
        let cm = makeManager()
        let pending = makePending(cm: cm, displayName: "Carol", seedExistingUnknown: false)
        cm.pendingLocalFirstTrust = pending

        cm.approveLocalFirstTrust(fingerprint: pending.fingerprint)

        let stored = cm.trustedContactStore.find(byPublicKey: pending.senderIdentityKey)
        XCTAssertNotNil(stored, "defensive path: approve creates the contact if missing")
        XCTAssertEqual(stored?.trustLevel, .linked)
        XCTAssertEqual(stored?.displayName, "Carol")
    }

    // MARK: - Block

    func test_block_setsBlocked_andClearsPrompt() {
        let cm = makeManager()
        let pending = makePending(cm: cm, displayName: "Mallory")
        cm.pendingLocalFirstTrust = pending

        cm.blockLocalFirstTrust(fingerprint: pending.fingerprint)

        XCTAssertNil(cm.pendingLocalFirstTrust, "block clears the prompt")
        let stored = cm.trustedContactStore.find(byPublicKey: pending.senderIdentityKey)
        XCTAssertEqual(stored?.isBlocked, true,
                       "block marks the contact as blocked")
        XCTAssertEqual(stored?.trustLevel, .unknown,
                       "block does NOT promote trust level — the record persists for audit")
    }

    func test_block_isNoOp_whenNoExistingContact() {
        let cm = makeManager()
        let pending = makePending(cm: cm, seedExistingUnknown: false)
        cm.pendingLocalFirstTrust = pending

        cm.blockLocalFirstTrust(fingerprint: pending.fingerprint)

        XCTAssertNil(cm.pendingLocalFirstTrust)
        XCTAssertNil(cm.trustedContactStore.find(byPublicKey: pending.senderIdentityKey),
                     "block without prior record does NOT create one — nothing to block")
    }

    // MARK: - Stale-fingerprint guard

    func test_approve_ignoresMismatchedFingerprint() {
        let cm = makeManager()
        let pending = makePending(cm: cm)
        cm.pendingLocalFirstTrust = pending

        // Simulate a stale sheet tap: user taps "Approve" but the fingerprint
        // payload is for a different peer (e.g. the sheet was reused for a
        // queued second peer between render and tap). Handler should no-op.
        cm.approveLocalFirstTrust(fingerprint: "FFFF FFFF FFFF FFFF FFFF")

        XCTAssertNotNil(cm.pendingLocalFirstTrust,
                        "stale fingerprint must not clear the active prompt")
        XCTAssertEqual(
            cm.trustedContactStore.find(byPublicKey: pending.senderIdentityKey)?.trustLevel,
            .unknown,
            "stale fingerprint must not mutate the contact"
        )
    }

    func test_block_ignoresMismatchedFingerprint() {
        let cm = makeManager()
        let pending = makePending(cm: cm)
        cm.pendingLocalFirstTrust = pending

        cm.blockLocalFirstTrust(fingerprint: "FFFF FFFF FFFF FFFF FFFF")

        XCTAssertNotNil(cm.pendingLocalFirstTrust)
        XCTAssertEqual(
            cm.trustedContactStore.find(byPublicKey: pending.senderIdentityKey)?.isBlocked,
            false,
            "stale fingerprint must not block"
        )
    }

    // MARK: - SAS propagation (audit-#14 Stage 2)

    func test_pendingFirstContact_carriesSAS_whenLocalHandshakeProvidesOne() {
        let cm = makeManager()
        let identityKey = Curve25519.KeyAgreement.PrivateKey().publicKey.rawRepresentation
        createdIdentityKeys.append(identityKey)

        cm.pendingLocalFirstTrust = PendingFirstContact(
            fingerprint: "AB12 CD34 EF56 7890 1234",
            senderDisplayName: "Alice",
            senderIdentityKey: identityKey,
            sas: "123 456"
        )

        XCTAssertEqual(cm.pendingLocalFirstTrust?.sas, "123 456",
                       "SAS must round-trip through the pending prompt unchanged")
        XCTAssertNotEqual(cm.pendingLocalFirstTrust?.sas, cm.pendingLocalFirstTrust?.fingerprint,
                          "SAS and fingerprint are distinct artifacts (SAS is a 6-digit code, fingerprint is a 20-hex string)")
    }

    func test_pendingFirstContact_remotePath_carriesNoSAS() {
        // Remote-mailbox first-contact path doesn't have a LocalSecureChannel,
        // so its sas field stays nil. The sheet uses presence of sas to pick
        // the SAS-led layout vs the fingerprint-led layout.
        let identityKey = Curve25519.KeyAgreement.PrivateKey().publicKey.rawRepresentation
        let pending = PendingFirstContact(
            fingerprint: "AB12 CD34 EF56 7890 1234",
            senderDisplayName: "Bob",
            senderIdentityKey: identityKey
        )
        XCTAssertNil(pending.sas)
    }
}
