import Foundation
import CryptoKit
import PeerDropSecurity
import PeerDropTransport
import PeerDropAccount

public enum NoteCryptoError: Error, Equatable {
    case textTooLong
    case missingPreKeyBundle
    case invalidRecipientKeys
    case invalidSignedPreKeySignature
    case staleSignedPreKey
    case opkExhausted
    case unsupportedVersion
    case unknownSignedPreKey
    case oneTimePreKeyUnavailable
    case decryptionFailed
    case malformedPlaintext
}

/// What a signed (non-anonymous) sender contributes. `sign` is the
/// device's Ed25519 identity signing operation (`IdentityKeyManager.sign`).
public struct NoteSigner {
    public let accountId: String
    public let nickname: String?
    public let signingPublicKey: Data
    public let sign: (Data) throws -> Data
    public init(accountId: String, nickname: String?, signingPublicKey: Data, sign: @escaping (Data) throws -> Data) {
        self.accountId = accountId; self.nickname = nickname; self.signingPublicKey = signingPublicKey; self.sign = sign
    }
}

/// The recipient device's private material, supplied as lookups so the
/// caller (not this module) owns keychain/PreKeyStore access. The
/// one-time pre-key lookup is expected to CONSUME the key.
public struct NoteRecipientKeys {
    public let identityKey: Curve25519.KeyAgreement.PrivateKey
    public let signedPreKey: (UInt32) throws -> SignedPreKey?
    public let oneTimePreKey: (UInt32) throws -> OneTimePreKey?
    public init(identityKey: Curve25519.KeyAgreement.PrivateKey, signedPreKey: @escaping (UInt32) throws -> SignedPreKey?, oneTimePreKey: @escaping (UInt32) throws -> OneTimePreKey?) {
        self.identityKey = identityKey; self.signedPreKey = signedPreKey; self.oneTimePreKey = oneTimePreKey
    }
}

/// Pure functions — no singletons, no I/O — so they run anywhere
/// (background thread, `swift test` without keychain).
public enum NoteCrypto {
    public static let maxTextScalars = 2_000
    static let hkdfInfo = Data("peerdrop-note-v1".utf8)
    static let senderDomain = Data("peerdrop-note-sender-v1".utf8)
    static let tagLength = 16

    static func aad(recipientAccountId: String, version: UInt8) -> Data {
        var d = Data(recipientAccountId.utf8); d.append(version); return d
    }

    /// sha256("peerdrop-note-sender-v1" ‖ text ‖ sentAt BE8 ‖ recipientAccountId)
    public static func senderSignatureDigest(text: String, sentAt: Int64, recipientAccountId: String) -> Data {
        var m = senderDomain
        m.append(Data(text.utf8))
        var be = UInt64(bitPattern: sentAt).bigEndian
        m.append(Data(bytes: &be, count: 8))
        m.append(Data(recipientAccountId.utf8))
        return Data(SHA256.hash(data: m))
    }

    static func noteKey(from agreement: X3DH.KeyAgreementResult) -> SymmetricKey {
        HKDF<SHA256>.deriveKey(inputKeyMaterial: agreement.rootKey, salt: Data(), info: hkdfInfo, outputByteCount: 32)
    }

    public static func seal(text: String, recipient: DirectoryEntry, signer: NoteSigner?, policy: SecurityPolicy = .bundledDefault, now: Date = Date()) throws -> NoteEnvelope {
        guard text.unicodeScalars.count <= maxTextScalars else { throw NoteCryptoError.textTooLong }
        guard let bundle = recipient.preKeyBundle else { throw NoteCryptoError.missingPreKeyBundle }
        guard let identity = try? Curve25519.KeyAgreement.PublicKey(rawRepresentation: recipient.identityKey),
              let signingKey = try? Curve25519.Signing.PublicKey(rawRepresentation: recipient.signingKey),
              let spk = try? Curve25519.KeyAgreement.PublicKey(rawRepresentation: bundle.signedPreKey.publicKey)
        else { throw NoteCryptoError.invalidRecipientKeys }
        guard signingKey.isValidSignature(bundle.signedPreKey.signature, for: bundle.signedPreKey.publicKey) else {
            throw NoteCryptoError.invalidSignedPreKeySignature
        }
        let peerVersion: PeerVersion
        do {
            peerVersion = try X3DH.verifyBundleFreshness(
                signedPreKeyPublicKey: bundle.signedPreKey.publicKey,
                signedPreKeyTimestamp: bundle.signedPreKeyTimestamp,
                signedPreKeyTimestampSignature: bundle.signedPreKeyTimestampSignature,
                peerSigningKey: signingKey, now: now, policy: policy, metrics: nil)
        } catch {
            throw NoteCryptoError.staleSignedPreKey
        }
        let opk = try bundle.oneTimePreKey.map { try Curve25519.KeyAgreement.PublicKey(rawRepresentation: $0.publicKey) }
        let ek1 = Curve25519.KeyAgreement.PrivateKey()   // plays IK_A
        let ek2 = Curve25519.KeyAgreement.PrivateKey()   // EK_A
        let agreement: X3DH.KeyAgreementResult
        do {
            agreement = try X3DH.initiatorKeyAgreement(myIdentityKey: ek1, myEphemeralKey: ek2, theirIdentityKey: identity,
                                                       theirSignedPreKey: spk, theirOneTimePreKey: opk, peerVersion: peerVersion, policy: policy)
        } catch X3DH.InitiationError.opkExhausted {
            throw NoteCryptoError.opkExhausted
        }
        let sentAt = Int64(now.timeIntervalSince1970)
        var senderBlock: NoteSenderBlock? = nil
        if let signer {
            let sig = try signer.sign(senderSignatureDigest(text: text, sentAt: sentAt, recipientAccountId: recipient.accountId.raw))
            senderBlock = NoteSenderBlock(accountId: signer.accountId, nickname: signer.nickname, signingKey: signer.signingPublicKey, signature: sig)
        }
        let plaintext = try JSONEncoder().encode(NotePlaintext(kind: .note, text: text, sentAt: sentAt, sender: senderBlock))
        let nonce = AES.GCM.Nonce()
        let box = try AES.GCM.seal(plaintext, using: noteKey(from: agreement), nonce: nonce,
                                   authenticating: aad(recipientAccountId: recipient.accountId.raw, version: NoteEnvelope.currentVersion))
        // `AES.GCM.SealedBox.ciphertext`/`.tag` are slices into the box's
        // combined representation, so they carry non-zero start indices —
        // `Data(box.ciphertext)` normalizes to a fresh 0-based buffer before
        // appending, so callers can safely index/mutate `env.ciphertext`.
        var combined = Data(box.ciphertext)
        combined.append(box.tag)
        return NoteEnvelope(v: NoteEnvelope.currentVersion, ephemeralKey: ek1.publicKey.rawRepresentation, ephemeralKey2: ek2.publicKey.rawRepresentation,
                            spkId: bundle.signedPreKey.id, opkId: bundle.oneTimePreKey?.id, nonce: Data(nonce), ciphertext: combined)
    }

