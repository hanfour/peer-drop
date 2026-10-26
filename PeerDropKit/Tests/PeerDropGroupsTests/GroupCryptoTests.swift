import XCTest
import CryptoKit
@testable import PeerDropGroups

final class GroupCryptoTests: XCTestCase {
    private let key = SymmetricKey(size: .bits256)
    private let groupId = "01JBX8G7R5ZK4Q2M9N3PDT6WAC"
    private let memberId = "7M3Q9ZR4K2X8N5PDT6WACB1HJE"
    private let eventId = "01JBX8H2Q4S6T8V0W2Y4Z6A8C0"

    func testMessageRoundTripAndAssociatedDataBinding() throws {
        let payload = GroupMessagePayload(kind: .text, text: "哈囉，群組！Hello group 👋")
        let sealed = try GroupCrypto.sealMessage(payload, key: key, groupId: groupId, memberId: memberId, eventId: eventId, epoch: 3)

        XCTAssertEqual(try GroupCrypto.openMessage(sealed, key: key, groupId: groupId, memberId: memberId, eventId: eventId, epoch: 3), payload)
        XCTAssertThrowsError(try GroupCrypto.openMessage(sealed, key: key, groupId: "other", memberId: memberId, eventId: eventId, epoch: 3)) {
            XCTAssertEqual($0 as? GroupCryptoError, .decryptionFailed)
        }
        XCTAssertThrowsError(try GroupCrypto.openMessage(sealed, key: key, groupId: groupId, memberId: "other", eventId: eventId, epoch: 3)) {
            XCTAssertEqual($0 as? GroupCryptoError, .decryptionFailed)
        }
        XCTAssertThrowsError(try GroupCrypto.openMessage(sealed, key: key, groupId: groupId, memberId: memberId, eventId: "other", epoch: 3)) {
            XCTAssertEqual($0 as? GroupCryptoError, .decryptionFailed)
        }
        XCTAssertThrowsError(try GroupCrypto.openMessage(sealed, key: key, groupId: groupId, memberId: memberId, eventId: eventId, epoch: 4)) {
            XCTAssertEqual($0 as? GroupCryptoError, .decryptionFailed)
        }
    }

    func testWrapRejectsIncorrectLength() throws {
        let privateKey = Curve25519.KeyAgreement.PrivateKey()
        XCTAssertThrowsError(try GroupCrypto.unwrap(Data(repeating: 0, count: 91), groupId: groupId, epoch: 1, memberId: memberId, privateKey: privateKey)) {
            XCTAssertEqual($0 as? GroupCryptoError, .badLength)
        }
    }

    func testMessageAndNicknameScalarLimitsAreEnforced() {
        let longText = GroupMessagePayload(kind: .text, text: String(repeating: "字", count: GroupLimits.messageScalars + 1))
        XCTAssertThrowsError(try GroupCrypto.sealMessage(longText, key: key, groupId: groupId, memberId: memberId, eventId: eventId, epoch: 1)) {
            XCTAssertEqual($0 as? GroupCryptoError, .oversized)
        }

        let longNickname = GroupMessagePayload(kind: .identity, nickname: String(repeating: "字", count: GroupLimits.nicknameScalars + 1))
        XCTAssertThrowsError(try GroupCrypto.sealMessage(longNickname, key: key, groupId: groupId, memberId: memberId, eventId: eventId, epoch: 1)) {
            XCTAssertEqual($0 as? GroupCryptoError, .oversized)
        }
    }

    func testOpenRejectsOversizedTextAndNickname() throws {
        let payloads = [
            GroupMessagePayload(kind: .text, text: String(repeating: "字", count: GroupLimits.messageScalars + 1)),
            GroupMessagePayload(kind: .identity, nickname: String(repeating: "字", count: GroupLimits.nicknameScalars + 1)),
        ]

        for payload in payloads {
            let plaintext = try JSONEncoder().encode(payload)
            let sealed = try GroupCrypto.sealRaw(
                plaintext: plaintext,
                key: key,
                aad: GroupCrypto.messageAAD(groupId: groupId, memberId: memberId, eventId: eventId, epoch: 1),
                nonce: AES.GCM.Nonce()
            )
            XCTAssertThrowsError(try GroupCrypto.openMessage(sealed, key: key, groupId: groupId, memberId: memberId, eventId: eventId, epoch: 1)) {
                XCTAssertEqual($0 as? GroupCryptoError, .oversized)
            }
        }
    }

