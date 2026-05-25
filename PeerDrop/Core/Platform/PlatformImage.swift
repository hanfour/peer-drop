import Foundation
#if canImport(UIKit)
import UIKit
public typealias PlatformImage = UIImage
public typealias PlatformColor = UIColor
#elseif canImport(AppKit)
import AppKit
public typealias PlatformImage = NSImage
public typealias PlatformColor = NSColor
#endif

extension PlatformImage {
    /// Cross-platform JPEG encoder. iOS forwards to `jpegData(compressionQuality:)`;
    /// macOS implementation lives in PeerDropApp-macOS (M2).
    func platformJPEGData(compressionQuality: CGFloat) -> Data? {
        #if canImport(UIKit)
        return self.jpegData(compressionQuality: compressionQuality)
        #elseif canImport(AppKit)
        guard let tiff = self.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff) else { return nil }
        return rep.representation(using: .jpeg, properties: [.compressionFactor: compressionQuality])
        #endif
    }
}

extension PlatformImage {
    /// Cross-platform CGImage adapter. iOS uses `UIImage(cgImage:)` (size derived
    /// from CGImage); macOS uses `NSImage(cgImage:size:)` (size must be supplied).
    convenience init?(platformCGImage cgImage: CGImage, size: CGSize) {
        #if canImport(UIKit)
        self.init(cgImage: cgImage)
        #elseif canImport(AppKit)
        self.init(cgImage: cgImage, size: size)
        #else
        return nil
        #endif
    }

    /// Cross-platform SF Symbol loader. iOS uses `UIImage(systemName:)`;
    /// macOS uses `NSImage(systemSymbolName:accessibilityDescription:)` (macOS 11+).
    convenience init?(platformSystemName name: String) {
        #if canImport(UIKit)
        self.init(systemName: name)
        #elseif canImport(AppKit)
        self.init(systemSymbolName: name, accessibilityDescription: nil)
        #else
        return nil
        #endif
    }
}
