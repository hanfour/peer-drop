import XCTest
import CryptoKit
@testable import PeerDropGroups

final class GroupCryptoVectorTests: XCTestCase {
    func testMemberKeySignatureVector() throws {
        let vectors = try loadVectors()
        let vector = vectors.memberKeySig
        let message = GroupCrypto.memberKeyMessage(
            groupId: vector.groupId,
            memberId: vector.memberId,
            accountId: vector.accountId,
            pubKey: Data(hex: vector.pubKeyHex)
        )
        let privateKey = try Curve25519.Signing.PrivateKey(rawRepresentation: Data(hex: vectors.signing.seedHex))

        XCTAssertEqual(message, Data(hex: vector.messageHex))
        XCTAssertTrue(GroupCrypto.verify(signature: Data(hex: vector.signatureHex), message: message, signingPublicKey: Data(hex: vectors.signing.publicKeyHex)))
        // CryptoKit's Ed25519 signature did not byte-match the vector (observed), so verify the fresh signature instead.
        let fresh = GroupCrypto.sign(message, with: privateKey)
        XCTAssertTrue(GroupCrypto.verify(signature: fresh, message: message, signingPublicKey: Data(hex: vectors.signing.publicKeyHex)))

        var changedMessage = message
        changedMessage[0] ^= 0x01
        XCTAssertFalse(GroupCrypto.verify(signature: Data(hex: vector.signatureHex), message: changedMessage, signingPublicKey: Data(hex: vectors.signing.publicKeyHex)))
    }

    func testWrapAndWrapSignatureVectors() throws {
        let vectors = try loadVectors()
        let vector = vectors.wrap
        let ephemeral = try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: Data(hex: vector.ephemeralPrivateKeyHex))
        let recipientPrivateKey = try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: Data(hex: vector.recipientPrivateKeyHex))
        let recipientPublicKey = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: Data(hex: vector.recipientPublicKeyHex))
        let nonce = try AES.GCM.Nonce(data: Data(hex: vector.nonceHex))
        let roomKey = SymmetricKey(data: Data(hex: vector.roomKeyHex))
        let wrapped = try GroupCrypto.wrap(
            roomKey: roomKey,
            groupId: vector.groupId,
            epoch: UInt32(vector.epoch),
            recipientMemberId: vector.memberId,
            recipientPublicKey: recipientPublicKey,
            ephemeral: ephemeral,
            nonce: nonce
        )

        XCTAssertEqual(wrapped.count, 92)
        XCTAssertEqual(wrapped, Data(hex: vector.wrappedHex))
        let unwrapped = try GroupCrypto.unwrap(
            wrapped,
            groupId: vector.groupId,
            epoch: UInt32(vector.epoch),
            memberId: vector.memberId,
            privateKey: recipientPrivateKey
        )
        XCTAssertEqual(unwrapped.withUnsafeBytes { Data($0) }, Data(hex: vector.roomKeyHex))

        let signatureVector = vectors.wrapSig
        let message = GroupCrypto.wrapMessage(
            groupId: signatureVector.groupId,
            epoch: UInt32(signatureVector.epoch),
            target: signatureVector.targetMemberId,
            wrapper: signatureVector.wrapperMemberId,
            wrapped: Data(base64Encoded: signatureVector.wrappedB64)!
        )
        XCTAssertEqual(message, Data(hex: signatureVector.messageHex))
        XCTAssertTrue(GroupCrypto.verify(signature: Data(hex: signatureVector.signatureHex), message: message, signingPublicKey: Data(hex: vectors.signing.publicKeyHex)))
    }

    func testMessageCipherVector() throws {
        let vector = try loadVectors().message
        let key = SymmetricKey(data: Data(hex: vector.roomKeyHex))
        let aad = GroupCrypto.messageAAD(groupId: vector.groupId, memberId: vector.memberId, eventId: vector.eventId, epoch: UInt32(vector.epoch))
        XCTAssertEqual(aad, Data(hex: vector.aadHex))

        let sealed = try GroupCrypto.sealRaw(
            plaintext: Data(vector.plaintext.utf8),
            key: key,
            aad: aad,
            nonce: try AES.GCM.Nonce(data: Data(hex: vector.nonceHex))
        )
        XCTAssertEqual(sealed, Data(base64Encoded: vector.payloadCipherB64)!)
        XCTAssertEqual(try GroupCrypto.openRaw(sealed, key: key, aad: aad), Data(vector.plaintext.utf8))
    }

    func testMetaCipherVector() throws {
        let vector = try loadVectors().metaCipher
        let key = SymmetricKey(data: Data(hex: vector.roomKeyHex))
        let nonce = try AES.GCM.Nonce(data: Data(hex: vector.nonceHex))
        // JSONEncoder key order is not stable, so the byte match uses the vector's own plaintext.
        let sealed = try GroupCrypto.sealRaw(
            plaintext: Data(vector.plaintext.utf8),
            key: key,
            aad: GroupCrypto.metaAAD(groupId: vector.groupId, epoch: UInt32(vector.epoch)),
            nonce: nonce
        )
        XCTAssertEqual(sealed, Data(base64Encoded: vector.metaCipherB64)!)
        let meta = GroupMetaPlaintext(name: "週末爬山", category: "興趣")
        let roundTrip = try GroupCrypto.sealMeta(meta, key: key, groupId: vector.groupId, epoch: UInt32(vector.epoch))
        XCTAssertEqual(try GroupCrypto.openMeta(roundTrip, key: key, groupId: vector.groupId, epoch: UInt32(vector.epoch)), meta)
        let opened = try GroupCrypto.openMeta(Data(base64Encoded: vector.metaCipherB64)!, key: key, groupId: vector.groupId, epoch: UInt32(vector.epoch))
        XCTAssertEqual(opened.name, "週末爬山")
        XCTAssertEqual(opened.category, "興趣")
    }

    private func loadVectors() throws -> GroupCryptoVectors {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let url = root.appendingPathComponent("cloudflare-worker/test-vectors/group-crypto.json")
        return try JSONDecoder().decode(GroupCryptoVectors.self, from: Data(contentsOf: url))
    }
}

