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
