import Foundation
import CryptoKit
import PeerDropSecurity

// Project E — rendezvous ("碰面代號") primitives. Pure and deterministic: the
// clock, the randomness and the static DH are all injected; nothing here reads
// the keychain, the network or writes logs. NEVER log a token, a signaling key
// or a session tag (privacy contract, plan Global Constraints).

public enum RendezvousCryptoError: Error, Equatable {
    /// An agreement public key was not exactly 32 raw bytes.
    case invalidPublicKeyLength
    /// Both public keys are identical (MITM, reflection, or a bug).
    case identicalPublicKeys
    /// The DH output was all zeros (low-order peer point) or empty.
    case degenerateSharedSecret
    /// Day / hour index must be non-negative.
    case invalidEpoch
    /// A token was not exactly 32 bytes.
    case invalidTokenLength
}

// MARK: - Injection points

/// Supplies the static X25519 DH with a friend. `peerKey` must be the friend's
/// X25519 AGREEMENT key (`TrustedContact.identityPublicKey`) — never an
/// Ed25519 signing key. Production uses
/// `IdentityRendezvousSecretProvider` (backed by `IdentityKeyManager.shared`);
/// tests use in-memory keys so the keychain is never touched.
public protocol RendezvousSecretProvider {
    /// Our long-term X25519 agreement public key, 32 raw bytes.
    var localAgreementPublicKey: Data { get }
    /// Raw static DH output with `peerKey` (32 raw bytes), as HKDF input key material.
    func sharedSecret(withPeerAgreementKey peerKey: Data) throws -> SymmetricKey
}

/// Real provider: the same identity key and static DH as `LocalSecureChannel`
/// (domain-separated by a distinct HKDF salt).
public struct IdentityRendezvousSecretProvider: RendezvousSecretProvider {
    private let identity: LocalChannelIdentity

    public init(identity: LocalChannelIdentity = IdentityKeyManager.shared) {
        self.identity = identity
    }

    public var localAgreementPublicKey: Data { identity.publicKey.rawRepresentation }

    public func sharedSecret(withPeerAgreementKey peerKey: Data) throws -> SymmetricKey {
        guard peerKey.count == 32 else { throw RendezvousCryptoError.invalidPublicKeyLength }
        guard peerKey != localAgreementPublicKey else { throw RendezvousCryptoError.identicalPublicKeys }
        let peer = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: peerKey)
        let shared = try identity.deriveSharedSecret(with: peer)
        return shared.withUnsafeBytes { SymmetricKey(data: Data($0)) }
    }
}

/// Randomness source (injectable for deterministic tests).
public protocol RendezvousRandomSource: AnyObject {
    func randomBytes(count: Int) -> Data
}

/// CSPRNG-backed source (`SystemRandomNumberGenerator` is cryptographically
/// secure on Apple platforms).
public final class SystemRendezvousRandom: RendezvousRandomSource {
    public static let shared = SystemRendezvousRandom()
    public init() {}
    public func randomBytes(count: Int) -> Data {
        var rng = SystemRandomNumberGenerator()
        return Data((0..<count).map { _ in UInt8.random(in: .min ... .max, using: &rng) })
    }
}

// MARK: - Pair ordering shared by token and signaling key

public enum RendezvousKeyOrder {
    static func validate(myKey: Data, peerKey: Data) throws {
        guard myKey.count == 32, peerKey.count == 32 else { throw RendezvousCryptoError.invalidPublicKeyLength }
        guard myKey != peerKey else { throw RendezvousCryptoError.identicalPublicKeys }
    }

    /// True when our key sorts first in raw-byte lexicographic order.
    public static func isLocalSmaller(myKey: Data, peerKey: Data) throws -> Bool {
        try validate(myKey: myKey, peerKey: peerKey)
        return myKey.lexicographicallyPrecedes(peerKey)
    }

    /// HKDF info = min(pubA,pubB) ‖ max(pubA,pubB) ‖ UInt64BE(day) — 72 bytes.
    public static func pairInfo(myKey: Data, peerKey: Data, day: Int) throws -> Data {
        guard day >= 0 else { throw RendezvousCryptoError.invalidEpoch }
        let smaller = try isLocalSmaller(myKey: myKey, peerKey: peerKey)
        var info = Data(smaller ? myKey : peerKey)
        info.append(smaller ? peerKey : myKey)
        info.append(bigEndian8(UInt64(day)))
        return info
    }

