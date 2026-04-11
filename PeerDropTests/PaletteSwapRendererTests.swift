import XCTest
import SwiftUI
@testable import PeerDrop

final class PaletteSwapRendererTests: XCTestCase {

    func testRenderProducesCorrectSize() {
        let indices: [[UInt8]] = Array(repeating: Array(repeating: 2, count: 16), count: 16)
        let palette = PetPalettes.all[0]
        let image = PaletteSwapRenderer.render(indices: indices, palette: palette)
        XCTAssertNotNil(image)
        XCTAssertEqual(image?.width, 16)
        XCTAssertEqual(image?.height, 16)
    }

    func testTransparentPixelsAreAlphaZero() {
        let indices: [[UInt8]] = Array(repeating: Array(repeating: 0, count: 16), count: 16)
        let palette = PetPalettes.all[0]
        let image = PaletteSwapRenderer.render(indices: indices, palette: palette)!

        var pixel = [UInt8](repeating: 0, count: 4)
        let context = CGContext(data: &pixel, width: 1, height: 1,
                                bitsPerComponent: 8, bytesPerRow: 4,
                                space: CGColorSpaceCreateDeviceRGB(),
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.draw(image, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        XCTAssertEqual(pixel[3], 0, "Alpha should be 0 for transparent pixel")
    }

    func testScaleUpProducesLargerImage() {
        let indices: [[UInt8]] = Array(repeating: Array(repeating: 1, count: 16), count: 16)
        let palette = PetPalettes.all[0]
        let image = PaletteSwapRenderer.render(indices: indices, palette: palette, scale: 8)
        XCTAssertEqual(image?.width, 128)
        XCTAssertEqual(image?.height, 128)
    }
}
