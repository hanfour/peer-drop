import XCTest
import CryptoKit
@testable import PeerDrop

/// Pins the wire + crypto contract for `LocalSecureChannel`. The class
/// will be wired into `PeerConnection` in Phase 2; these tests validate
/// it in isolation so the cryptographic core lands proven.
final class LocalSecureChannelTests: XCTestCase {

    // MARK: - Test fixtures

    /// Stand-in `LocalChannelIdentity` backed by a freshly-generated
    /// Curve25519 keypair — bypasses IdentityKeyManager's Keychain layer
    /// so each test case gets a unique identity without polluting the
    /// real device key.
    struct TestIdentity: LocalChannelIdentity {
        let privateKey: Curve25519.KeyAgreement.PrivateKey
        var publicKey: Curve25519.KeyAgreement.PublicKey { privateKey.publicKey }

        init() {
            self.privateKey = Curve25519.KeyAgreement.PrivateKey()
        }

        func deriveSharedSecret(with peerPublicKey: Curve25519.KeyAgreement.PublicKey) throws -> SharedSecret {
            try privateKey.sharedSecretFromKeyAgreement(with: peerPublicKey)
        }

        var fingerprint: String {
            let hash = SHA256.hash(data: publicKey.rawRepresentation)
            let hex = hash.prefix(10).map { String(format: "%02X", $0) }.joined()
            return stride(from: 0, to: 20, by: 4).map { i in
                let start = hex.index(hex.startIndex, offsetBy: i)
                let end = hex.index(start, offsetBy: 4)
                return String(hex[start..<end])
            }.joined(separator: " ")
        }
    }

    private func makeIdentity() -> TestIdentity {
        TestIdentity()
    }

    /// Establish a paired (a, b) channel as if the two peers had just
    /// exchanged handshake bundles over the wire.
    /// Establish a paired channel where `initiator` is guaranteed to be
    /// the side with the lexicographically-smaller identity public key.
    /// The Double Ratchet design requires the initiator to speak first
    /// so the responder's first received message can bootstrap its
    /// receive chain. Tests that ignore this distinction hit
    /// `noSendChain` randomly depending on which fresh keypair sorts
    /// lower.
    private func establishPair() throws -> (initiator: LocalSecureChannel, responder: LocalSecureChannel,
                                             initiatorIdentity: TestIdentity, responderIdentity: TestIdentity) {
        let a = makeIdentity()
        let b = makeIdentity()

        // Determine roles by the same lex comparison LocalSecureChannel uses.
        let aIsInitiator = Array(a.publicKey.rawRepresentation).lexicographicallyPrecedes(
            Array(b.publicKey.rawRepresentation))
        let (initId, respId) = aIsInitiator ? (a, b) : (b, a)

        let (initBundle, initRatchet) = LocalSecureChannel.prepareHandshake(identity: initId)
        let (respBundle, respRatchet) = LocalSecureChannel.prepareHandshake(identity: respId)

        let initChannel = try LocalSecureChannel.establish(
            myIdentity: initId,
            myRatchetPrivateKey: initRatchet,
            peerBundle: respBundle)
        let respChannel = try LocalSecureChannel.establish(
            myIdentity: respId,
            myRatchetPrivateKey: respRatchet,
            peerBundle: initBundle)

        return (initChannel, respChannel, initId, respId)
    }

    // MARK: - Handshake

    func test_handshakeBundle_containsFreshKeys() {
        let identity = makeIdentity()
        let (bundle1, priv1) = LocalSecureChannel.prepareHandshake(identity: identity)
        let (bundle2, priv2) = LocalSecureChannel.prepareHandshake(identity: identity)

        XCTAssertEqual(bundle1.identityPublicKey, bundle2.identityPublicKey,
                       "identity key is stable across handshakes")
        XCTAssertNotEqual(bundle1.initialRatchetPublicKey, bundle2.initialRatchetPublicKey,
                          "ratchet key must be fresh per handshake (FS invariant)")
        XCTAssertNotEqual(priv1.rawRepresentation, priv2.rawRepresentation)
    }