    static func derive(sharedSecret: SymmetricKey, salt: String, myKey: Data, peerKey: Data, day: Int) throws -> SymmetricKey {
        let info = try pairInfo(myKey: myKey, peerKey: peerKey, day: day)
        let isDegenerate = sharedSecret.withUnsafeBytes { raw in raw.isEmpty || raw.allSatisfy { $0 == 0 } }
        guard !isDegenerate else { throw RendezvousCryptoError.degenerateSharedSecret }
        return HKDF<SHA256>.deriveKey(
            inputKeyMaterial: sharedSecret,
            salt: Data(salt.utf8),
            info: info,
            outputByteCount: 32
        )
    }
}

@inline(__always)
func bigEndian8(_ v: UInt64) -> Data {
    withUnsafeBytes(of: v.bigEndian) { Data($0) }
}

// MARK: - Token

/// Daily rendezvous token: only the two holders of the static DH can compute it.
///
/// `token = HKDF<SHA256>(ikm: DH, salt: "peerdrop-rv-v1",
///                       info: min(pubA,pubB) ‖ max(pubA,pubB) ‖ UInt64BE(day), L: 32)`,
/// `day = floor(unixSeconds / 86400)` (UTC).
public enum RendezvousToken {
    public static let salt = "peerdrop-rv-v1"
    public static let byteCount = 32
    public static let secondsPerDay = 86_400
    /// Join the adjacent day's token within this many seconds of UTC midnight.
    public static let boundaryWindowSeconds = 600

    public static func day(at date: Date) -> Int {
        Int((date.timeIntervalSince1970 / Double(secondsPerDay)).rounded(.down))
    }

    public static func token(sharedSecret: SymmetricKey, myKey: Data, peerKey: Data, day: Int) throws -> Data {
        try RendezvousKeyOrder.derive(sharedSecret: sharedSecret, salt: salt, myKey: myKey, peerKey: peerKey, day: day)
            .withUnsafeBytes { Data($0) }
    }

    public static func token(provider: RendezvousSecretProvider, peerKey: Data, day: Int) throws -> Data {
        let myKey = provider.localAgreementPublicKey
        try RendezvousKeyOrder.validate(myKey: myKey, peerKey: peerKey)
        return try token(sharedSecret: provider.sharedSecret(withPeerAgreementKey: peerKey),
                         myKey: myKey, peerKey: peerKey, day: day)
    }

    /// Days whose token should be joined at `now`, ascending.
    ///
    /// Boundary rule (exact): with `D = day(now)`, `M = D·86400`:
    /// - previous day `D−1` is also joined while `now < M + 600` (and `D > 0`);
    /// - next day `D+1` is also joined once `now ≥ M + 86400 − 600`.
    /// Two clocks up to ±10 min apart therefore always share at least one token.
    public static func daysToJoin(now: Date) -> [Int] {
        let t = now.timeIntervalSince1970
        let d = day(at: now)
        guard d >= 0 else { return [] }
        let midnight = Double(d) * Double(secondsPerDay)
        var days = [d]
        if d > 0, t < midnight + Double(boundaryWindowSeconds) {
            days.insert(d - 1, at: 0)
        }
        if t >= midnight + Double(secondsPerDay - boundaryWindowSeconds) {
            days.append(d + 1)
        }
        return days
    }

    public static func tokensToJoin(
        now: Date, provider: RendezvousSecretProvider, peerKey: Data
    ) throws -> [(day: Int, token: Data)] {
        try daysToJoin(now: now).map { ($0, try token(provider: provider, peerKey: peerKey, day: $0)) }
    }

    /// Canonical base64url (no padding) — 43 chars for a 32-byte token; the
    /// exact spelling the Worker's canonical check accepts.
    public static func encoded(_ token: Data) throws -> String {
        guard token.count == byteCount else { throw RendezvousCryptoError.invalidTokenLength }
        return encodeBase64URL(token)
    }

    /// Strict inverse of `encoded(_:)`: nil for any non-canonical spelling.
    public static func decodeCanonical(_ s: String) -> Data? {
        decodeBase64URL(s, expectedLength: byteCount)
    }

    // MARK: base64url helpers (shared by the rendezvous files)

    static func encodeBase64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    /// Mirrors the Worker's `decodeBase64UrlStrict` + re-encode equality check.
    static func decodeBase64URL(_ s: String, expectedLength: Int) -> Data? {
        guard !s.isEmpty, s.utf8.allSatisfy({ c in
            (c >= 0x41 && c <= 0x5A) || (c >= 0x61 && c <= 0x7A) || (c >= 0x30 && c <= 0x39) || c == 0x2D || c == 0x5F
        }) else { return nil }
        guard s.utf8.count % 4 != 1 else { return nil }
        var b64 = s.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        b64 += String(repeating: "=", count: (4 - b64.utf8.count % 4) % 4)
        guard let data = Data(base64Encoded: b64), data.count == expectedLength,
              encodeBase64URL(data) == s else { return nil }
        return data
    }
}
