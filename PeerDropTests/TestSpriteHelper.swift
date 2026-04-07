import CoreGraphics

enum TestSpriteHelper {
    /// Create a CGImage filled with a single color index value (stored in red channel).
    static func make(width: Int, height: Int, fillIndex: UInt8) -> CGImage {
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        for i in 0..<(width * height) {
            pixels[i * 4] = fillIndex     // R = palette index
            pixels[i * 4 + 1] = 0        // G
            pixels[i * 4 + 2] = 0        // B
            pixels[i * 4 + 3] = 255      // A = opaque
        }
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let context = CGContext(data: &pixels, width: width, height: height,
                                bitsPerComponent: 8, bytesPerRow: width * 4,
                                space: colorSpace,
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        return context.makeImage()!
    }
}
