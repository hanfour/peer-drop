import XCTest
import CoreGraphics
@testable import PeerDrop

final class SpriteCacheTests: XCTestCase {

    // MARK: - basic set/get

    func test_setThenGet_returnsImage() {
        let cache = SpriteCache(countLimit: 10)
        let key = catTabbyAdultEast
        cache.setImage(makeStubImage(), for: key)
        XCTAssertNotNil(cache.image(for: key))
    }

    func test_get_missingKey_returnsNil() {
        let cache = SpriteCache(countLimit: 10)
        XCTAssertNil(cache.image(for: catTabbyAdultEast))
    }

    func test_clear_evictsAllEntries() {
        let cache = SpriteCache(countLimit: 10)
        cache.setImage(makeStubImage(), for: catTabbyAdultEast)
        cache.clear()
        XCTAssertNil(cache.image(for: catTabbyAdultEast))
    }

    // MARK: - keys

    func test_distinctRequests_haveDistinctSlots() {
        let cache = SpriteCache(countLimit: 10)
        let east = catTabbyAdultEast
        let west = SpriteRequest(species: SpeciesID("cat-tabby"), stage: .adult, direction: .west)
        cache.setImage(makeStubImage(red: true), for: east)
        cache.setImage(makeStubImage(red: false), for: west)
        XCTAssertNotNil(cache.image(for: east))
        XCTAssertNotNil(cache.image(for: west))
    }

    // MARK: - hit rate metric

    func test_hitRate_zeroForFreshCache() {
        let cache = SpriteCache(countLimit: 10)
        XCTAssertEqual(cache.hitRate, 0.0)
    }

    func test_hitRate_reflectsHitsOverTotal() {
        let cache = SpriteCache(countLimit: 10)
        cache.setImage(makeStubImage(), for: catTabbyAdultEast)
        _ = cache.image(for: catTabbyAdultEast)              // hit
        _ = cache.image(for: catTabbyAdultEast)              // hit
        let dogKey = SpriteRequest(species: SpeciesID("dog-shiba"), stage: .adult, direction: .east)
        _ = cache.image(for: dogKey)                          // miss
        XCTAssertEqual(cache.hitRate, 2.0 / 3.0, accuracy: 0.001)
        let stats = cache.statistics
        XCTAssertEqual(stats.hits, 2)
        XCTAssertEqual(stats.misses, 1)
    }

    func test_clear_resetsHitRateMetric() {
        let cache = SpriteCache(countLimit: 10)
        cache.setImage(makeStubImage(), for: catTabbyAdultEast)
        _ = cache.image(for: catTabbyAdultEast)
        cache.clear()
        XCTAssertEqual(cache.hitRate, 0.0)
        XCTAssertEqual(cache.statistics.hits, 0)
        XCTAssertEqual(cache.statistics.misses, 0)
    }

    // MARK: - shared singleton

    func test_shared_returnsSameInstance() {
        XCTAssertTrue(SpriteCache.shared === SpriteCache.shared)
    }

    // NOTE on eviction: NSCache may discard objects on memory pressure or when
    // the count limit is exceeded — but the timing is non-deterministic per
    // Apple's docs ("may discard"). We trust NSCache's contract rather than
    // testing strict LRU eviction here. SpriteService integration tests in
    // M3.5 cover end-to-end cache behavior under load.

    // MARK: - helpers

    private var catTabbyAdultEast: SpriteRequest {
        SpriteRequest(species: SpeciesID("cat-tabby"), stage: .adult, direction: .east)
    }

    /// 1×1 RGBA solid color image.
    private func makeStubImage(red: Bool = true) -> CGImage {
        let context = CGContext(
            data: nil,
            width: 1,
            height: 1,
            bitsPerComponent: 8,
            bytesPerRow: 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        context.setFillColor(red: red ? 1 : 0, green: 0, blue: red ? 0 : 1, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: 1, height: 1))
        return context.makeImage()!
    }
}
