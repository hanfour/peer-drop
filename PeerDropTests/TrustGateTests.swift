import XCTest
import CryptoKit
import PeerDropSecurity
@testable import PeerDrop

/// Pure-function tests for the trust gate (audit-#14 Stage 3) that decides
/// whether a peer is eligible to receive user-initiated sends (files, chat,
/// media). Lives at the static `evaluateTrustGate` boundary so the gate's
/// truth table is verifiable without a live `PeerConnection` / `NWConnection`.
///
/// The wrapper `isPeerTrustedForUserActions(peerID:)` on `ConnectionManager`
/// just does the lookup + delegates, so behavior end-to-end is asserted via
/// the existing `LocalFirstTrustTests` (approve flips trust → gate opens).
final class TrustGateTests: XCTestCase {

    private func makeContact(trust: TrustLevel, blocked: Bool = false) -> TrustedContact {
        TrustedContact(
            displayName: "Alice",
            identityPublicKey: Curve25519.KeyAgreement.PrivateKey().publicKey.rawRepresentation,
            trustLevel: trust,
            isBlocked: blocked
        )
    }

    // MARK: - Legacy peer bypass

    func test_legacyPeer_alwaysAllowed_regardlessOfContact() {
        // v5.0.x peers don't carry an identity key or support secure channels;
        // gating them would break interop with shipping clients.
        XCTAssertTrue(ConnectionManager.evaluateTrustGate(
            supportsSecureChannel: false,
            publicKey: nil,
            contact: nil))
        // Even if (somehow) a contact record exists at .unknown, legacy
        // semantics override.
        XCTAssertTrue(ConnectionManager.evaluateTrustGate(
            supportsSecureChannel: false,
            publicKey: Data(repeating: 0, count: 32),
            contact: makeContact(trust: .unknown)))
    }

    // MARK: - v5.1+ peer, no contact yet

    func test_securePeer_withoutPublicKey_isDenied() {
        // Defensive: a peer advertising secure-channel support but missing
        // an identity public key is in an impossible state; fail closed.
        XCTAssertFalse(ConnectionManager.evaluateTrustGate(
            supportsSecureChannel: true,
            publicKey: nil,
            contact: nil))
    }

    func test_securePeer_withPublicKey_butNoContactRecord_isDenied() {
        // Brief window during handshake where the contact hasn't been added
        // yet. Better to defer the send than risk leaking to an unverified peer.
        XCTAssertFalse(ConnectionManager.evaluateTrustGate(
            supportsSecureChannel: true,
            publicKey: Data(repeating: 0xAB, count: 32),
            contact: nil))
    }

    // MARK: - v5.1+ peer, contact present

    func test_securePeer_atUnknown_isAllowed_afterHotfix_2026_05_21() {
        // Hotfix 2026-05-21: gate threshold lowered from `.linked` to
        // `.unknown`. The original `.linked` threshold required users to
        // walk through the SAS pairing sheet, but that sheet only
        // surfaces on the local-Wi-Fi path — relay (cross-country) users
        // had no way to elevate past `.unknown` and every chat send hit
        // this gate. Receiver-side trust on first contact is still gated
        // by handleRemoteMessage's pendingFirstContact, so MITM defense
        // is intact on the receiver side. See evaluateTrustGate's doc
        // comment for the full history.
        XCTAssertTrue(ConnectionManager.evaluateTrustGate(
            supportsSecureChannel: true,
            publicKey: Data(repeating: 0xAB, count: 32),
            contact: makeContact(trust: .unknown)))
    }

    func test_securePeer_atLinked_isAllowed() {
        XCTAssertTrue(ConnectionManager.evaluateTrustGate(
            supportsSecureChannel: true,
            publicKey: Data(repeating: 0xAB, count: 32),
            contact: makeContact(trust: .linked)))
    }

    func test_securePeer_atVerified_isAllowed() {
        XCTAssertTrue(ConnectionManager.evaluateTrustGate(
            supportsSecureChannel: true,
            publicKey: Data(repeating: 0xAB, count: 32),
            contact: makeContact(trust: .verified)))
    }

    // MARK: - Blocked overrides trust

    func test_blockedContact_isDenied_evenAtLinkedTrust() {
        // isBlocked is the explicit user gesture to refuse the peer; it
        // overrides every higher trust level. Without this branch a
        // previously-trusted peer who gets blocked could keep receiving data.
        XCTAssertFalse(ConnectionManager.evaluateTrustGate(
            supportsSecureChannel: true,
            publicKey: Data(repeating: 0xAB, count: 32),
            contact: makeContact(trust: .linked, blocked: true)))
    }

    func test_blockedContact_isDenied_evenAtVerifiedTrust() {
        XCTAssertFalse(ConnectionManager.evaluateTrustGate(
            supportsSecureChannel: true,
            publicKey: Data(repeating: 0xAB, count: 32),
            contact: makeContact(trust: .verified, blocked: true)))
    }
}
