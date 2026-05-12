import XCTest
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import ZIPFoundation
@testable import PeerDrop

/// End-to-end tests for the atlas read path inside `SpriteService` and
/// `SpriteDecoder`. Fixtures are built in-process: a synthetic atlas zip
/// with known-colored frames lets us assert that the atlas slice path
/// returns the expected pixel data, independent of the Python builder.
///
/// The Python builder is unit-tested separately (Scripts/test_build_atlas.py).
/// These Swift tests pin the *reader* side: given a well-formed atlas, the
/// service must return frames whose pixels match the atlas slot the
/// metadata path maps to.
final class SpriteAtlasIntegrationTests: XCTestCase {

    private let frameSize = 4  // 4×4 cells keep fixtures tiny + readable

    // MARK: - Fixture builder

    /// Build an in-memory atlas zip with:
    ///   • two rotation cells (south, east)
    ///   • a 2-frame walk animation in the "south" direction
    /// Each cell is a distinct solid color so the test can verify the
    /// slice path returned the right rect (a bug would surface as a
    /// neighbor's color bleeding through).
    private func buildAtlasZipFixture() throws -> URL {
        // Colors: (r, g, b) per cell. Indices correspond to atlas slot order.
        // slot 0 = rotations/south.png  → red
        // slot 1 = rotations/east.png   → green
        // slot 2 = walk south frame 0   → blue
        // slot 3 = walk south frame 1   → yellow
        let cells: [(r: UInt8, g: UInt8, b: UInt8)] = [
            (255, 0, 0),
            (0, 255, 0),
            (0, 0, 255),
            (255, 255, 0),
        ]
        // Grid is 2×2 (square-ish for 4 cells)
        let cols = 2
        let rows = 2
        let atlasW = cols * frameSize
        let atlasH = rows * frameSize

        // Construct atlas.png in RGBA pixel order, row-major, top-to-bottom.
        // For each pixel: determine which cell it lives in, paint that
        // cell's color.
        var pixels = [UInt8](repeating: 0, count: atlasW * atlasH * 4)
        for y in 0..<atlasH {
            for x in 0..<atlasW {
                let col = x / frameSize
                let row = y / frameSize
                let slot = row * cols + col
                let p = (y * atlasW + x) * 4
                pixels[p + 0] = cells[slot].r
                pixels[p + 1] = cells[slot].g
                pixels[p + 2] = cells[slot].b
                pixels[p + 3] = 255
            }
        }
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let ctx = CGContext(
            data: &pixels,
            width: atlasW,
            height: atlasH,
            bitsPerComponent: 8,
            bytesPerRow: atlasW * 4,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        let cgImage = ctx.makeImage()!

        // Encode to PNG bytes.
        let pngData = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(
            pngData, UTType.png.identifier as CFString, 1, nil
        ) else {
            throw XCTSkip("CGImageDestination could not create PNG encoder")
        }
        CGImageDestinationAddImage(dest, cgImage, nil)
        XCTAssertTrue(CGImageDestinationFinalize(dest))

        // Build atlas.json — note slot rects use top-left origin
        // (matching the Python generator).
        let frames: [String: [String: Int]] = [
            "rotations/south.png": ["x": 0, "y": 0, "w": frameSize, "h": frameSize],
            "rotations/east.png": ["x": frameSize, "y": 0, "w": frameSize, "h": frameSize],
            "animations/walk/south/frame_000.png": ["x": 0, "y": frameSize, "w": frameSize, "h": frameSize],
            "animations/walk/south/frame_001.png": ["x": frameSize, "y": frameSize, "w": frameSize, "h": frameSize],
        ]
        let atlasJSON: [String: Any] = [
            "atlas_version": 1,
            "frame_size": ["width": frameSize, "height": frameSize],
            "frames": frames,
        ]
        let atlasJSONData = try JSONSerialization.data(withJSONObject: atlasJSON, options: .sortedKeys)

        // Build metadata.json — the existing SpriteMetadata parser needs
        // the v3.0 schema to surface the animation block.
        let metadataObj: [String: Any] = [
            "character": ["size": ["width": frameSize, "height": frameSize], "directions": 8],
            "frames": [
                "rotations": [
                    "south": "rotations/south.png",
                    "east": "rotations/east.png",
                ],
                "animations": [
                    "walk": [
                        "fps": 6,
                        "frame_count": 2,
                        "loops": true,
                        "directions": [
                            "south": [
                                "animations/walk/south/frame_000.png",
                                "animations/walk/south/frame_001.png",
                            ],
                        ],
                    ],
                ],
            ],
            "export_version": "3.0",
        ]
        let metadataData = try JSONSerialization.data(withJSONObject: metadataObj, options: [])

        // Write zip: atlas.png + atlas.json + metadata.json. No per-frame
        // PNGs — this exercises the atlas-only ("stripped") shape that
        // production assets eventually land in.
        let zipURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("peerdrop-atlas-integration-\(UUID()).zip")
        let archive = try Archive(url: zipURL, accessMode: .create)
        let pngBytes = pngData as Data
        try archive.addEntry(
            with: SpriteAtlas.imageEntry,
            type: .file,
            uncompressedSize: Int64(pngBytes.count),
            provider: { position, size in
                pngBytes.subdata(in: Int(position)..<Int(position) + size)
            })
        try archive.addEntry(
            with: SpriteAtlas.manifestEntry,
            type: .file,
            uncompressedSize: Int64(atlasJSONData.count),
            provider: { position, size in
                atlasJSONData.subdata(in: Int(position)..<Int(position) + size)
            })
        try archive.addEntry(
            with: "metadata.json",
            type: .file,
            uncompressedSize: Int64(metadataData.count),
            provider: { position, size in
                metadataData.subdata(in: Int(position)..<Int(position) + size)
            })
        addTeardownBlock { try? FileManager.default.removeItem(at: zipURL) }
        return zipURL
    }

    /// Read the top-left pixel of a CGImage. Slicing via cropping(to:)
    /// shares the atlas backing store, so the first pixel of a sliced
    /// frame must match the color we painted into that atlas cell.
    struct Pixel: Equatable {
        let r: UInt8
        let g: UInt8
        let b: UInt8
    }

    private func firstPixel(of image: CGImage) -> Pixel {
        guard let data = image.dataProvider?.data as Data?,
              data.count >= 3 else { return Pixel(r: 0, g: 0, b: 0) }
        return Pixel(r: data[0], g: data[1], b: data[2])
    }

    // MARK: - Atlas mode: SpriteDecoder rotations

    func test_decoder_atlasMode_slicesRotationsByColor() throws {
        let zipURL = try buildAtlasZipFixture()
        let images = try SpriteDecoder.decode(zipURL: zipURL)

        XCTAssertEqual(images.count, 2, "fixture ships south + east only")
        let south = try XCTUnwrap(images[.south])
        let east = try XCTUnwrap(images[.east])

        XCTAssertEqual(south.width, frameSize)
        XCTAssertEqual(south.height, frameSize)
        XCTAssertEqual(firstPixel(of: south), Pixel(r: 255, g: 0, b: 0), "south slot is red")
        XCTAssertEqual(firstPixel(of: east), Pixel(r: 0, g: 255, b: 0), "east slot is green")
    }

    // MARK: - Atlas mode: SpriteService animations

    func test_service_atlasMode_returnsWalkFramesInOrder() async throws {
        let zipURL = try buildAtlasZipFixture()
        let service = SpriteService()
        let request = AnimationRequest(
            species: SpeciesID("ignored-by-internal-seam"),
            stage: .baby,
            direction: .south,
            action: .walking
        )

        let frames = try await service.framesInternal(at: zipURL, for: request)

        XCTAssertEqual(frames.images.count, 2, "fixture ships walk/south with 2 frames")
        XCTAssertEqual(frames.fps, 6)
        XCTAssertTrue(frames.loops)
        XCTAssertEqual(firstPixel(of: frames.images[0]), Pixel(r: 0, g: 0, b: 255),
                       "frame 0 should slice from the blue atlas cell")
        XCTAssertEqual(firstPixel(of: frames.images[1]), Pixel(r: 255, g: 255, b: 0),
                       "frame 1 should slice from the yellow atlas cell")
    }

    // MARK: - Atlas mode: SpriteService fallback to rotation

    func test_service_atlasMode_fallsBackToRotation_whenActionNotInMetadata() async throws {
        let zipURL = try buildAtlasZipFixture()
        let service = SpriteService()
        let request = AnimationRequest(
            species: SpeciesID("ignored"),
            stage: .baby,
            direction: .south,
            action: .idle   // metadata has no idle block
        )

        let frames = try await service.framesInternal(at: zipURL, for: request)
        XCTAssertEqual(frames.images.count, 1, "fallback path returns 1-frame static")
        XCTAssertEqual(frames.fps, 1)
        XCTAssertFalse(frames.loops)
        XCTAssertEqual(firstPixel(of: frames.images[0]), Pixel(r: 255, g: 0, b: 0),
                       "rotation fallback returns the south cell (red)")
    }
}
