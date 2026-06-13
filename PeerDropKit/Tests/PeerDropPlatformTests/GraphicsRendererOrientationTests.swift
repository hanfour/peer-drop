import XCTest
import CoreGraphics
@testable import PeerDropPlatform

/// Audit round 22: the macOS PlatformGraphicsRenderer used a bottom-left /
/// y-up `NSGraphicsContext(bitmapImageRep:)`, the OPPOSITE of UIKit's
/// top-left / y-down `UIGraphicsImageRenderer`. The shared pet-compositing
/// code (PetRendererV3) draws for a UIKit top-left context, so on macOS it
/// came out double-flipped and the pet rendered UPSIDE-DOWN (live finding
/// 2026-06-13, user-reported). This pins the renderer's coordinate system:
/// a rect drawn at the TOP-LEFT of the context must land at the TOP of the
/// output image on every platform.
final class GraphicsRendererOrientationTests: XCTestCase {

    func testTopLeftDrawLandsAtTopOfImage() throws {
        let size = CGSize(width: 8, height: 8)
        let renderer = PlatformGraphicsRenderer(size: size)
        let image = renderer.image { ctx in
            // Fill only the top-left 2×2 in a top-left-origin coordinate
            // system (y grows downward, as on iOS).
            ctx.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
            ctx.fill(CGRect(x: 0, y: 0, width: 2, height: 2))
        }
        let cg = try XCTUnwrap(image.platformCGImage, "renderer must produce a CGImage")
        XCTAssertEqual(cg.width, 8)
        XCTAssertEqual(cg.height, 8)

        // Read the alpha of a TOP pixel (row 1) and a BOTTOM pixel (row 6).
        // CGImage row 0 is the visual top. If the context were y-up the fill
        // would land at the bottom and this assertion would fail.
        let topAlpha = try alpha(of: cg, x: 1, y: 1)
        let bottomAlpha = try alpha(of: cg, x: 1, y: 6)
        XCTAssertGreaterThan(topAlpha, 0.5, "the top-left draw must appear at the TOP of the image")
        XCTAssertLessThan(bottomAlpha, 0.5, "nothing should be drawn at the bottom")
    }

    func testPlatformImageDrawKeepsOrientation() throws {
        // The mood SF Symbol overlay is drawn via PlatformImage.draw(in:)
        // (NSImage.draw on macOS), which honours NSGraphicsContext.isFlipped
        // rather than the CTM — so the round-22 CTM-only flip fixed the base
        // sprite but left the mood icon upside-down (round-23 user report).
        // Build a marker image whose TOP half is opaque, draw it full-canvas
        // through the renderer, and assert the top stays opaque.
        let side = 8
        let markerCG = try makeTopHalfOpaqueImage(side: side)
        let marker = try XCTUnwrap(
            PlatformImage(platformCGImage: markerCG, size: CGSize(width: side, height: side)))

        let renderer = PlatformGraphicsRenderer(size: CGSize(width: side, height: side))
        let out = renderer.image { _ in
            marker.draw(in: CGRect(x: 0, y: 0, width: side, height: side))
        }
        let cg = try XCTUnwrap(out.platformCGImage)
        let topAlpha = try alpha(of: cg, x: 4, y: 1)
        let bottomAlpha = try alpha(of: cg, x: 4, y: 6)
        XCTAssertGreaterThan(topAlpha, 0.5, "PlatformImage.draw must keep the top at the top (mood icon orientation)")
        XCTAssertLessThan(bottomAlpha, 0.5, "the transparent bottom half must stay at the bottom")
    }

    /// A `side`×`side` CGImage: top half opaque white, bottom half clear.
    private func makeTopHalfOpaqueImage(side: Int) throws -> CGImage {
        let cs = CGColorSpaceCreateDeviceRGB()
        let ctx = try XCTUnwrap(CGContext(
            data: nil, width: side, height: side,
            bitsPerComponent: 8, bytesPerRow: side * 4, space: cs,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        // Flip to top-left so "top half" means the visual top.
        ctx.translateBy(x: 0, y: CGFloat(side))
        ctx.scaleBy(x: 1, y: -1)
        ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: side, height: side / 2))
        return try XCTUnwrap(ctx.makeImage())
    }

    /// Reads a pixel's alpha straight from the CGImage's backing bytes.
    /// CGImage data is always stored top-left (row 0 == visual top), so this
    /// is an unambiguous orientation oracle — unlike redrawing through
    /// another CGContext, whose CTM flip varies by platform.
    private func alpha(of image: CGImage, x: Int, y: Int) throws -> CGFloat {
        let data = try XCTUnwrap(image.dataProvider?.data)
        let ptr = try XCTUnwrap(CFDataGetBytePtr(data))
        let bpr = image.bytesPerRow
        let bpp = image.bitsPerPixel / 8
        let alphaOffset: Int
        switch image.alphaInfo {
        case .premultipliedLast, .last:   alphaOffset = bpp - 1   // RGBA → 3
        case .premultipliedFirst, .first: alphaOffset = 0         // ARGB → 0
        case .noneSkipLast, .noneSkipFirst, .none:
            return 1                                              // opaque
        @unknown default:                 alphaOffset = bpp - 1
        }
        return CGFloat(ptr[y * bpr + x * bpp + alphaOffset]) / 255.0
    }
}
