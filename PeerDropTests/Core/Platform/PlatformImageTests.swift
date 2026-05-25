import XCTest
@testable import PeerDrop

final class PlatformImageTests: XCTestCase {
    func test_typealiasResolvesToUIImageOnIOS() {
        let image: PlatformImage = PlatformImage()
        XCTAssertTrue(type(of: image) == PlatformImage.self)
    }

    func test_jpegDataExtensionReturnsData() {
        // 1x1 pixel red image
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: 1, height: 1))
        let image: PlatformImage = renderer.image { ctx in
            UIColor.red.setFill()
            ctx.fill(CGRect(x: 0, y: 0, width: 1, height: 1))
        }
        let data = image.platformJPEGData(compressionQuality: 0.8)
        XCTAssertNotNil(data)
        XCTAssertGreaterThan(data?.count ?? 0, 0)
    }

    func test_initWithCGImage_roundTrips() {
        // 2x2 red pixel CGImage
        let width = 2, height = 2
        let bitsPerComponent = 8
        let bytesPerRow = width * 4
        var bytes: [UInt8] = [
            255, 0, 0, 255,   255, 0, 0, 255,
            255, 0, 0, 255,   255, 0, 0, 255,
        ]
        let provider = CGDataProvider(data: Data(bytes: &bytes, count: bytes.count) as CFData)!
        let cgImage = CGImage(
            width: width, height: height,
            bitsPerComponent: bitsPerComponent, bitsPerPixel: 32,
            bytesPerRow: bytesPerRow,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
            provider: provider, decode: nil, shouldInterpolate: false,
            intent: .defaultIntent
        )!

        let image = PlatformImage(platformCGImage: cgImage, size: CGSize(width: 2, height: 2))
        XCTAssertNotNil(image)
    }

    func test_initWithSystemName_returnsImageForKnownSymbol() {
        let image = PlatformImage(platformSystemName: "circle.fill")
        XCTAssertNotNil(image, "circle.fill should resolve to an SF Symbol")
    }

    func test_initWithSystemName_returnsNilForUnknownSymbol() {
        let image = PlatformImage(platformSystemName: "this.symbol.does.not.exist.12345")
        XCTAssertNil(image)
    }

    func test_withTintColor_returnsNonNilImage() {
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: 10, height: 10))
        let source: PlatformImage = renderer.image { ctx in
            UIColor.white.setFill()
            ctx.fill(CGRect(x: 0, y: 0, width: 10, height: 10))
        }
        let tinted = source.platformWithTintColor(PlatformColor.red)
        XCTAssertNotNil(tinted)
    }
}
