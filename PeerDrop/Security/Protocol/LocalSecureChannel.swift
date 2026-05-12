import Foundation
import CryptoKit

/// Identity interface required by `LocalSecureChannel`. Production uses
/// `IdentityKeyManager.shared`; tests bind to a freshly-generated keypair
/// per case so each handshake gets a unique identity without polluting
/// the real Keychain.
protocol LocalChannelIdentity {
    var publicKey: Curve25519.KeyAgreement.PublicKey { get }
    func deriveSharedSecret(with peerPublicKey: Curve25519.KeyAgreement.PublicKey) throws -> SharedSecret
}

extension IdentityKeyManager: LocalChannelIdentity {}

/// E2E channel for local-network TCP transport. Replaces the abandoned
/// TLS path (`CertificateManager`) with a Signal-style Double Ratchet
/// keyed off the existing per-device Curve25519 identity keys.
///
/// **Wire model**
/// ```
///                  ┌─────────── handshake (plaintext) ───────────┐
///   Peer A ───►  IdentityPubKey_A + RatchetPubKey_A  ──►  Peer B
///   Peer A  ◄──  IdentityPubKey_B + RatchetPubKey_B  ◄───
///                  │
///                  ▼  both sides derive shared static-DH root
///                  ▼  determine initiator/responder by lex order of identity keys
///                  ▼  init DoubleRatchet
///                  │
///   Peer A ───►   RatchetMessage_1                    ──►  Peer B
///                  ...   (forward-secret from this point)
/// ```
///
/// **Threat model**
/// - Passive eavesdropper on LAN: confidentiality only after handshake completes,
///   but the handshake itself only exposes public keys (no secrets).
/// - Active MITM on first contact: still possible — the fingerprint of the
///   peer's identity key must be verified out-of-band (TrustedContactStore /
///   user-displayed fingerprint), same TOFU model the remote-mailbox path uses.
/// - Forward secrecy: per-message keys via DoubleRatchet's DH ratchet step.
///   Compromising a current session key does not reveal past messages.
/// - Identity key compromise: an attacker with the long-term Curve25519
///   private key can read all future channels until the user regenerates.
///   Identity rotation is out of scope for this v5.0.x channel.
///
/// This is Phase 1 — the cryptographic core. PeerConnection integration
/// (handshake state machine, wire-level negotiation, fallback to plaintext
/// for v5.0.x peers) lands in Phase 2.
final class LocalSecureChannel {

    /// Wire frame for an encrypted message. Wraps a `RatchetMessage` with
    /// a version byte so we can roll the format forward.
    struct Frame: Codable {
        /// Schema version. `1` = current format (RatchetMessage payload).
        let version: UInt8
        let message: RatchetMessage

        static let currentVersion: UInt8 = 1
    }

    /// Bundle exchanged during the handshake. Each peer sends its own to
    /// the other; both peers receive the other's. The two together let
    /// each side compute the same root key and bootstrap the ratchet.
    struct HandshakeBundle: Codable {
        /// The sender's long-term Curve25519.KeyAgreement public key, raw.
        let identityPublicKey: Data

        /// A fresh Curve25519.KeyAgreement public key the sender will use
        /// as its starting ratchet key. Must be freshly generated per
        /// handshake — reusing it across sessions defeats forward secrecy.
        let initialRatchetPublicKey: Data
    }

    /// Errors surfaced by establishment / encrypt / decrypt.
    enum ChannelError: Error, Equatable {
        case invalidIdentityKey
        case invalidRatchetKey
        case sameIdentityKey   // two peers with identical pubkeys → MITM or bug
        case decodeFailed
        case wrongVersion(UInt8)
    }

    /// HKDF salt + info — making explicit prevents accidental key reuse
    /// across protocol versions.
    private static let kdfInfo = "PeerDrop-LocalE2E-v1".data(using: .utf8)!

    private let ratchet: DoubleRatchetSession
    let peerIdentityPublicKey: Curve25519.KeyAgreement.PublicKey

    /// Fingerprint of the peer's identity key. Same format as
    /// `IdentityKeyManager.fingerprint` for round-trip verification:
    /// `"A1B2 C3D4 E5F6 G7H8 I9J0"`.
    var peerFingerprint: String {
        let hash = SHA256.hash(data: peerIdentityPublicKey.rawRepresentation)
        let hex = hash.prefix(10).map { String(format: "%02X", $0) }.joined()
        return stride(from: 0, to: 20, by: 4).map { i in
            let start = hex.index(hex.startIndex, offsetBy: i)
            let end = hex.index(start, offsetBy: 4)
            return String(hex[start..<end])
        }.joined(separator: " ")
    }

    private init(
        ratchet: DoubleRatchetSession,
        peerIdentityPublicKey: Curve25519.KeyAgreement.PublicKey
    ) {
        self.ratchet = ratchet
        self.peerIdentityPublicKey = peerIdentityPublicKey
    }

    // MARK: - Handshake API

