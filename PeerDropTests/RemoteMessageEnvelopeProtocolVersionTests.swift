import XCTest
@testable import PeerDrop

final class RemoteMessageEnvelopeProtocolVersionTests: XCTestCase {

    // MARK: - Tests

    /// v5.0–v5.3 envelopes (no protocolVersion key in JSON) must still decode.
    func test_legacy_envelope_decodes_without_protocolVersion() throws {
        let legacyJSON = makeLegacyEnvelopeDict()
        let data = try JSONSerialization.data(withJSONObject: legacyJSON)
        let decoded = try JSONDecoder().decode(RemoteMessageEnvelope.self, from: data)
        XCTAssertNil(decoded.protocolVersion)
    }

    /// v5.4+ envelopes carry protocolVersion = 1 and round-trip cleanly.
    func test_v5_4_envelope_carries_protocolVersion_1() throws {
        let envelope = makeV54Envelope()
        let data = try JSONEncoder().encode(envelope)
        let decoded = try JSONDecoder().decode(RemoteMessageEnvelope.self, from: data)
        XCTAssertEqual(decoded.protocolVersion, 1)
    }

    /// Future versions (e.g. the server somehow returns 99) decode the number
    /// without throwing. The receiver-side PeerVersion mapping handles the
    /// "unknown number" case at a higher layer.
    func test_unknown_protocolVersion_decodes_as_raw_number() throws {
        let envelope = makeV54Envelope()
        var data = try JSONEncoder().encode(envelope)
        var dict = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        dict["protocolVersion"] = 99
        data = try JSONSerialization.data(withJSONObject: dict)
        let decoded = try JSONDecoder().decode(RemoteMessageEnvelope.self, from: data)
        XCTAssertEqual(decoded.protocolVersion, 99)
    }

    // MARK: - Helpers

    /// Build a JSON dict containing all required existing fields but NO
    /// protocolVersion key — mirrors what a v5.0–v5.3 sender would emit.
    private func makeLegacyEnvelopeDict() -> [String: Any] {
        // ratchetMessage sub-dict
        let ratchetDict: [String: Any] = [
            "ratchetKey": Data(repeating: 0x01, count: 32).base64EncodedString(),
            "counter": 0,
            "previousCounter": 0,
            "ciphertext": Data(repeating: 0x02, count: 64).base64EncodedString()
        ]
        return [
            "senderIdentityKey": Data(repeating: 0xAA, count: 32).base64EncodedString(),
            "senderMailboxId": "test-legacy-mailbox",
            // senderDisplayName, ephemeralKey, usedSignedPreKeyId,
            // usedOneTimePreKeyId are all optional — omit to test nils too.
            "ratchetMessage": ratchetDict
            // protocolVersion intentionally absent
        ]
    }

    /// Build a real RemoteMessageEnvelope using the default init — gets
    /// protocolVersion: 1 automatically via the init's default parameter.
    private func makeV54Envelope() -> RemoteMessageEnvelope {
        let ratchetMsg = RatchetMessage(
            ratchetKey: Data(repeating: 0x01, count: 32),
            counter: 0,
            previousCounter: 0,
            ciphertext: Data(repeating: 0x02, count: 64)
        )
        return RemoteMessageEnvelope(
            senderIdentityKey: Data(repeating: 0xAA, count: 32),
            senderMailboxId: "test-v54-mailbox",
            senderDisplayName: "Tester",
            ephemeralKey: nil,
            usedSignedPreKeyId: nil,
            usedOneTimePreKeyId: nil,
            ratchetMessage: ratchetMsg
            // protocolVersion omitted → defaults to 1
        )
    }
}
