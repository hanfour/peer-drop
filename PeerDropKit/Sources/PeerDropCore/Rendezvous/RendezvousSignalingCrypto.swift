import Foundation
import CryptoKit

// Project E — signaling AEAD for SDP/ICE relayed through the (untrusted)
// rendezvous room. Purpose: keep IPs and DTLS fingerprints from the operator
// and stop it from injecting or replaying signaling. It is NOT peer
// authentication — that is the pinned-key LocalSecureChannel handshake on the
// data channel (spec §12.5).
//
// Wire format of a sealed frame (binary; the transport layer wraps it):
//     counter (UInt64 BE, 8) ‖ ChaCha20-Poly1305 ciphertext ‖ tag (16)
// Nonce (12) = UInt32BE(direction) ‖ UInt64BE(counter)
//     direction 0x01 = party with the lexicographically smaller key, 0x02 = other.
// AAD = "rv-sig-v1" ‖ UInt64BE(day) ‖ sessionID (16) ‖ direction byte of the SENDER.
// Key = HKDF<SHA256>(DH, salt "peerdrop-rv-signal-v1", info = token info layout).
//
// Session binding / replay (decision):
//   Each side sends one plaintext hello `{"t":"hello","r":"<8 random bytes b64url>"}`
//   per handshake. sessionID = r(smaller-key party) ‖ r(larger-key party). A
//   receiver only ever opens frames under the sessionID formed from ITS OWN
//   fresh r for this handshake plus the peer r it saw, so anything sealed in
//   an earlier session (an operator replaying an old offer, even together with
//   the old hello) fails AEAD. A hello equal to our own r is rejected as a
//   reflection. A replayed old hello therefore can only make the handshake fail
//   (denial of service), never inject signaling. Within a session the receive
//   counter must strictly increase (gaps allowed, repeats/regressions refused).
//   A handshake accepts exactly one peer hello; on a new 'joined' or any later
//   hello the caller must discard the cipher and start a NEW handshake (new r).

public enum RendezvousSignalingError: Error, Equatable {
    case invalidHello
    case reflectedHello
    case handshakeAlreadyCompleted
    case invalidSessionID
    case frameTooShort
    case invalidCounter
    case replayedOrStaleCounter
    case authenticationFailed
    case sendCounterExhausted
}

public enum RendezvousDirection: UInt8 {
    case smallerKey = 0x01
    case largerKey = 0x02

    public var peer: RendezvousDirection { self == .smallerKey ? .largerKey : .smallerKey }
}

public enum RendezvousSignalingCrypto {
    public static let salt = "peerdrop-rv-signal-v1"
    public static let aadLabel = "rv-sig-v1"
    public static let sessionIDLength = 16
    public static let contributionLength = 8
    static let counterLength = 8
    static let tagLength = 16

    public static func signalingKey(sharedSecret: SymmetricKey, myKey: Data, peerKey: Data, day: Int) throws -> SymmetricKey {
        try RendezvousKeyOrder.derive(sharedSecret: sharedSecret, salt: salt, myKey: myKey, peerKey: peerKey, day: day)
    }

    public static func signalingKey(provider: RendezvousSecretProvider, peerKey: Data, day: Int) throws -> SymmetricKey {
        let myKey = provider.localAgreementPublicKey
        try RendezvousKeyOrder.validate(myKey: myKey, peerKey: peerKey)
        return try signalingKey(sharedSecret: provider.sharedSecret(withPeerAgreementKey: peerKey),
                                myKey: myKey, peerKey: peerKey, day: day)
    }

    public static func localDirection(myKey: Data, peerKey: Data) throws -> RendezvousDirection {
        try RendezvousKeyOrder.isLocalSmaller(myKey: myKey, peerKey: peerKey) ? .smallerKey : .largerKey
    }

    static func nonceBytes(direction: RendezvousDirection, counter: UInt64) -> Data {
        Data([0, 0, 0, direction.rawValue]) + bigEndian8(counter)
    }

    static func aad(day: Int, sessionID: Data, direction: RendezvousDirection) -> Data {
        var d = Data(aadLabel.utf8)
        d.append(bigEndian8(UInt64(max(day, 0))))
        d.append(sessionID)
        d.append(direction.rawValue)
        return d
    }

    /// sessionID = smaller-key party's contribution ‖ larger-key party's contribution.
    static func sessionID(local: Data, peer: Data, localDirection: RendezvousDirection) -> Data {
        localDirection == .smallerKey ? local + peer : peer + local
    }
}

// MARK: - Hello frame

public enum RendezvousHello {
    /// Compact JSON hello. Plaintext by design: the operator learns 8 random bytes.
    public static func frame(contribution: Data) -> String {
        #"{"t":"hello","r":""# + RendezvousToken.encodeBase64URL(contribution) + #""}"#
    }

    /// Returns the 8-byte contribution or nil for anything that is not a
    /// well-formed hello with a canonical base64url `r`.
    public static func parse(_ text: String) -> Data? {
        guard text.utf8.count <= 128,
              let obj = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any],
              obj["t"] as? String == "hello",
              let r = obj["r"] as? String else { return nil }
        return RendezvousToken.decodeBase64URL(r, expectedLength: RendezvousSignalingCrypto.contributionLength)
    }
}

