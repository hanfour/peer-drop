import XCTest
import ZIPFoundation
@testable import PeerDrop

final class SpriteDecoderTests: XCTestCase {

    private var testBundle: Bundle { Bundle(for: type(of: self)) }
    private var catTabbyAdultZip: URL {
        testBundle.url(forResource: "cat-tabby-adult", withExtension: "zip")!
    }

    func test_decode_catTabbyAdult_returnsAll8Directions() throws {
        let images = try SpriteDecoder.decode(zipURL: catTabbyAdultZip)
        XCTAssertEqual(images.count, 8)
        for direction in SpriteDirection.allCases {
            XCTAssertNotNil(images[direction], "missing direction: \(direction)")
        }
    }

    func test_decode_eachDirection_is68x68() throws {
        let images = try SpriteDecoder.decode(zipURL: catTabbyAdultZip)
        for direction in SpriteDirection.allCases {
            let cg = try XCTUnwrap(images[direction])
            XCTAssertEqual(cg.width,  68, "\(direction) width")
            XCTAssertEqual(cg.height, 68, "\(direction) height")
        }
    }

    func test_decode_distinctDirections_returnDistinctImages() throws {
        // east.png and west.png are not horizontal mirrors of each other —
        // they are independent PixelLab gens. Pin this so a future "let's just
        // flip east for west" optimization is intentional.
        let images = try SpriteDecoder.decode(zipURL: catTabbyAdultZip)
        let east = try XCTUnwrap(images[.east])
        let west = try XCTUnwrap(images[.west])
        XCTAssertFalse(cgImagesIdentical(east, west),
                       "east and west should be distinct sprite frames in the zip")
    }

    func test_decode_nonExistentURL_throws() {
        let badURL = URL(fileURLWithPath: "/tmp/peerdrop-decoder-test-nonexistent.zip")
        XCTAssertThrowsError(try SpriteDecoder.decode(zipURL: badURL))
    }

    func test_decode_partialZip_skipsMissingEntries() throws {
        // Build a zip containing ONLY rotations/south.png and verify the
        // decoder returns a partial dict (1 entry, south present, others nil)
        // rather than throwing. This is the contract that
        // SpriteService.directionMissing relies on — without partial-zip
        // support, that code path would never fire and the defensive guard
        // would be dead code. With it, a partial asset shipped through the
        // pipeline surfaces as a typed throw at the SpriteService boundary.
        let tempZipURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("peerdrop-decoder-partial-\(UUID()).zip")
        defer { try? FileManager.default.removeItem(at: tempZipURL) }

        // Re-use one PNG from the bundled fixture — we only care that a valid
        // PNG exists at the entry path, not what it depicts.
        let fixtureArchive = try Archive(url: catTabbyAdultZip, accessMode: .read)
        let southEntry = try XCTUnwrap(fixtureArchive["rotations/south.png"])
        var pngData = Data()
        _ = try fixtureArchive.extract(southEntry) { chunk in pngData.append(chunk) }

        let partial = try Archive(url: tempZipURL, accessMode: .create)
        try partial.addEntry(
            with: "rotations/south.png",
            type: .file,
            uncompressedSize: Int64(pngData.count),
            provider: { position, size in
                pngData.subdata(in: Int(position)..<Int(position) + size)
            })

        let images = try SpriteDecoder.decode(zipURL: tempZipURL)
        XCTAssertEqual(images.count, 1)
        XCTAssertNotNil(images[.south])
        for missing in SpriteDirection.allCases where missing != .south {
            XCTAssertNil(images[missing], "expected \(missing) to be missing")
        }
    }

    func test_decode_corruptedData_throws() throws {
        // Write a not-actually-a-zip file and try to open it.
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("peerdrop-decoder-test-corrupt-\(UUID()).zip")
        try Data("this is not a zip".utf8).write(to: tempURL)
        defer { try? FileManager.default.removeItem(at: tempURL) }
        XCTAssertThrowsError(try SpriteDecoder.decode(zipURL: tempURL))
    }

    // MARK: - helpers

    private func cgImagesIdentical(_ a: CGImage, _ b: CGImage) -> Bool {
        guard a.width == b.width, a.height == b.height else { return false }
        guard let dataA = a.dataProvider?.data, let dataB = b.dataProvider?.data else { return false }
        return CFEqual(dataA, dataB)
    }
}
