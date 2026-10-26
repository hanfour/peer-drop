import Foundation
import CryptoKit

public enum GroupCryptoError: Error, Equatable {
    case badLength
    case decryptionFailed
    case malformedPlaintext
    case oversized
}

/// Pure crypto for group rooms (wire format: `cloudflare-worker/GROUPS.md`).
/// - wrapped room key: ephemeralPub(32) ‖ nonce(12) ‖ AES-GCM ciphertext(32) ‖ tag(16) = 92 bytes.
/// - message AAD: groupId ‖ authorMemberId ‖ eventId ‖ UInt32BE(epoch); meta AAD: groupId ‖ UInt32BE(epoch) ‖ "meta".
/// - every `seal*`/`wrap` draws a fresh random nonce unless a test injects one.
public enum GroupCrypto {
    private static let nonceLength = 12
    private static let tagLength = 16
    private static let wrappedLength = 92
    private static let maxPayloadCipherBytes = 8 * 1024

    public static func memberKeyMessage(groupId: String, memberId: String, accountId: String, pubKey: Data) -> Data {
        var message = Data("PDGRPMK1".utf8)
        message.append(Data(groupId.utf8))
        message.append(Data(memberId.utf8))
        message.append(Data(accountId.utf8))
        message.append(pubKey)
        return message
    }

    public static func wrapMessage(groupId: String, epoch: UInt32, target: String, wrapper: String, wrapped: Data) -> Data {
        var message = Data("PDGRPWK1".utf8)
        message.append(Data(groupId.utf8))
        message.append(uint32Data(epoch))
        message.append(Data(target.utf8))
        message.append(Data(wrapper.utf8))
        message.append(wrapped)
        return message
    }

    public static func wrap(
        roomKey: SymmetricKey,
        groupId: String,
        epoch: UInt32,
        recipientMemberId: String,
        recipientPublicKey: Curve25519.KeyAgreement.PublicKey,
        ephemeral: Curve25519.KeyAgreement.PrivateKey = .init(),
        nonce: AES.GCM.Nonce = .init()
    ) throws -> Data {
        let roomKeyData = roomKey.withUnsafeBytes { Data($0) }
        guard roomKeyData.count == 32 else { throw GroupCryptoError.badLength }

        let sharedSecret = try ephemeral.sharedSecretFromKeyAgreement(with: recipientPublicKey)
        var salt = ephemeral.publicKey.rawRepresentation
        salt.append(recipientPublicKey.rawRepresentation)
        let wrappingKey = deriveWrappingKey(sharedSecret: sharedSecret, salt: salt)
        let aad = wrapAAD(groupId: groupId, epoch: epoch, memberId: recipientMemberId)
        let sealedBox = try AES.GCM.seal(roomKeyData, using: wrappingKey, nonce: nonce, authenticating: aad)

        var wrapped = ephemeral.publicKey.rawRepresentation
        wrapped.append(Data(nonce))
        wrapped.append(Data(sealedBox.ciphertext))
        wrapped.append(sealedBox.tag)
        return wrapped
    }

    public static func unwrap(
        _ wrapped: Data,
        groupId: String,
        epoch: UInt32,
        memberId: String,
        privateKey: Curve25519.KeyAgreement.PrivateKey
    ) throws -> SymmetricKey {
        guard wrapped.count == wrappedLength else { throw GroupCryptoError.badLength }

        let ephemeralPublicKey: Curve25519.KeyAgreement.PublicKey
        do {
            ephemeralPublicKey = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: Data(wrapped.prefix(32)))
        } catch {
            throw GroupCryptoError.decryptionFailed
        }

        let sharedSecret: SharedSecret
        do {
            sharedSecret = try privateKey.sharedSecretFromKeyAgreement(with: ephemeralPublicKey)
        } catch {
            throw GroupCryptoError.decryptionFailed
        }

