import UIKit

enum SpriteSheetError: Error {
    case invalidStripWidth
    case imageLoadFailed(String)
    case pixelReadFailed
}

enum SpriteSheetLoader {

    static let frameSize = 16

    /// Slice a horizontal strip into individual CGImage frames.
    static func slice(strip: CGImage, frameSize: Int = Self.frameSize) throws -> [CGImage] {
        let width = strip.width
        let height = strip.height
        guard width % frameSize == 0, height == frameSize else {
            throw SpriteSheetError.invalidStripWidth
        }
        let count = width / frameSize
        return try (0..<count).map { i in
            guard let frame = strip.cropping(to: CGRect(x: i * frameSize, y: 0,
                                                         width: frameSize, height: frameSize)) else {
                throw SpriteSheetError.pixelReadFailed
            }
            return frame
        }
    }

    /// Read the color indices from a grayscale/indexed CGImage into a 2D array.
    /// Each pixel's red channel value is treated as the palette index (0-15).
    static func readIndices(from image: CGImage) -> [[UInt8]] {
        let w = image.width
        let h = image.height
        var pixelData = [UInt8](repeating: 0, count: w * h * 4)
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(
            data: &pixelData, width: w, height: h,
            bitsPerComponent: 8, bytesPerRow: w * 4,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return [] }
        context.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))

        var result = [[UInt8]]()
        for y in 0..<h {
            var row = [UInt8]()
            for x in 0..<w {
                let offset = (y * w + x) * 4
                let r = pixelData[offset]     // use red channel as index
                let a = pixelData[offset + 3] // alpha
                row.append(a < 128 ? 0 : r)  // transparent = index 0
            }
            result.append(row)
        }
        return result
    }

    /// Load sprite strip for a body type + stage + action from bundle.
    static func loadAction(body: BodyGene, stage: PetLevel, action: PetAction) throws -> [[[UInt8]]] {
        let name = "\(body.rawValue)_\(stage.rawValue)_\(action.rawValue)"
        guard let url = Bundle.main.url(forResource: name, withExtension: "png"),
              let data = try? Data(contentsOf: url),
              let source = CGImage.from(pngData: data) else {
            throw SpriteSheetError.imageLoadFailed(name)
        }
        let frames = try slice(strip: source)
        return frames.map { readIndices(from: $0) }
    }
}

extension CGImage {
    static func from(pngData data: Data) -> CGImage? {
        guard let provider = CGDataProvider(data: data as CFData),
              let image = CGImage(pngDataProviderSource: provider,
                                  decode: nil, shouldInterpolate: false,
                                  intent: .defaultIntent) else { return nil }
        return image
    }
}
