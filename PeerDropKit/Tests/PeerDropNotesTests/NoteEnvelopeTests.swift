import XCTest
@testable import PeerDropNotes

final class NoteEnvelopeTests: XCTestCase {
    func testWireBytesAreSortedKeyJSONWithBase64Data() throws {
        let env = NoteEnvelope(v: 1, ephemeralKey: Data(repeating: 1, count: 32), ephemeralKey2: Data(repeating: 2, count: 32), spkId: 7, opkId: 41, nonce: Data(repeating: 3, count: 12), ciphertext: Data(repeating: 4, count: 20))
        let bytes = try env.wireBytes()
        let text = String(decoding: bytes, as: UTF8.self)
        XCTAssertTrue(text.hasPrefix(#"{"ciphertext":"BAQEBAQEBAQEBAQEBAQEBAQEBAQ=","ephemeralKey":"#), text)
        XCTAssertTrue(text.contains(#""spkId":7"#) && text.contains(#""opkId":41"#) && text.contains(#""v":1"#))
        XCTAssertEqual(try NoteEnvelope.fromWire(bytes), env)
    }
    func testOptionalOPKIsOmittedOnTheWire() throws {
        let env = NoteEnvelope(v: 1, ephemeralKey: Data(count: 32), ephemeralKey2: Data(count: 32), spkId: 1, opkId: nil, nonce: Data(count: 12), ciphertext: Data(count: 16))
        XCTAssertFalse(String(decoding: try env.wireBytes(), as: UTF8.self).contains("opkId"))
        XCTAssertNil(try NoteEnvelope.fromWire(env.wireBytes()).opkId)
    }
    func testBase64SlashesAreNotEscapedOnTheWire() throws {
        // Data([0xff, 0xff, 0xff]).base64EncodedString() == "////" — JSON's
        // default escaping (`\/`) would otherwise make the wire payload
        // depend on which encoder produced it; `.withoutEscapingSlashes`
        // keeps the base64 verbatim.
        let env = NoteEnvelope(v: 1, ephemeralKey: Data([0xff, 0xff, 0xff]), ephemeralKey2: Data(count: 32), spkId: 1, opkId: nil, nonce: Data(count: 12), ciphertext: Data(count: 16))
        let text = String(decoding: try env.wireBytes(), as: UTF8.self)
        XCTAssertTrue(text.contains(#""ephemeralKey":"////""#), text)
        XCTAssertFalse(text.contains(#"\/"#), text)
    }
}
