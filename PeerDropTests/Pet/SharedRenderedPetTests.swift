import XCTest
import CoreGraphics
@testable import PeerDrop

final class SharedRenderedPetTests: XCTestCase {

    private var bridge: SharedRenderedPet!

    override func setUp() {
        super.setUp()
        // Init with nil suite forces the per-process tempdir fallback so each
        // test gets its own container.
        bridge = SharedRenderedPet(suiteName: nil)
    }

    override func tearDown() {
        bridge.clear()
        bridge = nil
        super.tearDown()
    }

    // MARK: - basic round-trip

    func test_writeThenRead_returnsCGImageWithMatchingDimensions() {
        let original = makeStubImage(width: 68, height: 68, red: true)
        bridge.write(original)

        let loaded = bridge.read()
        XCTAssertNotNil(loaded)
        XCTAssertEqual(loaded?.width, 68)
        XCTAssertEqual(loaded?.height, 68)
    }

    func test_read_onMissingFile_returnsNil() {
        // setUp creates a fresh container; no write yet.
        XCTAssertNil(bridge.read())
    }

    func test_clear_removesFile_subsequentReadReturnsNil() {
        bridge.write(makeStubImage(width: 16, height: 16))
        XCTAssertNotNil(bridge.read())

        bridge.clear()
        XCTAssertNil(bridge.read())
    }

    // MARK: - last-write-wins

    func test_secondWrite_replacesFirst_observedDimensionsMatchSecond() {
        bridge.write(makeStubImage(width: 16, height: 16))
        bridge.write(makeStubImage(width: 64, height: 32))

        let loaded = bridge.read()
        XCTAssertEqual(loaded?.width, 64)
        XCTAssertEqual(loaded?.height, 32)
    }

    // MARK: - PNG round-trip preserves visible content

    func test_pngRoundTrip_preservesPixelColor_atSamplePoint() {
        // Encode a known-color image, read back, sample the centre pixel.
        // PNG round-trip should preserve the colour exactly (lossless).
        let original = makeStubImage(width: 4, height: 4, red: true)
        bridge.write(original)
        let loaded = try! XCTUnwrap(bridge.read())

        let originalSample = samplePixel(in: original, x: 1, y: 1)
        let loadedSample = samplePixel(in: loaded, x: 1, y: 1)
        XCTAssertEqual(originalSample.r, loadedSample.r, accuracy: 2,
                       "PNG round-trip should preserve red channel")
        XCTAssertEqual(originalSample.g, loadedSample.g, accuracy: 2)
        XCTAssertEqual(originalSample.b, loadedSample.b, accuracy: 2)
    }

    // MARK: - file location

    func test_fileURL_isUnderContainerRoot() {
        XCTAssertEqual(bridge.fileURL.lastPathComponent, "pet-rendered.png")
    }

    // MARK: - helpers

    /// N×M image filled with a solid colour.
    private func makeStubImage(width: Int, height: Int, red: Bool = true) -> CGImage {
        let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        context.setFillColor(red: red ? 1 : 0, green: 0, blue: red ? 0 : 1, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()!
    }

    /// Sample one RGBA pixel at (x, y) by drawing the image into a 1×1 context
    /// positioned to capture the desired source pixel.
    private func samplePixel(in image: CGImage, x: Int, y: Int) -> (r: Int, g: Int, b: Int, a: Int) {
        let cs = CGColorSpaceCreateDeviceRGB()
        let info = CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue
        var bytes = [UInt8](repeating: 0, count: 4)
        let ctx = CGContext(data: &bytes, width: 1, height: 1, bitsPerComponent: 8,
                             bytesPerRow: 4, space: cs, bitmapInfo: info)!
        ctx.draw(image,
                 in: CGRect(x: -x, y: -(image.height - y - 1), width: image.width, height: image.height))
        return (Int(bytes[0]), Int(bytes[1]), Int(bytes[2]), Int(bytes[3]))
    }
}
