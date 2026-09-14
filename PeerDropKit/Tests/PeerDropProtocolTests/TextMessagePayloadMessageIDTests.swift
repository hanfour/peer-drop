// PeerDropKit/Tests/PeerDropProtocolTests/TextMessagePayloadMessageIDTests.swift
//
// The wire payload must carry the sender's message id so the receiver stores
// the message under the SAME id — without it, receipts / edits / deletes /
// reactions reference ids the other side never has. The field is optional so
// old clients (which omit it, and ignore it when present) still interoperate.
import XCTest
@testable import PeerDropProtocol

final class TextMessagePayloadMessageIDTests: XCTestCase {

    func test_messageID_roundTrips() throws {
        let payload = TextMessagePayload(text: "hi", messageID: "shared-abc-123")
        let data = try JSONEncoder().encode(payload)
        let decoded = try JSONDecoder().decode(TextMessagePayload.self, from: data)
        XCTAssertEqual(decoded.messageID, "shared-abc-123")
    }

    /// A payload from an older client has no messageID key; it must decode to
    /// nil rather than throwing, so the receiver falls back to minting an id.
    func test_decode_legacyPayloadWithoutMessageID_isNil() throws {
        let legacyJSON = Data(#"{"text":"hi","timestamp":0}"#.utf8)
        let decoded = try JSONDecoder().decode(TextMessagePayload.self, from: legacyJSON)
        XCTAssertNil(decoded.messageID)
        XCTAssertEqual(decoded.text, "hi")
    }
}