private struct GroupCryptoVectors: Decodable {
    let signing: Signing
    let memberKeySig: MemberKeySignature
    let wrap: Wrap
    let wrapSig: WrapSignature
    let message: Message
    let metaCipher: MetaCipher

    struct Signing: Decodable {
        let seedHex: String
        let publicKeyHex: String
    }
    struct MemberKeySignature: Decodable {
        let groupId: String
        let memberId: String
        let accountId: String
        let pubKeyHex: String
        let messageHex: String
        let signatureHex: String
    }
    struct Wrap: Decodable {
        let groupId: String
        let epoch: Int
        let memberId: String
        let recipientPrivateKeyHex: String
        let recipientPublicKeyHex: String
        let ephemeralPrivateKeyHex: String
        let roomKeyHex: String
        let nonceHex: String
        let wrappedHex: String
    }
    struct WrapSignature: Decodable {
        let groupId: String
        let epoch: Int
        let targetMemberId: String
        let wrapperMemberId: String
        let wrappedB64: String
        let messageHex: String
        let signatureHex: String
    }
    struct Message: Decodable {
        let groupId: String
        let memberId: String
        let eventId: String
        let epoch: Int
        let roomKeyHex: String
        let nonceHex: String
        let plaintext: String
        let aadHex: String
        let payloadCipherB64: String
    }
    struct MetaCipher: Decodable {
        let groupId: String
        let epoch: Int
        let roomKeyHex: String
        let nonceHex: String
        let metaCipherB64: String
        let plaintext: String
    }
}

private extension Data {
    init(hex: String) {
        var bytes = [UInt8]()
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2)
            bytes.append(UInt8(hex[index..<next], radix: 16)!)
            index = next
        }
        self.init(bytes)
    }
}
