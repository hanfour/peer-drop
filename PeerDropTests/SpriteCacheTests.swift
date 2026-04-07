import XCTest
@testable import PeerDrop

final class SpriteCacheTests: XCTestCase {

    func testCacheStoreAndRetrieve() {
        let cache = SpriteCache(maxEntries: 10)
        let img = TestSpriteHelper.make(width: 16, height: 16, fillIndex: 1)
        let key = SpriteCache.Key(body: .cat, stage: .baby, action: .idle, frame: 0, paletteIndex: 0)
        cache.set(img, for: key)
        XCTAssertNotNil(cache.get(key))
    }

    func testCacheMissReturnsNil() {
        let cache = SpriteCache(maxEntries: 10)
        let key = SpriteCache.Key(body: .cat, stage: .baby, action: .idle, frame: 0, paletteIndex: 0)
        XCTAssertNil(cache.get(key))
    }

    func testCacheEvictsOldEntries() {
        let cache = SpriteCache(maxEntries: 2)
        let img = TestSpriteHelper.make(width: 16, height: 16, fillIndex: 1)
        let k1 = SpriteCache.Key(body: .cat, stage: .baby, action: .idle, frame: 0, paletteIndex: 0)
        let k2 = SpriteCache.Key(body: .cat, stage: .baby, action: .idle, frame: 1, paletteIndex: 0)
        let k3 = SpriteCache.Key(body: .cat, stage: .baby, action: .walking, frame: 0, paletteIndex: 0)
        cache.set(img, for: k1)
        cache.set(img, for: k2)
        cache.set(img, for: k3) // should evict k1
        XCTAssertNil(cache.get(k1))
        XCTAssertNotNil(cache.get(k2))
        XCTAssertNotNil(cache.get(k3))
    }

    func testClearRemovesAll() {
        let cache = SpriteCache(maxEntries: 10)
        let img = TestSpriteHelper.make(width: 16, height: 16, fillIndex: 1)
        let key = SpriteCache.Key(body: .cat, stage: .baby, action: .idle, frame: 0, paletteIndex: 0)
        cache.set(img, for: key)
        cache.clear()
        XCTAssertNil(cache.get(key))
    }
}
