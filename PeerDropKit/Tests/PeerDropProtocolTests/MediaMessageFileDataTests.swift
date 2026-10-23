import XCTest
@testable import PeerDropProtocol

/// H7: a media message used to carry only metadata + thumbnail, so receivers
/// stored an empty file. The file bytes now ride inline in the payload.
final class MediaMessageFileDataTests: XCTestCase {
    private func payload(fileData: Data?, fileSize: Int64? = nil) -> MediaMessagePayload {
        MediaMessagePayload(
            mediaType: .voice, fileName: "v.m4a",
            fileSize: fileSize ?? Int64(fileData?.count ?? 0),
            mimeType: "audio/mp4", duration: 1.5, thumbnailData: nil, fileData: fileData)
    }

    func testFileDataSurvivesPeerMessageRoundTrip() throws {
        let bytes = Data((0..<5_000).map { UInt8($0 % 251) })
        let msg = try PeerMessage.mediaMessage(payload(fileData: bytes), senderID: "s")
        let decoded = try msg.decodePayload(MediaMessagePayload.self)
        XCTAssertEqual(decoded.fileData, bytes)
    }

    /// A pre-H7 peer sends no `fileData` key; it must still decode (thumbnail-only, as before).
    func testLegacyPayloadWithoutFileDataStillDecodes() throws {
        let legacy = """
        {"id":"1","mediaType":"image","fileName":"a.jpg","fileSize":10,"mimeType":"image/jpeg","timestamp":0}
        """.data(using: .utf8)!
        let decoded = try JSONDecoder().decode(MediaMessagePayload.self, from: legacy)
        XCTAssertNil(decoded.fileData)
    }

    func testValidatedFileDataAcceptsMatchingSize() {
        let bytes = Data(repeating: 7, count: 100)
        XCTAssertEqual(payload(fileData: bytes).validatedFileData, bytes)
    }

    /// The claimed size is untrusted: a mismatch means the bytes aren't what the
    /// metadata says, so they are not stored.
    func testValidatedFileDataRejectsSizeMismatch() {
        XCTAssertNil(payload(fileData: Data(repeating: 7, count: 100), fileSize: 99).validatedFileData)
    }

    func testValidatedFileDataRejectsOverCap() {
        let over = MediaMessagePayload.maxInlineFileSize + 1
        let p = MediaMessagePayload(mediaType: .file, fileName: "big", fileSize: Int64(over),
                                    mimeType: "x/y", duration: nil, thumbnailData: nil,
                                    fileData: Data(count: over))
        XCTAssertNil(p.validatedFileData)
    }

    func testNilFileDataValidatesToNil() {
        XCTAssertNil(payload(fileData: nil).validatedFileData)
    }
}
