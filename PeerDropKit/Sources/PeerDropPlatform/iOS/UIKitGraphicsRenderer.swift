#if canImport(UIKit)
import UIKit
import CoreGraphics

enum UIKitGraphicsRenderer {
    static func render(size: CGSize, drawing: (CGContext) -> Void) -> PlatformImage {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = false
        let renderer = UIGraphicsImageRenderer(size: size, format: format)
        return renderer.image { ctx in
            drawing(ctx.cgContext)
        }
    }
}
#endif
