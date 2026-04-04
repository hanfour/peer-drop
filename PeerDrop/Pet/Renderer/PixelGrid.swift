import Foundation

// MARK: - Axis

enum Axis {
    case horizontal
    case vertical
}

// MARK: - PixelGrid

struct PixelGrid: Equatable {
    let size: Int
    var pixels: [[Bool]]

    static func empty(size: Int = 64) -> PixelGrid {
        PixelGrid(size: size, pixels: Array(repeating: Array(repeating: false, count: size), count: size))
    }

    var activePixelCount: Int {
        pixels.reduce(0) { $0 + $1.filter { $0 }.count }
    }

    // MARK: - Drawing Primitives

    mutating func setPixel(x: Int, y: Int, value: Bool = true) {
        guard x >= 0, x < size, y >= 0, y < size else { return }
        pixels[y][x] = value
    }

    mutating func drawCircle(center: (Int, Int), radius: Int) {
        drawEllipse(center: center, rx: radius, ry: radius)
    }

    mutating func drawEllipse(center: (Int, Int), rx: Int, ry: Int) {
        let cx = center.0
        let cy = center.1
        guard rx > 0, ry > 0 else { return }
        for y in (cy - ry)...(cy + ry) {
            for x in (cx - rx)...(cx + rx) {
                let dx = x - cx
                let dy = y - cy
                // Inside ellipse: (dx/rx)^2 + (dy/ry)^2 <= 1
                if dx * dx * ry * ry + dy * dy * rx * rx <= rx * rx * ry * ry {
                    setPixel(x: x, y: y)
                }
            }
        }
    }

    mutating func drawRect(origin: (Int, Int), size: (Int, Int)) {
        let ox = origin.0
        let oy = origin.1
        for y in oy..<(oy + size.1) {
            for x in ox..<(ox + size.0) {
                setPixel(x: x, y: y)
            }
        }
    }

    mutating func drawLine(from: (Int, Int), to: (Int, Int)) {
        // Bresenham's line algorithm
        var x0 = from.0
        var y0 = from.1
        let x1 = to.0
        let y1 = to.1

        let dx = abs(x1 - x0)
        let dy = -abs(y1 - y0)
        let sx = x0 < x1 ? 1 : -1
        let sy = y0 < y1 ? 1 : -1
        var err = dx + dy

        while true {
            setPixel(x: x0, y: y0)
            if x0 == x1 && y0 == y1 { break }
            let e2 = 2 * err
            if e2 >= dy {
                err += dy
                x0 += sx
            }
            if e2 <= dx {
                err += dx
                y0 += sy
            }
        }
    }

    mutating func mirror(axis: Axis) {
        switch axis {
        case .horizontal:
            for y in 0..<size {
                for x in 0..<(size / 2) {
                    let mirrorX = size - 1 - x
                    if pixels[y][x] {
                        pixels[y][mirrorX] = true
                    } else if pixels[y][mirrorX] {
                        pixels[y][x] = true
                    }
                }
            }
        case .vertical:
            for y in 0..<(size / 2) {
                let mirrorY = size - 1 - y
                for x in 0..<size {
                    if pixels[y][x] {
                        pixels[mirrorY][x] = true
                    } else if pixels[mirrorY][x] {
                        pixels[y][x] = true
                    }
                }
            }
        }
    }
}
