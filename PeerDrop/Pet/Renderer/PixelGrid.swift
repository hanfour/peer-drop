import Foundation

// MARK: - Axis

enum Axis {
    case horizontal
    case vertical
}

// MARK: - PixelGrid

struct PixelGrid: Equatable {
    let size: Int
    var pixels: [[Int]]

    static func empty(size: Int = 32) -> PixelGrid {
        PixelGrid(size: size, pixels: Array(repeating: Array(repeating: 0, count: size), count: size))
    }

    var activePixelCount: Int {
        pixels.reduce(0) { $0 + $1.filter { $0 != 0 }.count }
    }

    // MARK: - Drawing Primitives

    mutating func setPixel(x: Int, y: Int, value: Int = 1) {
        guard x >= 0, x < size, y >= 0, y < size else { return }
        pixels[y][x] = value
    }

    mutating func drawCircle(center: (Int, Int), radius: Int, value: Int = 1) {
        drawEllipse(center: center, rx: radius, ry: radius, value: value)
    }

    mutating func drawEllipse(center: (Int, Int), rx: Int, ry: Int, value: Int = 1) {
        let cx = center.0
        let cy = center.1
        guard rx > 0, ry > 0 else { return }
        for y in (cy - ry)...(cy + ry) {
            for x in (cx - rx)...(cx + rx) {
                let dx = x - cx
                let dy = y - cy
                if dx * dx * ry * ry + dy * dy * rx * rx <= rx * rx * ry * ry {
                    setPixel(x: x, y: y, value: value)
                }
            }
        }
    }

    mutating func drawRect(origin: (Int, Int), size rectSize: (Int, Int), value: Int = 1) {
        let ox = origin.0
        let oy = origin.1
        for y in oy..<(oy + rectSize.1) {
            for x in ox..<(ox + rectSize.0) {
                setPixel(x: x, y: y, value: value)
            }
        }
    }

    mutating func drawLine(from: (Int, Int), to: (Int, Int), value: Int = 1) {
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
            setPixel(x: x0, y: y0, value: value)
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

    /// Stamps a 2D template onto the grid at the given top-left position.
    /// Zeros in the template are transparent (do not overwrite existing pixels).
    mutating func stamp(template: [[Int]], at origin: (Int, Int)) {
        for (row, line) in template.enumerated() {
            for (col, val) in line.enumerated() {
                guard val != 0 else { continue }
                setPixel(x: origin.0 + col, y: origin.1 + row, value: val)
            }
        }
    }

    mutating func mirror(axis: Axis) {
        switch axis {
        case .horizontal:
            for y in 0..<size {
                for x in 0..<(size / 2) {
                    let mirrorX = size - 1 - x
                    if pixels[y][x] != 0 {
                        pixels[y][mirrorX] = pixels[y][x]
                    } else if pixels[y][mirrorX] != 0 {
                        pixels[y][x] = pixels[y][mirrorX]
                    }
                }
            }
        case .vertical:
            for y in 0..<(size / 2) {
                let mirrorY = size - 1 - y
                for x in 0..<size {
                    if pixels[y][x] != 0 {
                        pixels[mirrorY][x] = pixels[y][x]
                    } else if pixels[mirrorY][x] != 0 {
                        pixels[y][x] = pixels[mirrorY][x]
                    }
                }
            }
        }
    }
}
