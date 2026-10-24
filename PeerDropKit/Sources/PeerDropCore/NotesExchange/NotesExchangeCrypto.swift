import Foundation
import CryptoKit
import PeerDropAccount
import PeerDropProtocol

/// A value seen from one party's point of view: `mine` belongs to the local
/// party, `theirs` to the peer. Used for both handshake identity keys and the
/// per-connection intent nonces.
public struct NotesExchangePair: Equatable, Sendable {
    public let mine: Data
    public let theirs: Data
    public init(mine: Data, theirs: Data) {
        self.mine = mine
        self.theirs = theirs
    }
}

/// Reveal signature for the mutual notes-account exchange (spec §10.1).
///
/// Digest (all fields fixed length, so no length prefixes), ROLE-ORDERED:
///
///     SHA256( "peerdrop-notes-exchange-v1"
///           ‖ accountId               8 bytes, strict Crockford (AccountID(raw:))
///           ‖ revealerHandshakeKey   32 bytes
///           ‖ verifierHandshakeKey   32 bytes
///           ‖ revealerNonce          32 bytes
///           ‖ verifierNonce          32 bytes )
///
/// Nothing is sorted. The revealer signs with (keys.mine, keys.theirs,
/// nonces.mine, nonces.theirs); the verifier checks with (keys.theirs,
/// keys.mine, nonces.theirs, nonces.mine). Because the digest names who
/// revealed, a reveal reflected back to its signer does not verify, and a
/// reveal for one connection does not verify on another (different keys or
/// nonces).
///
/// Signing keys that are small-order Ed25519 points (`smallOrderSigningKeys`)
/// and the all-zero signature are rejected: with such a key a fixed signature
/// can verify for any message.
///
/// CM contract (Task 4):
/// - `makeReveal` and `verifyReveal` must be given the handshake keys of the
///   SAME `PeerConnection` the intents/reveal travel on (`handshakePeerIdentityKey`
///   for theirs, the local identity key for mine) and the nonces from the
///   session's action for that connection, never cached values.
/// - `verifyReveal` proves only key possession bound to this connection, and
///   runs first, offline. Nothing is persisted unless it passes. Then: if the
///   directory answers, bind only when `entry.accountId.raw == payload.accountId`,
///   `entry.identityKey == peer handshake key` and
///   `entry.signingKey == payload.signingKey`. If the directory is unreachable,
///   a pending binding may be persisted after the offline checks alone
///   (spec §10.7). It becomes a binding only after a later retry passes the
///   same three directory checks.
public enum NotesExchangeCrypto {

    public static let domain = Data("peerdrop-notes-exchange-v1".utf8)
    public static let accountIdLength = 8
    public static let keyLength = 32
    public static let nonceLength = 32
    public static let signingKeyLength = 32
    public static let signatureLength = 64

    public enum CryptoError: Error, Equatable {
        case invalidField
        case badSignature
    }

    /// The 14 encodings of small-order Ed25519 points (orders 1, 2, 4, 8):
    /// 8 canonical encodings plus 6 non-canonical ones (x = -0, and y ≥ p).
    /// Derived by decoding each candidate and checking 8·P = identity; the
    /// canonical order-8 values match libsodium's blocklist.
    public static let smallOrderSigningKeys: [Data] = [
        "0100000000000000000000000000000000000000000000000000000000000000",
        "ecffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff7f",
        "0000000000000000000000000000000000000000000000000000000000000000",
        "0000000000000000000000000000000000000000000000000000000000000080",
        "26e8958fc2b227b045c3f489f2ef98f0d5dfac05d3c63339b13802886d53fc05",
        "26e8958fc2b227b045c3f489f2ef98f0d5dfac05d3c63339b13802886d53fc85",
        "c7176a703d4dd84fba3c0b760d10670f2a2053fa2c39ccc64ec7fd7792ac037a",
        "c7176a703d4dd84fba3c0b760d10670f2a2053fa2c39ccc64ec7fd7792ac03fa",
        "0100000000000000000000000000000000000000000000000000000000000080",
        "ecffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff",
        "edffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff7f",
        "edffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff",
        "eeffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff7f",
        "eeffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff",
    ].map(hexData)

    private static func hexData(_ s: String) -> Data {
        var d = Data(capacity: s.count / 2)
        var i = s.startIndex
        while i < s.endIndex {
            let j = s.index(i, offsetBy: 2)
            d.append(UInt8(s[i..<j], radix: 16)!)
            i = j
        }
        return d
    }

