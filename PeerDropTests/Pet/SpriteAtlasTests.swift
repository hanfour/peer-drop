import XCTest
import ZIPFoundation
@testable import PeerDrop

final class SpriteAtlasTests: XCTestCase {

    // MARK: - Fixture helpers

    private func writeZip(
        atlasJSON: Data?,
        atlasPNG: Data? = nil,
        extraEntries: [String: Data] = [:]
    ) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("peerdrop-atlas-\(UUID()).zip")
        let archive = try Archive(url: url, accessMode: .create)
        if let atlasJSON {
            try archive.addEntry(
                with: SpriteAtlas.manifestEntry,
                type: .file,
                uncompressedSize: Int64(atlasJSON.count),
                provider: { position, size in
                    atlasJSON.subdata(in: Int(position)..<Int(position) + size)
                })
        }
        if let atlasPNG {
            try archive.addEntry(
                with: SpriteAtlas.imageEntry,
                type: .file,
                uncompressedSize: Int64(atlasPNG.count),
                provider: { position, size in
                    atlasPNG.subdata(in: Int(position)..<Int(position) + size)
                })
        }
        for (path, data) in extraEntries {
            try archive.addEntry(
                with: path,
                type: .file,
                uncompressedSize: Int64(data.count),
                provider: { position, size in
                    data.subdata(in: Int(position)..<Int(position) + size)
                })
        }
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    private func validAtlasJSON(
        version: Int = 1,
        frameSize: (Int, Int) = (68, 68),
        frames: [String: (Int, Int, Int, Int)] = [
            "rotations/south.png": (0, 0, 68, 68),
            "rotations/east.png": (68, 0, 68, 68),
        ]
    ) -> Data {
        let framesObj = frames.mapValues { rect -> [String: Int] in
            ["x": rect.0, "y": rect.1, "w": rect.2, "h": rect.3]
        }
        let obj: [String: Any] = [
            "atlas_version": version,
            "frame_size": ["width": frameSize.0, "height": frameSize.1],
            "frames": framesObj,
        ]
        return try! JSONSerialization.data(withJSONObject: obj, options: .sortedKeys)
    }

    // MARK: - Parse: absence is not an error

    func test_parse_returnsNil_whenZipHasNoAtlasJson() throws {
        let url = try writeZip(atlasJSON: nil, extraEntries: [
            "metadata.json": Data("{}".utf8),
        ])
        XCTAssertNil(try SpriteAtlas.parse(zipURL: url))
    }

    // MARK: - Parse: happy path

    func test_parse_returnsAtlas_withFrameSizeAndRectMap() throws {
        let url = try writeZip(atlasJSON: validAtlasJSON())
        let atlas = try XCTUnwrap(try SpriteAtlas.parse(zipURL: url))

        XCTAssertEqual(atlas.atlasVersion, 1)
        XCTAssertEqual(atlas.frameSize, SpriteAtlas.FrameSize(width: 68, height: 68))
        XCTAssertEqual(atlas.frames.count, 2)

        let south = try XCTUnwrap(atlas.rect(for: "rotations/south.png"))
        XCTAssertEqual(south, SpriteAtlas.Rect(x: 0, y: 0, w: 68, h: 68))

        let east = try XCTUnwrap(atlas.rect(for: "rotations/east.png"))
        XCTAssertEqual(east, SpriteAtlas.Rect(x: 68, y: 0, w: 68, h: 68))

        XCTAssertNil(atlas.rect(for: "rotations/north.png"))
    }

    func test_parse_rect_bridgesToCGRectForCropping() throws {
        let url = try writeZip(atlasJSON: validAtlasJSON(
            frames: ["rotations/south.png": (10, 20, 30, 40)]
        ))
        let atlas = try XCTUnwrap(try SpriteAtlas.parse(zipURL: url))
        let rect = try XCTUnwrap(atlas.rect(for: "rotations/south.png"))
        XCTAssertEqual(rect.cgRect, CGRect(x: 10, y: 20, width: 30, height: 40))
    }

    // MARK: - Parse: error paths

    func test_parse_throwsUnsupportedAtlasVersion_onFutureSchema() throws {
        let url = try writeZip(atlasJSON: validAtlasJSON(version: 99))
        XCTAssertThrowsError(try SpriteAtlas.parse(zipURL: url)) { error in
            guard case SpriteAtlasError.unsupportedAtlasVersion(let v) = error else {
                return XCTFail("expected unsupportedAtlasVersion, got \(error)")
            }
            XCTAssertEqual(v, 99)
        }
    }

    func test_parse_throwsDecodeFailed_onMalformedJSON() throws {
        let url = try writeZip(atlasJSON: Data("{not json".utf8))
        XCTAssertThrowsError(try SpriteAtlas.parse(zipURL: url)) { error in
            guard case SpriteAtlasError.atlasJSONDecodeFailed = error else {
                return XCTFail("expected atlasJSONDecodeFailed, got \(error)")
            }
        }
    }

    func test_parse_throwsDecodeFailed_whenRequiredFieldMissing() throws {
        // Missing "frame_size" should fail decoding.
        let payload: [String: Any] = ["atlas_version": 1, "frames": [:]]
        let bad = try JSONSerialization.data(withJSONObject: payload, options: [])
        let url = try writeZip(atlasJSON: bad)
        XCTAssertThrowsError(try SpriteAtlas.parse(zipURL: url)) { error in
            guard case SpriteAtlasError.atlasJSONDecodeFailed = error else {
                return XCTFail("expected atlasJSONDecodeFailed, got \(error)")
            }
        }
    }

    func test_parse_throwsZipOpenFailed_onMissingZip() {
        let url = URL(fileURLWithPath: "/tmp/peerdrop-atlas-does-not-exist-\(UUID()).zip")
        XCTAssertThrowsError(try SpriteAtlas.parse(zipURL: url)) { error in
            guard case SpriteAtlasError.zipOpenFailed = error else {
                return XCTFail("expected zipOpenFailed, got \(error)")
            }
        }
    }
}
