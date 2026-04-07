import XCTest
@testable import PeerDrop

final class SpriteSheetLoaderTests: XCTestCase {

    func testSlice4FrameStrip() throws {
        // Create a 64x16 test image (4 frames of 16x16)
        let strip = TestSpriteHelper.make(width: 64, height: 16, fillIndex: 2)
        let frames = try SpriteSheetLoader.slice(strip: strip, frameSize: 16)
        XCTAssertEqual(frames.count, 4)
        for frame in frames {
            XCTAssertEqual(frame.width, 16)
            XCTAssertEqual(frame.height, 16)
        }
    }

    func testSliceSingleFrame() throws {
        let strip = TestSpriteHelper.make(width: 16, height: 16, fillIndex: 1)
        let frames = try SpriteSheetLoader.slice(strip: strip, frameSize: 16)
        XCTAssertEqual(frames.count, 1)
    }

    func testSliceInvalidWidthThrows() {
        // 50px wide is not divisible by 16
        let strip = TestSpriteHelper.make(width: 50, height: 16, fillIndex: 1)
        XCTAssertThrowsError(try SpriteSheetLoader.slice(strip: strip, frameSize: 16))
    }

    func testReadPixelIndices() throws {
        // Create a 16x16 image where pixel (0,0) = index 5
        let img = TestSpriteHelper.make(width: 16, height: 16, fillIndex: 5)
        let indices = SpriteSheetLoader.readIndices(from: img)
        XCTAssertEqual(indices.count, 16) // 16 rows
        XCTAssertEqual(indices[0].count, 16) // 16 cols
        XCTAssertEqual(indices[0][0], 5)
    }
}
