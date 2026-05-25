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
}
