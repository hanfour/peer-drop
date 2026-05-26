import XCTest
import PeerDropProtocol
import CryptoKit
@testable import PeerDrop

/// Integration tests for the relay-path send trust gate. Regression coverage
/// for the v5.3.6 hotfix (2026-05-21): the audit-#14 sender-side trust gate
/// required `>= .linked`, but relay (cross-country) peers had no way to
/// elevate past `.unknown` because the SAS pairing sheet only surfaces on
/// local-Wi-Fi. The fix lowered the threshold to `>= .unknown`. These tests
/// drive the wrapper `isPeerTrustedForUserActions(peerID:)` end-to-end
/// (peer-identity extraction → `trustedContactStore` lookup →
/// `evaluateTrustGate`) so a future refactor of either layer can't silently
/// re-break relay sends. The pure-function gate is exhaustively covered by
/// `TrustGateTests`; this file pins the integration plumbing.
@MainActor
final class RelayTrustGateIntegrationTests: XCTestCase {

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

    /// Build a v5.1+ peer identity (`supportsSecureChannel: true`) carrying a
    /// fresh Curve25519 identity key. Mirrors what a real relay hello would
    /// populate after a successful handshake.
    private func makeSecurePeerIdentity(displayName: String = "Alice") -> (PeerIdentity, Data) {
        let identityKey = Curve25519.KeyAgreement.PrivateKey().publicKey.rawRepresentation
        createdIdentityKeys.append(identityKey)
        let fingerprint = ConnectionManager.computeFingerprint(of: identityKey)
        let identity = PeerIdentity(
            displayName: displayName,
            certificateFingerprint: nil,
            identityPublicKey: identityKey,
            identityFingerprint: fingerprint,
            supportsSecureChannel: true)
        return (identity, identityKey)
    }

    private func injectPeer(
        into cm: ConnectionManager,
        peerID: String,
        identity: PeerIdentity
    ) {
        let pc = PeerConnection(
            peerID: peerID,
            transport: NoOpTransport(),
            peerIdentity: identity,
            localIdentity: PeerIdentity(displayName: "Self"),
            state: .connected)
        cm._setConnectionForTesting(peerID: peerID, pc)
    }

    // MARK: - Regression: relay-path send must succeed at .unknown trust

    /// Reproduces the exact scenario the 2026-05-21 user report hit: peer
    /// connected via relay (secure channel up, but no SAS prompt to elevate
    /// trust), contact record sitting at `.unknown` from the initial hello.
    /// Pre-hotfix this returned false and every chat send got marked
    /// `.failed`. Post-hotfix it must return true.
    func test_relayPeer_unknownContact_isAllowed() {
        let cm = makeManager()
        let peerID = UUID().uuidString
        let (identity, pubKey) = makeSecurePeerIdentity()
        cm.trustedContactStore.add(TrustedContact(
            displayName: "Alice",
            identityPublicKey: pubKey,
            trustLevel: .unknown))
        injectPeer(into: cm, peerID: peerID, identity: identity)

        XCTAssertTrue(cm.isPeerTrustedForUserActions(peerID: peerID),
            "Relay peer with .unknown contact must be allowed to send — see v5.3.6 hotfix.")
    }

    /// Same setup, but the user has explicitly blocked the contact. Blocked
    /// overrides every trust level — `evaluateTrustGate` returns false even
    /// at `.verified`, and the integration must propagate that.
    func test_relayPeer_blockedContact_isDenied() {
        let cm = makeManager()
        let peerID = UUID().uuidString
        let (identity, pubKey) = makeSecurePeerIdentity()
        cm.trustedContactStore.add(TrustedContact(
            displayName: "Alice",
            identityPublicKey: pubKey,
            trustLevel: .linked,
            isBlocked: true))
        injectPeer(into: cm, peerID: peerID, identity: identity)

        XCTAssertFalse(cm.isPeerTrustedForUserActions(peerID: peerID),
            "Blocked contacts must always be denied regardless of trust level.")
    }

    /// During the brief window between the initial connect and the hello
    /// that creates the `.unknown` row, the contact lookup returns nil.
    /// `evaluateTrustGate` fails closed for this case and the integration
    /// must too — sends should be deferred, not silently leak to an
    /// unverified peer.
    func test_relayPeer_noContactRecord_isDenied() {
        let cm = makeManager()
        let peerID = UUID().uuidString
        let (identity, _) = makeSecurePeerIdentity()
        // Note: intentionally NOT adding the contact. Simulates the
        // pre-hello window where the row hasn't been written yet.
        injectPeer(into: cm, peerID: peerID, identity: identity)

        XCTAssertFalse(cm.isPeerTrustedForUserActions(peerID: peerID),
            "Secure peer without a contact record yet must fail closed.")
    }

    /// v5.0.x peers don't carry an identity key or advertise secure-channel
    /// support. The gate bypasses trust entirely for them so interop with
    /// shipped clients isn't broken. Integration must respect that branch.
    func test_legacyPeer_alwaysAllowed_regardlessOfContact() {
        let cm = makeManager()
        let peerID = UUID().uuidString
        let legacyIdentity = PeerIdentity(
            displayName: "Old Client",
            certificateFingerprint: nil,
            identityPublicKey: nil,
            identityFingerprint: nil,
            supportsSecureChannel: false)
        injectPeer(into: cm, peerID: peerID, identity: legacyIdentity)

        XCTAssertTrue(cm.isPeerTrustedForUserActions(peerID: peerID),
            "v5.0.x peers must bypass the trust gate.")
    }

    /// If `peerID` isn't in `connections`, the wrapper returns false (no
    /// peer to send to). Belt-and-braces — protects callers from a stale
    /// peerID after disconnect.
    func test_unknownPeerID_isDenied() {
        let cm = makeManager()
        XCTAssertFalse(cm.isPeerTrustedForUserActions(peerID: "nonexistent"),
            "Unknown peerID must be denied.")
    }
}

// MARK: - No-op transport

/// Minimal `TransportProtocol` stub for tests that only need a
/// `PeerConnection` instance to satisfy the type system. Never sends,
/// never receives — fine because `isPeerTrustedForUserActions` only
/// inspects `peerIdentity`.
private final class NoOpTransport: TransportProtocol {
    var isReady: Bool { true }
    var onStateChange: ((TransportState) -> Void)?
    func send(_ message: PeerMessage) async throws {}
    func receive() async throws -> PeerMessage {
        try await Task.sleep(nanoseconds: UInt64.max)
        throw CancellationError()
    }
    func close() {}
}