        var salt = ephemeralPublicKey.rawRepresentation
        salt.append(privateKey.publicKey.rawRepresentation)
        let wrappingKey = deriveWrappingKey(sharedSecret: sharedSecret, salt: salt)
        let nonceData = Data(wrapped.dropFirst(32).prefix(nonceLength))
        let ciphertext = Data(wrapped.dropFirst(32 + nonceLength).dropLast(tagLength))
        let tag = Data(wrapped.suffix(tagLength))

        do {
            let nonce = try AES.GCM.Nonce(data: nonceData)
            let sealedBox = try AES.GCM.SealedBox(nonce: nonce, ciphertext: ciphertext, tag: tag)
            let roomKey = try AES.GCM.open(sealedBox, using: wrappingKey, authenticating: wrapAAD(groupId: groupId, epoch: epoch, memberId: memberId))
            return SymmetricKey(data: roomKey)
        } catch {
            throw GroupCryptoError.decryptionFailed
        }
    }

    public static func sealMessage(
        _ payload: GroupMessagePayload,
        key: SymmetricKey,
        groupId: String,
        memberId: String,
        eventId: String,
        epoch: UInt32,
        nonce: AES.GCM.Nonce = .init()
    ) throws -> Data {
        try validate(payload)
        let plaintext: Data
        do {
            plaintext = try JSONEncoder().encode(payload)
        } catch {
            throw GroupCryptoError.malformedPlaintext
        }
        let sealed = try sealRaw(plaintext: plaintext, key: key, aad: messageAAD(groupId: groupId, memberId: memberId, eventId: eventId, epoch: epoch), nonce: nonce)
        guard sealed.count <= maxPayloadCipherBytes else { throw GroupCryptoError.oversized }
        return sealed
    }

    public static func openMessage(
        _ data: Data,
        key: SymmetricKey,
        groupId: String,
        memberId: String,
        eventId: String,
        epoch: UInt32
    ) throws -> GroupMessagePayload {
        guard data.count <= maxPayloadCipherBytes else { throw GroupCryptoError.oversized }
        let plaintext = try openRaw(data, key: key, aad: messageAAD(groupId: groupId, memberId: memberId, eventId: eventId, epoch: epoch))
        let payload: GroupMessagePayload
        do {
            payload = try JSONDecoder().decode(GroupMessagePayload.self, from: plaintext)
        } catch {
            throw GroupCryptoError.malformedPlaintext
        }
        try validate(payload)
        return payload
    }

    public static func sealMeta(
        _ meta: GroupMetaPlaintext,
        key: SymmetricKey,
        groupId: String,
        epoch: UInt32,
        nonce: AES.GCM.Nonce = .init()
    ) throws -> Data {
        try validate(meta)
        let plaintext: Data
        do {
            plaintext = try JSONEncoder().encode(meta)
        } catch {
            throw GroupCryptoError.malformedPlaintext
        }
        let sealed = try sealRaw(plaintext: plaintext, key: key, aad: metaAAD(groupId: groupId, epoch: epoch), nonce: nonce)
        guard sealed.count <= GroupLimits.metaBytes else { throw GroupCryptoError.oversized }
        return sealed
    }

    public static func openMeta(_ data: Data, key: SymmetricKey, groupId: String, epoch: UInt32) throws -> GroupMetaPlaintext {
        guard data.count <= GroupLimits.metaBytes else { throw GroupCryptoError.oversized }
        let plaintext = try openRaw(data, key: key, aad: metaAAD(groupId: groupId, epoch: epoch))
        let meta: GroupMetaPlaintext
        do {
            meta = try JSONDecoder().decode(GroupMetaPlaintext.self, from: plaintext)
        } catch {
            throw GroupCryptoError.malformedPlaintext
        }
        try validate(meta)
        return meta
    }

    public static func verify(signature: Data, message: Data, signingPublicKey: Data) -> Bool {
        guard let publicKey = try? Curve25519.Signing.PublicKey(rawRepresentation: signingPublicKey) else { return false }
        return publicKey.isValidSignature(signature, for: message)
    }

    /// Returns empty `Data` if signing fails (callers are tests and key re-wrapping, which verify the result).
    public static func sign(_ message: Data, with key: Curve25519.Signing.PrivateKey) -> Data {
        (try? key.signature(for: message)) ?? Data()
    }

    static func messageAAD(groupId: String, memberId: String, eventId: String, epoch: UInt32) -> Data {
        var aad = Data(groupId.utf8)
        aad.append(Data(memberId.utf8))
        aad.append(Data(eventId.utf8))
        aad.append(uint32Data(epoch))
        return aad
    }

    static func metaAAD(groupId: String, epoch: UInt32) -> Data {
        var aad = Data(groupId.utf8)
        aad.append(uint32Data(epoch))
        aad.append(Data("meta".utf8))
        return aad
    }

    static func sealRaw(plaintext: Data, key: SymmetricKey, aad: Data, nonce: AES.GCM.Nonce) throws -> Data {
        let sealedBox = try AES.GCM.seal(plaintext, using: key, nonce: nonce, authenticating: aad)
        var sealed = Data(nonce)
        sealed.append(Data(sealedBox.ciphertext))
        sealed.append(sealedBox.tag)
        return sealed
    }

    static func openRaw(_ data: Data, key: SymmetricKey, aad: Data) throws -> Data {
        guard data.count >= nonceLength + tagLength else { throw GroupCryptoError.decryptionFailed }
        let nonceData = Data(data.prefix(nonceLength))
        let ciphertext = Data(data.dropFirst(nonceLength).dropLast(tagLength))
        let tag = Data(data.suffix(tagLength))
        do {
            let nonce = try AES.GCM.Nonce(data: nonceData)
            let sealedBox = try AES.GCM.SealedBox(nonce: nonce, ciphertext: ciphertext, tag: tag)
            return try AES.GCM.open(sealedBox, using: key, authenticating: aad)
        } catch {
            throw GroupCryptoError.decryptionFailed
        }
    }

    private static func wrapAAD(groupId: String, epoch: UInt32, memberId: String) -> Data {
        var aad = Data(groupId.utf8)
        aad.append(uint32Data(epoch))
        aad.append(Data(memberId.utf8))
        return aad
    }

    private static func deriveWrappingKey(sharedSecret: SharedSecret, salt: Data) -> SymmetricKey {
        sharedSecret.hkdfDerivedSymmetricKey(
            using: SHA256.self,
            salt: salt,
            sharedInfo: Data("peerdrop-group-wrap-v1".utf8),
            outputByteCount: 32
        )
    }

    private static func uint32Data(_ value: UInt32) -> Data {
        var bigEndian = value.bigEndian
        return Data(bytes: &bigEndian, count: MemoryLayout<UInt32>.size)
    }

    private static func validate(_ payload: GroupMessagePayload) throws {
        if let text = payload.text, text.unicodeScalars.count > GroupLimits.messageScalars {
            throw GroupCryptoError.oversized
        }
        if let nickname = payload.nickname, nickname.unicodeScalars.count > GroupLimits.nicknameScalars {
            throw GroupCryptoError.oversized
        }
    }

    private static func validate(_ meta: GroupMetaPlaintext) throws {
        guard meta.name.unicodeScalars.count <= GroupLimits.nameScalars else { throw GroupCryptoError.oversized }
        if let description = meta.description, description.unicodeScalars.count > GroupLimits.descriptionScalars {
            throw GroupCryptoError.oversized
        }
        if let photo = meta.photo, photo.count > GroupLimits.photoBytes {
            throw GroupCryptoError.oversized
        }
        if case let .custom(data)? = meta.background, data.count > GroupLimits.customBackgroundBytes {
            throw GroupCryptoError.oversized
        }
    }
}
