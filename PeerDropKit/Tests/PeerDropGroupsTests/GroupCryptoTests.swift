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
}