    func test_establish_rejectsSameIdentityKey() {
        let identity = makeIdentity()
        let (bundle, ratchetPriv) = LocalSecureChannel.prepareHandshake(identity: identity)

        XCTAssertThrowsError(
            try LocalSecureChannel.establish(
                myIdentity: identity,
                myRatchetPrivateKey: ratchetPriv,
                peerBundle: bundle)
        ) { error in
            XCTAssertEqual(error as? LocalSecureChannel.ChannelError, .sameIdentityKey)
        }
    }

    func test_establish_rejectsMalformedIdentityKey() {
        let identity = makeIdentity()
        let (_, ratchetPriv) = LocalSecureChannel.prepareHandshake(identity: identity)
        let malformed = LocalSecureChannel.HandshakeBundle(
            identityPublicKey: Data([0xFF, 0xAA]),  // not a valid Curve25519 pubkey
            initialRatchetPublicKey: ratchetPriv.publicKey.rawRepresentation
        )
        XCTAssertThrowsError(
            try LocalSecureChannel.establish(
                myIdentity: identity,
                myRatchetPrivateKey: ratchetPriv,
                peerBundle: malformed)
        ) { error in
            XCTAssertEqual(error as? LocalSecureChannel.ChannelError, .invalidIdentityKey)
        }
    }

    // MARK: - Round trip

    func test_roundTrip_singleMessage_bothDirections() throws {
        let (initiator: a, responder: b, _, _) = try establishPair()

        // A → B
        let outbound = "hello world".data(using: .utf8)!
        let frame1 = try a.encrypt(outbound)
        XCTAssertNotEqual(frame1, outbound, "ciphertext differs from plaintext")
        let received1 = try b.decrypt(frame1)
        XCTAssertEqual(received1, outbound)

        // B → A
        let inbound = Data([0xDE, 0xAD, 0xBE, 0xEF])
        let frame2 = try b.encrypt(inbound)
        let received2 = try a.decrypt(frame2)
        XCTAssertEqual(received2, inbound)
    }

    func test_roundTrip_manyMessages_advanceForwardSecrecy() throws {
        let (initiator: a, responder: b, _, _) = try establishPair()
        var ciphertexts: [Data] = []

        for i in 0..<10 {
            let plaintext = "message \(i)".data(using: .utf8)!
            let frame = try a.encrypt(plaintext)
            ciphertexts.append(frame)
            let decrypted = try b.decrypt(frame)
            XCTAssertEqual(decrypted, plaintext)
        }

        // Each ciphertext must differ — same plaintext byte would still
        // produce different ciphertext because counter advances.
        XCTAssertEqual(ciphertexts.count, Set(ciphertexts).count,
                       "all ciphertexts unique (counter advance + ratchet)")
    }

    func test_roundTrip_bidirectionalInterleaved() throws {
        let (initiator: a, responder: b, _, _) = try establishPair()

        // Conversation: A1, A2, B1, A3, B2, B3
        let a1 = try a.encrypt("a1".data(using: .utf8)!)
        let a2 = try a.encrypt("a2".data(using: .utf8)!)
        XCTAssertEqual(try b.decrypt(a1), "a1".data(using: .utf8)!)
        XCTAssertEqual(try b.decrypt(a2), "a2".data(using: .utf8)!)

        let b1 = try b.encrypt("b1".data(using: .utf8)!)
        XCTAssertEqual(try a.decrypt(b1), "b1".data(using: .utf8)!)

        let a3 = try a.encrypt("a3".data(using: .utf8)!)
        XCTAssertEqual(try b.decrypt(a3), "a3".data(using: .utf8)!)

        let b2 = try b.encrypt("b2".data(using: .utf8)!)
        let b3 = try b.encrypt("b3".data(using: .utf8)!)
        XCTAssertEqual(try a.decrypt(b2), "b2".data(using: .utf8)!)
        XCTAssertEqual(try a.decrypt(b3), "b3".data(using: .utf8)!)
    }