    /// **The returned `NotePlaintext.sender` block is UNVERIFIED.** `open`
    /// only checks the AEAD tag on the envelope; it does not check that the
    /// inner sender attestation's `accountId`/`nickname` are genuine. Callers
    /// MUST call `verifySender(_:recipientAccountId:directorySigningKey:)`
    /// before displaying `sender.accountId`/`sender.nickname` to a user.
    public static func open(_ env: NoteEnvelope, recipientAccountId: String, keys: NoteRecipientKeys) throws -> NotePlaintext {
        guard env.v == NoteEnvelope.currentVersion else { throw NoteCryptoError.unsupportedVersion }
        guard let spk = try keys.signedPreKey(env.spkId) else { throw NoteCryptoError.unknownSignedPreKey }
        // Structural checks (nonce/ciphertext length, ephemeral keys parse)
        // BEFORE the one-time pre-key lookup: a malformed/tampered envelope
        // that will fail anyway shouldn't consume — and thereby waste — a
        // real OPK from the store.
        guard env.nonce.count == 12, env.ciphertext.count >= tagLength,
              let ek1 = try? Curve25519.KeyAgreement.PublicKey(rawRepresentation: env.ephemeralKey),
              let ek2 = try? Curve25519.KeyAgreement.PublicKey(rawRepresentation: env.ephemeralKey2)
        else { throw NoteCryptoError.decryptionFailed }
        var opkPrivate: Curve25519.KeyAgreement.PrivateKey? = nil
        if let opkId = env.opkId {
            guard let opk = try keys.oneTimePreKey(opkId) else { throw NoteCryptoError.oneTimePreKeyUnavailable }
            opkPrivate = try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: opk.privateKey)
        }
        let agreement = try X3DH.responderKeyAgreement(myIdentityKey: keys.identityKey, mySignedPreKey: try spk.agreementPrivateKey(),
                                                       myOneTimePreKey: opkPrivate, theirIdentityKey: ek1, theirEphemeralKey: ek2)
        let plaintext: Data
        do {
            let box = try AES.GCM.SealedBox(nonce: AES.GCM.Nonce(data: env.nonce), ciphertext: env.ciphertext.dropLast(tagLength), tag: env.ciphertext.suffix(tagLength))
            plaintext = try AES.GCM.open(box, using: noteKey(from: agreement), authenticating: aad(recipientAccountId: recipientAccountId, version: env.v))
        } catch {
            throw NoteCryptoError.decryptionFailed
        }
        guard let decoded = try? JSONDecoder().decode(NotePlaintext.self, from: plaintext),
              decoded.text.unicodeScalars.count <= maxTextScalars
        else { throw NoteCryptoError.malformedPlaintext }
        return decoded
    }

    /// True only when the inner signing key matches the directory's key for
    /// that account AND the signature covers this text/time/recipient.
    public static func verifySender(_ plaintext: NotePlaintext, recipientAccountId: String, directorySigningKey: Data) -> Bool {
        guard let s = plaintext.sender, s.signingKey == directorySigningKey,
              let key = try? Curve25519.Signing.PublicKey(rawRepresentation: s.signingKey) else { return false }
        return key.isValidSignature(s.signature, for: senderSignatureDigest(text: plaintext.text, sentAt: plaintext.sentAt, recipientAccountId: recipientAccountId))
    }
}
