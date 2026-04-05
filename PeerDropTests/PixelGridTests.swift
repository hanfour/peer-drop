import XCTest
@testable import PeerDrop

final class PixelGridTests: XCTestCase {

    func testEmptyGrid() {
        let grid = PixelGrid.empty()
        XCTAssertEqual(grid.size, 32)
        XCTAssertEqual(grid.activePixelCount, 0)
        for row in grid.pixels {
            for pixel in row {
                XCTAssertEqual(pixel, 0)
            }
        }
    }

    func testSetPixel() {
        var grid = PixelGrid.empty()
        grid.setPixel(x: 10, y: 20, value: 2)
        XCTAssertEqual(grid.pixels[20][10], 2)
        XCTAssertEqual(grid.activePixelCount, 1)
    }

    func testSetPixelDefaultValue() {
        var grid = PixelGrid.empty()
        grid.setPixel(x: 5, y: 5)
        XCTAssertEqual(grid.pixels[5][5], 1)
    }

    func testSetPixelOutOfBoundsIsIgnored() {
        var grid = PixelGrid.empty()
        grid.setPixel(x: 100, y: 100, value: 1)
        grid.setPixel(x: -1, y: 0, value: 1)
        grid.setPixel(x: 0, y: -1, value: 1)
        grid.setPixel(x: 32, y: 0, value: 1)
        XCTAssertEqual(grid.activePixelCount, 0)
    }

    func testDrawCircle() {
        var grid = PixelGrid.empty()
        grid.drawCircle(center: (16, 16), radius: 5, value: 2)
        XCTAssertEqual(grid.pixels[16][16], 2)
        XCTAssertFalse(grid.pixels[0][0] != 0)
        XCTAssertTrue(grid.activePixelCount > 0)
    }

    func testDrawRect() {
        var grid = PixelGrid.empty()
        grid.drawRect(origin: (10, 10), size: (4, 3), value: 3)
        XCTAssertEqual(grid.pixels[10][10], 3)
        XCTAssertEqual(grid.pixels[10][13], 3)
        XCTAssertEqual(grid.pixels[12][10], 3)
        XCTAssertEqual(grid.pixels[12][13], 3)
        XCTAssertEqual(grid.pixels[9][10], 0)
        XCTAssertEqual(grid.pixels[10][14], 0)
    }

    func testMirrorHorizontal() {
        var grid = PixelGrid.empty()
        grid.setPixel(x: 0, y: 0, value: 1)
        grid.mirror(axis: .horizontal)
        XCTAssertEqual(grid.pixels[0][0], 1)
        XCTAssertEqual(grid.pixels[0][31], 1)
    }

    func testPixelCount() {
        var grid = PixelGrid.empty()
        XCTAssertEqual(grid.activePixelCount, 0)
        grid.drawRect(origin: (0, 0), size: (2, 2), value: 1)
        XCTAssertEqual(grid.activePixelCount, 4)
    }

    func testDrawLine() {
        var grid = PixelGrid.empty()
        grid.drawLine(from: (0, 0), to: (5, 0), value: 4)
        for x in 0...5 {
            XCTAssertEqual(grid.pixels[0][x], 4, "Pixel at (\(x), 0) should be 4")
        }
        XCTAssertEqual(grid.activePixelCount, 6)
    }

    func testDrawEllipse() {
        var grid = PixelGrid.empty()
        grid.drawEllipse(center: (16, 16), rx: 8, ry: 4, value: 2)
        XCTAssertEqual(grid.pixels[16][16], 2)
        XCTAssertTrue(grid.activePixelCount > 0)
        XCTAssertEqual(grid.pixels[16][8], 2)  // cx - rx
        XCTAssertEqual(grid.pixels[16][24], 2)  // cx + rx
        XCTAssertEqual(grid.pixels[6][16], 0)   // cy - 10 should not be set (ry=4)
    }

    func testMirrorVertical() {
        var grid = PixelGrid.empty()
        grid.setPixel(x: 5, y: 0, value: 1)
        grid.mirror(axis: .vertical)
        XCTAssertEqual(grid.pixels[0][5], 1)
        XCTAssertEqual(grid.pixels[31][5], 1)
    }

    func testStampTemplate() {
        var grid = PixelGrid.empty()
        let template: [[Int]] = [
            [0, 1, 0],
            [1, 2, 1],
            [0, 1, 0]
        ]
        grid.stamp(template: template, at: (10, 10))
        XCTAssertEqual(grid.pixels[10][11], 1)
        XCTAssertEqual(grid.pixels[11][11], 2)
        XCTAssertEqual(grid.pixels[10][10], 0) // transparent stays 0
    }

    func testStampTemplateSkipsZero() {
        var grid = PixelGrid.empty()
        grid.setPixel(x: 10, y: 10, value: 3) // pre-existing pixel
        let template: [[Int]] = [[0]]
        grid.stamp(template: template, at: (10, 10))
        XCTAssertEqual(grid.pixels[10][10], 3) // should NOT be overwritten
    }
}
