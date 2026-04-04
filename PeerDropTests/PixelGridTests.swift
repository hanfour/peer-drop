import XCTest
@testable import PeerDrop

final class PixelGridTests: XCTestCase {

    func testEmptyGrid() {
        let grid = PixelGrid.empty()
        XCTAssertEqual(grid.size, 64)
        XCTAssertEqual(grid.activePixelCount, 0)
        for row in grid.pixels {
            for pixel in row {
                XCTAssertFalse(pixel)
            }
        }
    }

    func testSetPixel() {
        var grid = PixelGrid.empty()
        grid.setPixel(x: 10, y: 20)
        XCTAssertTrue(grid.pixels[20][10])
        XCTAssertEqual(grid.activePixelCount, 1)
    }

    func testSetPixelOutOfBoundsIsIgnored() {
        var grid = PixelGrid.empty()
        grid.setPixel(x: 100, y: 100)
        grid.setPixel(x: -1, y: 0)
        grid.setPixel(x: 0, y: -1)
        grid.setPixel(x: 64, y: 0)
        XCTAssertEqual(grid.activePixelCount, 0)
    }

    func testDrawCircle() {
        var grid = PixelGrid.empty()
        grid.drawCircle(center: (32, 32), radius: 5)
        // Center should have a pixel
        XCTAssertTrue(grid.pixels[32][32])
        // Far corner should not
        XCTAssertFalse(grid.pixels[0][0])
        XCTAssertTrue(grid.activePixelCount > 0)
    }

    func testDrawRect() {
        var grid = PixelGrid.empty()
        grid.drawRect(origin: (10, 10), size: (4, 3))
        // Corners of the rect should have pixels
        XCTAssertTrue(grid.pixels[10][10])
        XCTAssertTrue(grid.pixels[10][13])
        XCTAssertTrue(grid.pixels[12][10])
        XCTAssertTrue(grid.pixels[12][13])
        // Outside the rect
        XCTAssertFalse(grid.pixels[9][10])
        XCTAssertFalse(grid.pixels[10][14])
    }

    func testMirrorHorizontal() {
        var grid = PixelGrid.empty()
        grid.setPixel(x: 0, y: 0)
        grid.mirror(axis: .horizontal)
        XCTAssertTrue(grid.pixels[0][0])
        XCTAssertTrue(grid.pixels[0][63])
    }

    func testPixelCount() {
        var grid = PixelGrid.empty()
        XCTAssertEqual(grid.activePixelCount, 0)
        grid.drawRect(origin: (0, 0), size: (2, 2))
        XCTAssertEqual(grid.activePixelCount, 4)
    }

    func testDrawLine() {
        var grid = PixelGrid.empty()
        grid.drawLine(from: (0, 0), to: (5, 0))
        // Horizontal line should have 6 pixels
        for x in 0...5 {
            XCTAssertTrue(grid.pixels[0][x], "Pixel at (\(x), 0) should be set")
        }
        XCTAssertEqual(grid.activePixelCount, 6)
    }

    func testDrawEllipse() {
        var grid = PixelGrid.empty()
        grid.drawEllipse(center: (32, 32), rx: 10, ry: 5)
        XCTAssertTrue(grid.pixels[32][32])
        XCTAssertTrue(grid.activePixelCount > 0)
        // Should be wider than tall
        // Check horizontal extent
        XCTAssertTrue(grid.pixels[32][22]) // cx - rx
        XCTAssertTrue(grid.pixels[32][42]) // cx + rx
        // Vertical extent should be smaller
        XCTAssertFalse(grid.pixels[22][32]) // cy - 10 should not be set (ry=5)
    }

    func testMirrorVertical() {
        var grid = PixelGrid.empty()
        grid.setPixel(x: 5, y: 0)
        grid.mirror(axis: .vertical)
        XCTAssertTrue(grid.pixels[0][5])
        XCTAssertTrue(grid.pixels[63][5])
    }
}