    /// Generate the local peer's outgoing handshake bundle. Caller is
    /// responsible for sending `bundle` over the plaintext wire.
    /// The returned `myRatchetPrivateKey` MUST be kept by the caller and
    /// passed to `establish` when the peer's bundle arrives — it's
    /// needed for the responder path.
    static func prepareHandshake(
        identity: LocalChannelIdentity
    ) -> (bundle: HandshakeBundle, myRatchetPrivateKey: Curve25519.KeyAgreement.PrivateKey) {
        let ratchetPriv = Curve25519.KeyAgreement.PrivateKey()
        let bundle = HandshakeBundle(
            identityPublicKey: identity.publicKey.rawRepresentation,
            initialRatchetPublicKey: ratchetPriv.publicKey.rawRepresentation
        )
        return (bundle, ratchetPriv)
    }

    /// Complete the handshake after receiving the peer's bundle.
    /// Both peers run this with their own private state and the peer's
    /// public bundle; both end up with a session that can encrypt/decrypt
    /// each other's messages.
    static func establish(
        myIdentity: LocalChannelIdentity,
        myRatchetPrivateKey: Curve25519.KeyAgreement.PrivateKey,
        peerBundle: HandshakeBundle
    ) throws -> LocalSecureChannel {
        // 1. Reconstruct peer's identity key from raw bytes.
        let peerIdentityKey: Curve25519.KeyAgreement.PublicKey
        do {
            peerIdentityKey = try Curve25519.KeyAgreement.PublicKey(
                rawRepresentation: peerBundle.identityPublicKey
            )
        } catch {
            throw ChannelError.invalidIdentityKey
        }

        // 2. Reject same-key handshakes — a peer cannot establish a channel
        //    with itself, and if we see one it's either misconfiguration
        //    or a MITM reflecting our own bundle back.
        if peerIdentityKey.rawRepresentation == myIdentity.publicKey.rawRepresentation {
            throw ChannelError.sameIdentityKey
        }

        // 3. Reconstruct peer's initial ratchet key.
        let peerRatchetKey: Curve25519.KeyAgreement.PublicKey
        do {
            peerRatchetKey = try Curve25519.KeyAgreement.PublicKey(
                rawRepresentation: peerBundle.initialRatchetPublicKey
            )
        } catch {
            throw ChannelError.invalidRatchetKey
        }

        // 4. Static DH between long-term identity keys → root key seed.
        //    This is the only secret derived during handshake. Both peers
        //    compute the same value because DH is symmetric.
        let sharedSecret = try myIdentity.deriveSharedSecret(with: peerIdentityKey)
        let rootKey = sharedSecret.hkdfDerivedSymmetricKey(
            using: SHA256.self,
            salt: Data(),
            sharedInfo: kdfInfo,
            outputByteCount: 32
        )

        // 5. Decide initiator vs responder by lex order of identity public
        //    keys — both peers reach the same conclusion deterministically
        //    without needing a tiebreaker round trip. Initiator's DH
        //    ratchet uses the peer's ratchet key; responder waits for
        //    the first inbound message.
        let myKeyBytes = Array(myIdentity.publicKey.rawRepresentation)
        let theirKeyBytes = Array(peerBundle.identityPublicKey)
        let iAmInitiator = lexCompare(myKeyBytes, theirKeyBytes) < 0

        let ratchet: DoubleRatchetSession
        if iAmInitiator {
            ratchet = DoubleRatchetSession.initializeAsInitiator(
                rootKey: rootKey,
                theirRatchetKey: peerRatchetKey
            )
        } else {
            ratchet = DoubleRatchetSession.initializeAsResponder(
                rootKey: rootKey,
                myRatchetKey: myRatchetPrivateKey
            )
        }

        return LocalSecureChannel(
            ratchet: ratchet,
            peerIdentityPublicKey: peerIdentityKey
        )
    }

    // MARK: - Encrypt / Decrypt

    /// Encrypt a plaintext payload (typically a serialized `PeerMessage`)
    /// into a wire frame. Each call advances the sender chain — repeated
    /// encryption of the same input produces different ciphertext.
    func encrypt(_ plaintext: Data) throws -> Data {
        let ratchetMessage = try ratchet.encrypt(plaintext)
        let frame = Frame(version: Frame.currentVersion, message: ratchetMessage)
        return try JSONEncoder().encode(frame)
    }

    /// Decrypt a wire frame back to its plaintext. Throws on:
    /// - malformed frame
    /// - unknown version
    /// - replay (DoubleRatchet's internal counter logic catches this)
    /// - corruption / wrong key (AES-GCM tag verification)
    func decrypt(_ frameData: Data) throws -> Data {
        let frame: Frame
        do {
            frame = try JSONDecoder().decode(Frame.self, from: frameData)
        } catch {
            throw ChannelError.decodeFailed
        }
        guard frame.version == Frame.currentVersion else {
            throw ChannelError.wrongVersion(frame.version)
        }
        return try ratchet.decrypt(frame.message)
    }

    // MARK: - Helpers

    /// Lexicographic byte comparison. -1 if a < b, 0 if equal, 1 if a > b.
    private static func lexCompare(_ a: [UInt8], _ b: [UInt8]) -> Int {
        for (x, y) in zip(a, b) {
            if x < y { return -1 }
            if x > y { return 1 }
        }
        if a.count < b.count { return -1 }
        if a.count > b.count { return 1 }
        return 0
    }
}
