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
/// Digest (all fields fixed length, so no length prefixes):
///
///     SHA256( "peerdrop-notes-exchange-v1"
///           ‖ accountId              8 bytes, strict Crockford (AccountID(raw:))
///           ‖ smallerHandshakeKey   32 bytes
///           ‖ largerHandshakeKey    32 bytes
///           ‖ nonce of smaller-key owner  32 bytes
///           ‖ nonce of larger-key owner   32 bytes )
///
/// The two X25519 handshake identity keys are ordered lexicographically as raw
/// bytes. **Nonces are NOT sorted by their own value**: each nonce travels with
/// the key of the party that produced it (in its `intent`), so the first nonce
/// is always the one sent by the owner of the smaller key. Both peers therefore
/// compute the same digest from their own (mine, theirs) views, while a nonce
/// can never be attributed to the other party.
///
/// The digest is symmetric, so it does not say WHO revealed; a peer echoing our
/// own reveal back would verify. `NotesExchangeSession` rejects reveals carrying
/// our own accountId/signingKey, and binding additionally requires the
/// directory `identityKey` to equal the peer's handshake key.
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

    /// Strict account-id check shared with the session: exactly 8 uppercase
    /// Crockford base32 ASCII characters (lowercase / lenient forms rejected).
    static func isValidAccountId(_ s: String) -> Bool {
        guard s.utf8.count == accountIdLength, let id = AccountID(raw: s) else { return false }
        return id.raw == s
    }

    /// Returns nil when any field has the wrong size/shape or both keys are equal.
    /// `nonceA` must be the nonce produced by the owner of `keyA` (and B likewise).
    public static func revealDigest(accountId: String, keyA: Data, keyB: Data,
                                    nonceA: Data, nonceB: Data) -> Data? {
        guard isValidAccountId(accountId),
              keyA.count == keyLength, keyB.count == keyLength,
              nonceA.count == nonceLength, nonceB.count == nonceLength,
              keyA != keyB
        else { return nil }
        let aFirst = keyA.lexicographicallyPrecedes(keyB)
        var m = domain
        m.append(Data(accountId.utf8))
        m.append(aFirst ? keyA : keyB)
        m.append(aFirst ? keyB : keyA)
        m.append(aFirst ? nonceA : nonceB)
        m.append(aFirst ? nonceB : nonceA)
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
        guard let digest = revealDigest(accountId: account.accountId,
                                        keyA: handshakeKeys.mine, keyB: handshakeKeys.theirs,
                                        nonceA: nonces.mine, nonceB: nonces.theirs)
        else { throw CryptoError.invalidField }
        let signature = try signer(digest)
        guard signature.count == signatureLength,
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
              let signingKey = payload.signingKey, signingKey.count == signingKeyLength,
              let signature = payload.signature, signature.count == signatureLength,
              let digest = revealDigest(accountId: accountId,
                                        keyA: handshakeKeys.theirs, keyB: handshakeKeys.mine,
                                        nonceA: nonces.theirs, nonceB: nonces.mine),
              let pub = try? Curve25519.Signing.PublicKey(rawRepresentation: signingKey)
        else { return false }
        return pub.isValidSignature(signature, for: digest)
    }
}
