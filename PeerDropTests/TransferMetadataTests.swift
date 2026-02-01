import XCTest
@testable import PeerDrop

final class TransferMetadataTests: XCTestCase {

    func testCodableRoundTrip() throws {
        let metadata = TransferMetadata(
            fileName: "test.pdf",
            fileSize: 1_048_576,
            mimeType: "application/pdf",
            sha256Hash: "abc123"
        )
        let data = try JSONEncoder().encode(metadata)
        let decoded = try JSONDecoder().decode(TransferMetadata.self, from: data)

        XCTAssertEqual(decoded.fileName, "test.pdf")
        XCTAssertEqual(decoded.fileSize, 1_048_576)
        XCTAssertEqual(decoded.mimeType, "application/pdf")
        XCTAssertEqual(decoded.sha256Hash, "abc123")
    }

    func testCodableWithNilMimeType() throws {
        let metadata = TransferMetadata(
            fileName: "photo.jpg",
            fileSize: 512,
            mimeType: nil,
            sha256Hash: "def456"
        )
        let data = try JSONEncoder().encode(metadata)
        let decoded = try JSONDecoder().decode(TransferMetadata.self, from: data)

        XCTAssertNil(decoded.mimeType)
        XCTAssertEqual(decoded.fileName, "photo.jpg")
    }

    func testCodableWithDirectory() throws {
        let metadata = TransferMetadata(
            fileName: "MyFolder.zip",
            fileSize: 2_048,
            mimeType: nil,
            sha256Hash: "dir123",
            isDirectory: true
        )
        let data = try JSONEncoder().encode(metadata)
        let decoded = try JSONDecoder().decode(TransferMetadata.self, from: data)

        XCTAssertTrue(decoded.isDirectory)
        XCTAssertEqual(decoded.displayName, "MyFolder")
        XCTAssertEqual(decoded.fileName, "MyFolder.zip")
    }

    func testDisplayNameForRegularFile() {
        let metadata = TransferMetadata(
            fileName: "report.pdf",
            fileSize: 1024,
            mimeType: nil,
            sha256Hash: "file123"
        )
        XCTAssertFalse(metadata.isDirectory)
        XCTAssertEqual(metadata.displayName, "report.pdf")
    }

    func testFormattedSize() {
        let small = TransferMetadata(fileName: "a.txt", fileSize: 500, mimeType: nil, sha256Hash: "x")
        XCTAssertFalse(small.formattedSize.isEmpty)

        let large = TransferMetadata(fileName: "b.zip", fileSize: 1_073_741_824, mimeType: nil, sha256Hash: "y")
        XCTAssertTrue(large.formattedSize.contains("GB") || large.formattedSize.contains("G"))
    }
}
