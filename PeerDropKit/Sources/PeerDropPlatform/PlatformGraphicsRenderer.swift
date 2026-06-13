import Foundation
import CoreGraphics

/// Cross-platform image-context renderer. iOS wraps
/// `UIGraphicsImageRenderer` (scale = 1, opaque = false, deterministic
/// per Apple's docs); macOS uses an `NSGraphicsContext`-backed
/// `NSBitmapImageRep` with matching settings.
///
/// The output must be deterministic — the M4.3 caching contract in
/// PetRendererV3 (`docs/plans/2026-04-XX-pet-v4-impl.md`) depends on
/// byte-identical PNG bytes for identical drawing input.
public struct PlatformGraphicsRenderer {
    public let size: CGSize

    public init(size: CGSize) {
        self.size = size
    }

    public func image(drawing: (CGContext) -> Void) -> PlatformImage {
        #if canImport(UIKit)
        return UIKitGraphicsRenderer.render(size: size, drawing: drawing)
        #elseif canImport(AppKit)
        return AppKitGraphicsRenderer.render(size: size, drawing: drawing)
        #else
        // Compile-only branch
        return PlatformImage()
        #endif
    }
}

#if canImport(AppKit)
import AppKit

/// macOS implementation using NSBitmapImageRep. Matches UIGraphicsImageRenderer's
/// scale=1, opaque=false defaults.
enum AppKitGraphicsRenderer {
    static func render(size: CGSize, drawing: (CGContext) -> Void) -> PlatformImage {
        let width = Int(size.width)
        let height = Int(size.height)
        let bitmap = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: width,
            pixelsHigh: height,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: width * 4,
            bitsPerPixel: 32
        )!
        // Match UIGraphicsImageRenderer's coordinate system: top-left origin,
        // y increasing downward. `NSGraphicsContext(bitmapImageRep:)` is
        // bottom-left / y-up, the OPPOSITE of UIKit, so the shared drawing
        // code in PetRendererV3.composite (which manually y-flips for a
        // UIKit-style top-left context) ended up double-flipped on macOS.
        //
        // Two consumers read orientation DIFFERENTLY, so both must be made
        // top-left (audit rounds 22 + 23):
        //   • `CGContext.draw` (the base sprite) honours the CTM → flip the
        //     CTM.
        //   • `NSImage.draw` (the mood SF Symbol overlay) honours
        //     `NSGraphicsContext.isFlipped`, NOT the CTM → so flipping only
        //     the CTM fixed the sprite but left the mood icon upside-down
        //     (round-23 user report 「心情符號也是顛倒的」). Wrap the same
        //     CGContext in a `flipped: true` NSGraphicsContext so NSImage.draw
        //     agrees with the CTM.
        let cg = NSGraphicsContext(bitmapImageRep: bitmap)!.cgContext
        cg.translateBy(x: 0, y: CGFloat(height))
        cg.scaleBy(x: 1, y: -1)
        let context = NSGraphicsContext(cgContext: cg, flipped: true)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        drawing(cg)
        NSGraphicsContext.restoreGraphicsState()

        let image = NSImage(size: size)
        image.addRepresentation(bitmap)
        return image
    }
}
#endif
