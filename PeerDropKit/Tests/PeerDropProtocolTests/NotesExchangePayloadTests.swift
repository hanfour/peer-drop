import XCTest
@testable import PeerDropProtocol

final class NotesExchangePayloadTests: XCTestCase {
    func testRoundTrip() throws {
        let p = NotesExchangePayload(phase: "reveal", nonce: Data([1]), accountId: "ABCD1234",
                                     signingKey: Data([2]), signature: Data([3]))
        let msg = try PeerMessage.notesExchange(p, senderID: "S")
        XCTAssertEqual(msg.type, .notesExchange)
        XCTAssertEqual(try msg.decodePayload(NotesExchangePayload.self), p)
    }

    func testUnknownPhaseDecodes() throws {
        let json = #"{"phase":"from-the-future","extra":1}"#
        let p = try JSONDecoder().decode(NotesExchangePayload.self, from: Data(json.utf8))
        XCTAssertEqual(p.phase, "from-the-future")
        XCTAssertNil(NotesExchangePhase(rawValue: p.phase))
    }

    func testMissingFieldsDecode() throws {
        let p = try JSONDecoder().decode(NotesExchangePayload.self, from: Data(#"{"phase":"intent"}"#.utf8))
        XCTAssertNil(p.nonce)
        XCTAssertNil(p.accountId)
        XCTAssertNil(p.signingKey)
        XCTAssertNil(p.signature)
        XCTAssertEqual(NotesExchangePhase(rawValue: p.phase), .intent)
    }

    func testPhases() {
        XCTAssertEqual(Set(["intent", "reveal", "cancel", "unavailable"].compactMap(NotesExchangePhase.init(rawValue:))).count, 4)
    }
}