    func testIdentityRoundTripAndNicknameBoundary() throws {
        let ok = GroupMessagePayload(kind: .identity, nickname: String(repeating: "字", count: GroupLimits.nicknameScalars))
        let sealed = try GroupCrypto.sealMessage(ok, key: key, groupId: groupId, memberId: memberId, eventId: eventId, epoch: 1)
        XCTAssertEqual(try GroupCrypto.openMessage(sealed, key: key, groupId: groupId, memberId: memberId, eventId: eventId, epoch: 1), ok)
    }

    func testTamperedCiphertextAndTagFailToOpen() throws {
        let sealed = try GroupCrypto.sealMessage(GroupMessagePayload(kind: .text, text: "hi"), key: key, groupId: groupId, memberId: memberId, eventId: eventId, epoch: 1)
        for index in [14, sealed.count - 1] {
            var bad = sealed
            bad[index] ^= 0x01
            XCTAssertThrowsError(try GroupCrypto.openMessage(bad, key: key, groupId: groupId, memberId: memberId, eventId: eventId, epoch: 1)) {
                XCTAssertEqual($0 as? GroupCryptoError, .decryptionFailed)
            }
        }
    }

    func testDefaultNonceMakesEverySealDifferent() throws {
        let payload = GroupMessagePayload(kind: .text, text: "same")
        let a = try GroupCrypto.sealMessage(payload, key: key, groupId: groupId, memberId: memberId, eventId: eventId, epoch: 1)
        let b = try GroupCrypto.sealMessage(payload, key: key, groupId: groupId, memberId: memberId, eventId: eventId, epoch: 1)
        XCTAssertNotEqual(a, b)
    }

    func testUnwrapBindsGroupEpochMemberAndKeyAndLength() throws {
        let recipient = Curve25519.KeyAgreement.PrivateKey()
        let roomKey = SymmetricKey(size: .bits256)
        let wrapped = try GroupCrypto.wrap(roomKey: roomKey, groupId: groupId, epoch: 2, recipientMemberId: memberId, recipientPublicKey: recipient.publicKey)
        XCTAssertEqual(wrapped.count, 92)
        let opened = try GroupCrypto.unwrap(wrapped, groupId: groupId, epoch: 2, memberId: memberId, privateKey: recipient)
        XCTAssertEqual(opened.withUnsafeBytes { Data($0) }, roomKey.withUnsafeBytes { Data($0) })

        let cases: [(String, UInt32, String, Curve25519.KeyAgreement.PrivateKey)] = [
            ("other", 2, memberId, recipient), (groupId, 3, memberId, recipient),
            (groupId, 2, "other", recipient), (groupId, 2, memberId, Curve25519.KeyAgreement.PrivateKey()),
        ]
        for (g, e, m, k) in cases {
            XCTAssertThrowsError(try GroupCrypto.unwrap(wrapped, groupId: g, epoch: e, memberId: m, privateKey: k)) {
                XCTAssertEqual($0 as? GroupCryptoError, .decryptionFailed)
            }
        }
        XCTAssertThrowsError(try GroupCrypto.unwrap(wrapped + Data([0]), groupId: groupId, epoch: 2, memberId: memberId, privateKey: recipient)) {
            XCTAssertEqual($0 as? GroupCryptoError, .badLength)
        }
    }

    func testMetaBackgroundWireShapeAndForwardCompatibility() throws {
        let meta = GroupMetaPlaintext(name: "n", background: .preset("sky"))
        let json = String(decoding: try JSONEncoder().encode(meta), as: UTF8.self)
        XCTAssertTrue(json.contains("\"type\":\"preset\""))
        let future = Data(#"{"name":"n","background":{"type":"gradient","value":"x"}}"#.utf8)
        let decoded = try JSONDecoder().decode(GroupMetaPlaintext.self, from: future)
        XCTAssertEqual(decoded.name, "n")
        XCTAssertNil(decoded.background)
    }

    func testOpenMetaRejectsMalformedPlaintext() throws {
        let aad = GroupCrypto.metaAAD(groupId: groupId, epoch: 1)
        for plain in ["not json", #"{"category":"x"}"#] {
            let sealed = try GroupCrypto.sealRaw(plaintext: Data(plain.utf8), key: key, aad: aad, nonce: AES.GCM.Nonce())
            XCTAssertThrowsError(try GroupCrypto.openMeta(sealed, key: key, groupId: groupId, epoch: 1)) {
                XCTAssertEqual($0 as? GroupCryptoError, .malformedPlaintext)
            }
        }
    }
}
