import XCTest
@testable import PeerDrop

final class PlatformGraphicsRendererTests: XCTestCase {
    func test_drawsIntoContext_andReturnsImageWithCGImage() {
        let renderer = PlatformGraphicsRenderer(size: CGSize(width: 10, height: 10))
        let image = renderer.image { ctx in
            ctx.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
            ctx.fill(CGRect(x: 0, y: 0, width: 10, height: 10))
        }
        XCTAssertNotNil(image)
        XCTAssertNotNil(image.platformCGImage, "PlatformImage should be CGImage-backed")
    }

    func test_producesDeterministicOutput() {
        let renderer1 = PlatformGraphicsRenderer(size: CGSize(width: 4, height: 4))
        let renderer2 = PlatformGraphicsRenderer(size: CGSize(width: 4, height: 4))
        let drawing: (CGContext) -> Void = { ctx in
            ctx.setFillColor(CGColor(red: 0, green: 1, blue: 0, alpha: 1))
            ctx.fill(CGRect(x: 0, y: 0, width: 4, height: 4))
        }
        let img1 = renderer1.image(drawing: drawing)
        let img2 = renderer2.image(drawing: drawing)
        XCTAssertEqual(img1.platformCGImage?.dataProvider?.data,
                       img2.platformCGImage?.dataProvider?.data,
                       "PetRendererV3 caching contract requires deterministic output")
    }
}