    /// 32 bytes and not a small-order point.
    static func isAcceptableSigningKey(_ key: Data) -> Bool {
        key.count == signingKeyLength && !smallOrderSigningKeys.contains(key)
    }

    /// 64 bytes and not all zero.
    static func isAcceptableSignature(_ sig: Data) -> Bool {
        sig.count == signatureLength && sig.contains(where: { $0 != 0 })
    }

    /// Strict account-id check shared with the session: exactly 8 uppercase
    /// Crockford base32 ASCII characters (lowercase / lenient forms rejected).
    static func isValidAccountId(_ s: String) -> Bool {
        guard s.utf8.count == accountIdLength, let id = AccountID(raw: s) else { return false }
        return id.raw == s
    }

    /// Returns nil when any field has the wrong size/shape or both keys are equal.
    public static func revealDigest(accountId: String,
                                    revealerKey: Data, verifierKey: Data,
                                    revealerNonce: Data, verifierNonce: Data) -> Data? {
        guard isValidAccountId(accountId),
              revealerKey.count == keyLength, verifierKey.count == keyLength,
              revealerNonce.count == nonceLength, verifierNonce.count == nonceLength,
              revealerKey != verifierKey
        else { return nil }
        var m = domain
        m.append(Data(accountId.utf8))
        m.append(revealerKey)
        m.append(verifierKey)
        m.append(revealerNonce)
        m.append(verifierNonce)
        return Data(SHA256.hash(data: m))
    }

    /// 32 bytes from the system CSPRNG.
    public static func makeNonce() -> Data {
        var rng = SystemRandomNumberGenerator()
        return makeNonce(using: &rng)
    }

    /// 32 bytes from an injected generator (tests). Production uses `makeNonce()`.
    public static func makeNonce<R: RandomNumberGenerator>(using rng: inout R) -> Data {
        var out = Data(capacity: nonceLength)
        for _ in 0..<(nonceLength / 8) {
            var v = rng.next().littleEndian
            withUnsafeBytes(of: &v) { out.append(contentsOf: $0) }
        }
        return out
    }

    /// Builds the local reveal. `handshakeKeys`/`nonces` are from the local
    /// party's view. `signer` must sign with the account's Ed25519 signing key
    /// (production: `IdentityKeyManager.shared.sign`); its output is checked
    /// against `account.signingKey` before anything is sent.
    public static func makeReveal(account: NotesExchangeSession.AccountSnapshot,
                                  handshakeKeys: NotesExchangePair,
                                  nonces: NotesExchangePair,
                                  signer: (Data) throws -> Data) throws -> NotesExchangePayload {
        guard isAcceptableSigningKey(account.signingKey),
              let digest = revealDigest(accountId: account.accountId,
                                        revealerKey: handshakeKeys.mine, verifierKey: handshakeKeys.theirs,
                                        revealerNonce: nonces.mine, verifierNonce: nonces.theirs)
        else { throw CryptoError.invalidField }
        let signature = try signer(digest)
        guard isAcceptableSignature(signature),
              let pub = try? Curve25519.Signing.PublicKey(rawRepresentation: account.signingKey),
              pub.isValidSignature(signature, for: digest)
        else { throw CryptoError.badSignature }
        return NotesExchangePayload(phase: NotesExchangePhase.reveal.rawValue,
                                    accountId: account.accountId,
                                    signingKey: account.signingKey,
                                    signature: signature)
    }

    /// Verifies a reveal received from the peer. `handshakeKeys`/`nonces` are
    /// from the LOCAL party's view (`theirs` = the revealer). Nonces must be the
    /// CURRENT connection's intent nonces. This proves only that the revealer
    /// holds `signingKey` and bound it to this connection; the caller must still
    /// check the directory entry (accountId, identityKey, signingKey).
    public static func verifyReveal(payload: NotesExchangePayload,
                                    handshakeKeys: NotesExchangePair,
                                    nonces: NotesExchangePair) -> Bool {
        guard payload.phase == NotesExchangePhase.reveal.rawValue,
              let accountId = payload.accountId,
              let signingKey = payload.signingKey, isAcceptableSigningKey(signingKey),
              let signature = payload.signature, isAcceptableSignature(signature),
              let digest = revealDigest(accountId: accountId,
                                        revealerKey: handshakeKeys.theirs, verifierKey: handshakeKeys.mine,
                                        revealerNonce: nonces.theirs, verifierNonce: nonces.mine),
              let pub = try? Curve25519.Signing.PublicKey(rawRepresentation: signingKey)
        else { return false }
        return pub.isValidSignature(signature, for: digest)
    }
}