/// One handshake per peer join. Generates our fresh contribution once and
/// turns exactly one peer hello into a cipher bound to this session.
public final class RendezvousSignalingHandshake {
    public let day: Int
    public let helloFrame: String
    private let key: SymmetricKey
    private let localDirection: RendezvousDirection
    private let localContribution: Data
    private let lock = NSLock()
    private var completed = false

    public init(
        provider: RendezvousSecretProvider,
        peerKey: Data,
        day: Int,
        random: RendezvousRandomSource = SystemRendezvousRandom.shared
    ) throws {
        self.day = day
        self.key = try RendezvousSignalingCrypto.signalingKey(provider: provider, peerKey: peerKey, day: day)
        self.localDirection = try RendezvousSignalingCrypto.localDirection(
            myKey: provider.localAgreementPublicKey, peerKey: peerKey)
        let contribution = random.randomBytes(count: RendezvousSignalingCrypto.contributionLength)
        guard contribution.count == RendezvousSignalingCrypto.contributionLength else {
            throw RendezvousSignalingError.invalidSessionID
        }
        self.localContribution = contribution
        self.helloFrame = RendezvousHello.frame(contribution: contribution)
    }

    public func accept(peerHelloFrame: String) throws -> RendezvousSignalingCipher {
        lock.lock(); defer { lock.unlock() }
        guard !completed else { throw RendezvousSignalingError.handshakeAlreadyCompleted }
        guard let peer = RendezvousHello.parse(peerHelloFrame) else { throw RendezvousSignalingError.invalidHello }
        guard peer != localContribution else { throw RendezvousSignalingError.reflectedHello }
        completed = true
        let sid = RendezvousSignalingCrypto.sessionID(local: localContribution, peer: peer, localDirection: localDirection)
        return try RendezvousSignalingCipher(key: key, localDirection: localDirection, day: day, sessionID: sid)
    }
}

// MARK: - Cipher

/// Session-bound AEAD. A reference type on purpose: a copied value type could
/// seal twice with the same counter (nonce reuse breaks ChaCha20-Poly1305).
public final class RendezvousSignalingCipher: @unchecked Sendable {
    public let day: Int
    public let sessionID: Data
    public let localDirection: RendezvousDirection
    private let key: SymmetricKey
    private let lock = NSLock()
    private var nextSendCounter: UInt64
    private var lastReceivedCounter: UInt64?

    /// `initialSendCounter` exists for overflow tests only.
    init(key: SymmetricKey, localDirection: RendezvousDirection, day: Int, sessionID: Data,
         initialSendCounter: UInt64 = 0) throws {
        guard sessionID.count == RendezvousSignalingCrypto.sessionIDLength else {
            throw RendezvousSignalingError.invalidSessionID
        }
        guard day >= 0 else { throw RendezvousCryptoError.invalidEpoch }
        self.key = key
        self.localDirection = localDirection
        self.day = day
        self.sessionID = sessionID
        self.nextSendCounter = initialSendCounter
    }

    /// Seals with the next counter. Counters run 0 … UInt64.max − 1; once
    /// exhausted the cipher refuses to seal (never wraps).
    public func seal(_ plaintext: Data) throws -> Data {
        lock.lock(); defer { lock.unlock() }
        let counter = nextSendCounter
        guard counter < UInt64.max else { throw RendezvousSignalingError.sendCounterExhausted }
        let nonce = try ChaChaPoly.Nonce(data: RendezvousSignalingCrypto.nonceBytes(direction: localDirection, counter: counter))
        let box = try ChaChaPoly.seal(
            plaintext, using: key, nonce: nonce,
            authenticating: RendezvousSignalingCrypto.aad(day: day, sessionID: sessionID, direction: localDirection))
        nextSendCounter = counter + 1
        return bigEndian8(counter) + box.ciphertext + box.tag
    }

    /// Opens a peer frame. State advances only after successful authentication.
    public func open(_ wire: Data) throws -> Data {
        lock.lock(); defer { lock.unlock() }
        let bytes = Data(wire)  // re-base indices
        guard bytes.count >= RendezvousSignalingCrypto.counterLength + RendezvousSignalingCrypto.tagLength else {
            throw RendezvousSignalingError.frameTooShort
        }
        let counter = bytes.prefix(8).reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
        guard counter < UInt64.max else { throw RendezvousSignalingError.invalidCounter }
        if let last = lastReceivedCounter, counter <= last {
            throw RendezvousSignalingError.replayedOrStaleCounter
        }
        let peerDirection = localDirection.peer
        let body = bytes.dropFirst(8)
        let plaintext: Data
        do {
            let nonce = try ChaChaPoly.Nonce(data: RendezvousSignalingCrypto.nonceBytes(direction: peerDirection, counter: counter))
            let box = try ChaChaPoly.SealedBox(
                nonce: nonce,
                ciphertext: body.dropLast(RendezvousSignalingCrypto.tagLength),
                tag: body.suffix(RendezvousSignalingCrypto.tagLength))
            plaintext = try ChaChaPoly.open(
                box, using: key,
                authenticating: RendezvousSignalingCrypto.aad(day: day, sessionID: sessionID, direction: peerDirection))
        } catch {
            throw RendezvousSignalingError.authenticationFailed
        }
        lastReceivedCounter = counter
        return plaintext
    }
}
