import Foundation
import CoreGraphics
import OSLog

private let cacheLogger = Logger(subsystem: "com.hanfour.peerdrop", category: "PNGSpriteCache")

/// LRU cache for the v4.0 PNG sprite pipeline. Backed by NSCache, keyed by
/// SpriteRequest, holds decoded CGImages.
///
/// Class name disambiguates from the legacy `SpriteCache` in `Pet/Renderer/`,
/// which feeds PetRendererV2 with palette-swapped UInt8 sprites. The legacy
/// class dies in M8; we'll rename PNGSpriteCache → SpriteCache then.
///
/// Default count limit is 30 (per plan §M3.4). NSCache also evicts under memory
/// pressure, which is desirable on the iPhone-8 deploy floor.
///
/// Thread-safety: NSCache itself is thread-safe. The hit/miss counters use an
/// NSLock so the metric is consistent when accessed from the M3.5 SpriteService
/// actor and from prod telemetry readers.
final class PNGSpriteCache {

    static let shared = PNGSpriteCache()

    private let cache = NSCache<NSString, CGImageBox>()
    private let lock = NSLock()
    private var _hits = 0
    private var _misses = 0

    init(countLimit: Int = 30) {
        cache.countLimit = countLimit
    }

    func image(for key: SpriteRequest) -> CGImage? {
        let nsKey = key.cacheKey
        if let box = cache.object(forKey: nsKey) {
            recordHit()
            return box.image
        }
        recordMiss()
        return nil
    }

    func setImage(_ image: CGImage, for key: SpriteRequest) {
        // Cost = decoded image footprint in bytes. NSCache uses cost as a
        // tiebreaker for eviction priority and respects totalCostLimit. Even
        // without a cost limit set, costs let memory-pressure-driven eviction
        // make better choices than count-only.
        let cost = image.bytesPerRow * image.height
        cache.setObject(CGImageBox(image), forKey: key.cacheKey, cost: cost)
    }

    func clear() {
        cache.removeAllObjects()
        lock.lock()
        _hits = 0
        _misses = 0
        lock.unlock()
    }

    var hitRate: Double {
        lock.lock()
        defer { lock.unlock() }
        let total = _hits + _misses
        return total == 0 ? 0.0 : Double(_hits) / Double(total)
    }

    var statistics: (hits: Int, misses: Int) {
        lock.lock()
        defer { lock.unlock() }
        return (_hits, _misses)
    }

    private func recordHit() {
        lock.lock()
        _hits += 1
        let totalNow = _hits + _misses
        // Snapshot the rate inside the lock so the logged figure is internally
        // consistent — re-reading hitRate would re-acquire the lock and might
        // see a newer state than `totalNow`.
        let snapshotRate = totalNow == 0 ? 0.0 : Double(_hits) / Double(totalNow)
        lock.unlock()
        if totalNow.isMultiple(of: 100) {
            cacheLogger.debug("PNGSpriteCache: hitRate=\(snapshotRate, privacy: .public) after \(totalNow) requests")
        }
    }

    private func recordMiss() {
        lock.lock()
        _misses += 1
        lock.unlock()
    }
}

// NSCache requires reference-typed values. CGImage is a CF type that bridges
// to AnyObject, but using it as the generic ObjectType of NSCache is awkward
// in Swift — wrap it in a small box for clarity.
private final class CGImageBox {
    let image: CGImage
    init(_ image: CGImage) { self.image = image }
}

private extension SpriteRequest {
    var cacheKey: NSString {
        // species-stage-direction collapses to a single string for NSCache's
        // NSString-keyed lookup. SpriteDirection rawValue is already kebab-case
        // safe; SpeciesID.rawValue and PetLevel.rawValue have no slashes.
        NSString(string: "\(species.rawValue)/\(stage.rawValue)/\(direction.rawValue)")
    }
}