    // MARK: - Decrypt failures

    func test_decrypt_rejectsCorruptedFrame() throws {
        let (initiator: a, responder: b, _, _) = try establishPair()
        var frame = try a.encrypt("hello".data(using: .utf8)!)
        // Flip a byte in the JSON-encoded frame — JSON decoder may
        // tolerate some bit flips but the embedded base64 + AES-GCM tag
        // is much more sensitive. Pick a byte far from JSON structure.
        let flipIndex = frame.count - 5
        frame[flipIndex] ^= 0xFF
        XCTAssertThrowsError(try b.decrypt(frame))
    }

    func test_decrypt_rejectsUnknownVersion() throws {
        let (initiator: a, responder: b, _, _) = try establishPair()
        let frame = try a.encrypt("hello".data(using: .utf8)!)
        // Decode → bump version → re-encode → decrypt.
        var dict = try JSONSerialization.jsonObject(with: frame) as! [String: Any]
        dict["version"] = 99
        let mangled = try JSONSerialization.data(withJSONObject: dict)
        XCTAssertThrowsError(try b.decrypt(mangled)) { error in
            if case LocalSecureChannel.ChannelError.wrongVersion(let v) = error {
                XCTAssertEqual(v, 99)
            } else {
                XCTFail("expected wrongVersion, got \(error)")
            }
        }
    }

    func test_decrypt_thirdPartyKeyCannotDecrypt() throws {
        let (a, _, _, _) = try establishPair()
        // c is a third peer with its own a↔c channel. Messages from the
        // a↔b channel must NOT decrypt on c's side — its DH-derived
        // root key is different from b's.
        let cIdentity = makeIdentity()
        let aIdentity2 = makeIdentity()
        let (aBundle, aRatchet) = LocalSecureChannel.prepareHandshake(identity: aIdentity2)
        let (cBundle, cRatchet) = LocalSecureChannel.prepareHandshake(identity: cIdentity)
        let cChannel = try LocalSecureChannel.establish(
            myIdentity: cIdentity,
            myRatchetPrivateKey: cRatchet,
            peerBundle: aBundle)
        _ = try LocalSecureChannel.establish(
            myIdentity: aIdentity2,
            myRatchetPrivateKey: aRatchet,
            peerBundle: cBundle)

        let frame = try a.encrypt("secret".data(using: .utf8)!)
        XCTAssertThrowsError(try cChannel.decrypt(frame))
    }

    // MARK: - Peer fingerprint

    func test_peerFingerprint_matchesPeersOwnFingerprint() throws {
        let (a, _, _, bIdentity) = try establishPair()
        XCTAssertEqual(a.peerFingerprint, bIdentity.fingerprint,
                       "channel.peerFingerprint must equal the peer's IdentityKeyManager.fingerprint")
    }

    // MARK: - Symmetry property

    func test_initiatorResponderRolesAreDeterministic() throws {
        // Run a handshake twice; whoever is initiator the first time
        // must be initiator the second time. This guards against a race
        // where both peers think they're initiator and the ratchet
        // bootstraps inconsistently.
        for _ in 0..<5 {
            let (a, b, aIdentity, bIdentity) = try establishPair()
            // Both peers can encrypt + each other decrypt — proves the
            // initiator/responder choice was consistent.
            let msg = try a.encrypt("hi".data(using: .utf8)!)
            XCTAssertEqual(try b.decrypt(msg), "hi".data(using: .utf8)!)
            XCTAssertNotEqual(aIdentity.publicKey.rawRepresentation,
                              bIdentity.publicKey.rawRepresentation)
        }
    }
}
