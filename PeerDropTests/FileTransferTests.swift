import XCTest
@testable import PeerDrop

final class FileTransferTests: XCTestCase {

    func testDataChunking() {
        let data = Data(repeating: 0xAB, count: 100)
        let chunks = data.chunks(ofSize: 30)

        XCTAssertEqual(chunks.count, 4) // 30 + 30 + 30 + 10
        XCTAssertEqual(chunks[0].count, 30)
        XCTAssertEqual(chunks[1].count, 30)
        XCTAssertEqual(chunks[2].count, 30)
        XCTAssertEqual(chunks[3].count, 10)
    }

    func testDataChunkingExactDivision() {
        let data = Data(repeating: 0xCD, count: 90)
        let chunks = data.chunks(ofSize: 30)

        XCTAssertEqual(chunks.count, 3)
        for chunk in chunks {
            XCTAssertEqual(chunk.count, 30)
        }
    }

    func testDataChunkingSingleChunk() {
        let data = Data(repeating: 0xEF, count: 10)
        let chunks = data.chunks(ofSize: 100)

        XCTAssertEqual(chunks.count, 1)
        XCTAssertEqual(chunks[0].count, 10)
    }

    func testDataChunkingEmpty() {
        let data = Data()
        let chunks = data.chunks(ofSize: 30)

        XCTAssertTrue(chunks.isEmpty)
    }

    func testChunksReassembleToOriginal() {
        let original = Data((0..<256).map { UInt8($0) })
        let chunks = original.chunks(ofSize: 64)

        var reassembled = Data()
        for chunk in chunks {
            reassembled.append(chunk)
        }

        XCTAssertEqual(reassembled, original)
    }

    func testDefaultChunkSize() {
        XCTAssertEqual(Data.defaultChunkSize, 64 * 1024)
    }

    func testTransferMetadataFormattedSize() {
        let metadata = TransferMetadata(
            fileName: "test.txt",
            fileSize: 1_048_576, // 1 MB
            mimeType: "text/plain",
            sha256Hash: "abc"
        )
        // ByteCountFormatter should produce something like "1 MB"
        XCTAssertFalse(metadata.formattedSize.isEmpty)
    }
}
