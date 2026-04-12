import XCTest
@testable import PeerDrop

final class SpriteSheetLoaderTests: XCTestCase {

    func testSlice4FrameStrip() throws {
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
        let strip = TestSpriteHelper.make(width: 50, height: 16, fillIndex: 1)
        XCTAssertThrowsError(try SpriteSheetLoader.slice(strip: strip, frameSize: 16))
    }

    func testReadPixelIndices() throws {
        let img = TestSpriteHelper.make(width: 16, height: 16, fillIndex: 5)
        let indices = SpriteSheetLoader.readIndices(from: img)
        XCTAssertEqual(indices.count, 16)
        XCTAssertEqual(indices[0].count, 16)
        XCTAssertEqual(indices[0][0], 5)
    }

    func testLoadActionThrowsForMissingAsset() {
        XCTAssertThrowsError(try SpriteSheetLoader.loadAction(body: .cat, stage: .baby, action: .idle))
    }
}
