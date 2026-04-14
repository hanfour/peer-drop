import XCTest
@testable import PeerDrop

final class RemoteMessageEnvelopeTests: XCTestCase {

    func testEnvelopeCodableRoundTrip() throws {
        let ratchetMsg = RatchetMessage(
            ratchetKey: Data(repeating: 0x01, count: 32),
            counter: 0,
            previousCounter: 0,
            ciphertext: Data(repeating: 0x02, count: 64)
        )
        let envelope = RemoteMessageEnvelope(
            senderIdentityKey: Data(repeating: 0xAA, count: 32),
            senderMailboxId: "test-mailbox-123",
            senderDisplayName: "Carol",
            ephemeralKey: Data(repeating: 0xBB, count: 32),
            usedSignedPreKeyId: 1,
            usedOneTimePreKeyId: 5,
            ratchetMessage: ratchetMsg
        )

        let data = try JSONEncoder().encode(envelope)
        let decoded = try JSONDecoder().decode(RemoteMessageEnvelope.self, from: data)

        XCTAssertEqual(decoded.senderMailboxId, "test-mailbox-123")
        XCTAssertEqual(decoded.senderDisplayName, "Carol")
        XCTAssertEqual(decoded.senderIdentityKey, envelope.senderIdentityKey)
        XCTAssertEqual(decoded.ratchetMessage.counter, 0)
        XCTAssertTrue(decoded.isInitialMessage)
    }

    func testEnvelopeWithNilOptionals() throws {
        let ratchetMsg = RatchetMessage(
            ratchetKey: Data(repeating: 0x01, count: 32),
            counter: 3,
            previousCounter: 0,
            ciphertext: Data(repeating: 0x02, count: 64)
        )
        let envelope = RemoteMessageEnvelope(
            senderIdentityKey: Data(repeating: 0xAA, count: 32),
            senderMailboxId: "test-mailbox",
            senderDisplayName: nil,
            ephemeralKey: nil,
            usedSignedPreKeyId: nil,
            usedOneTimePreKeyId: nil,
            ratchetMessage: ratchetMsg
        )

        let data = try JSONEncoder().encode(envelope)
        let decoded = try JSONDecoder().decode(RemoteMessageEnvelope.self, from: data)

        XCTAssertNil(decoded.senderDisplayName)
        XCTAssertNil(decoded.ephemeralKey)
        XCTAssertFalse(decoded.isInitialMessage)
        XCTAssertEqual(decoded.ratchetMessage.counter, 3)
    }
}
