import Foundation
import PeerDropPlatform
import os

private let logger = Logger(subsystem: "com.hanfour.peerdrop", category: "ImageCache")

public final class ImageCache {
    public static let shared = ImageCache()

    private let cache = NSCache<NSString, PlatformImage>()

    private init() {
        cache.countLimit = 50
        cache.totalCostLimit = 50 * 1024 * 1024 // 50 MB
    }

    public func image(forKey key: String) -> PlatformImage? {
        cache.object(forKey: key as NSString)
    }

    public func setImage(_ image: PlatformImage, forKey key: String) {
        let cost = image.platformJPEGData(compressionQuality: 1.0)?.count ?? 0
        cache.setObject(image, forKey: key as NSString, cost: cost)
    }

    public func removeImage(forKey key: String) {
        cache.removeObject(forKey: key as NSString)
    }

    public func removeAll() {
        cache.removeAllObjects()
        logger.debug("Image cache cleared")
    }
}
