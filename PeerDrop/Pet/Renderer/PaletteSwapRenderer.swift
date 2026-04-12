import UIKit
import SwiftUI

enum PaletteSwapRenderer {

    /// Convert indexed pixel grid to a CGImage using the given palette.
    static func render(indices: [[UInt8]], palette: ColorPalette, scale: Int = 1) -> CGImage? {
        let h = indices.count
        guard h > 0 else { return nil }
        let w = indices[0].count
        let outW = w * scale
        let outH = h * scale

        var pixels = [UInt8](repeating: 0, count: outW * outH * 4)

        // Build lookup table: index -> (r, g, b, a)
        var lut = [(UInt8, UInt8, UInt8, UInt8)](repeating: (0, 0, 0, 0), count: 16)
        for slot in 1...6 {
            if let color = palette.color(for: slot) {
                let resolved = UIColor(color)
                var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
                resolved.getRed(&r, green: &g, blue: &b, alpha: &a)
                lut[slot] = (UInt8(r * 255), UInt8(g * 255), UInt8(b * 255), UInt8(a * 255))
            }
        }

        for y in 0..<h {
            for x in 0..<w {
                let idx = Int(indices[y][x])
                guard idx > 0, idx < lut.count else { continue }
                let (r, g, b, a) = lut[idx]
                for sy in 0..<scale {
                    for sx in 0..<scale {
                        let offset = ((y * scale + sy) * outW + (x * scale + sx)) * 4
                        pixels[offset] = r
                        pixels[offset + 1] = g
                        pixels[offset + 2] = b
                        pixels[offset + 3] = a
                    }
                }
            }
        }

        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(
            data: &pixels, width: outW, height: outH,
            bitsPerComponent: 8, bytesPerRow: outW * 4,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }

        return context.makeImage()
    }
}
