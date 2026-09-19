import SwiftUI
import PeerDropPlatform

/// SwiftUI bridge from the cross-platform `PlatformImage` typealias
/// (`UIImage` on iOS, `NSImage` on macOS) to a SwiftUI `Image`.
///
/// `PlatformImage` itself + JPEG / tint / CGImage adapters live in
/// `PeerDropPlatform.PlatformImage` (created in M0). This initializer
/// is the SwiftUI-side piece that was missing so M4 Task 1b can swap
/// the 8 iOS-only `Image(uiImage:)` call sites for a cross-platform
/// path without scattered `#if canImport(UIKit)` blocks.
///
/// Usage:
/// ```swift
/// let img: PlatformImage = ...
/// Image(platformImage: img)
/// ```
extension Image {
    init(platformImage: PlatformImage) {
        #if canImport(UIKit)
        self.init(uiImage: platformImage)
        #elseif canImport(AppKit)
        self.init(nsImage: platformImage)
        #endif
    }
}
