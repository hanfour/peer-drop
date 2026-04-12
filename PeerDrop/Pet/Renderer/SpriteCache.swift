import CoreGraphics

@MainActor
final class SpriteCache {

    struct Key: Hashable {
        let body: BodyGene
        let stage: PetLevel
        let action: PetAction
        let frame: Int
        let paletteIndex: Int
        let facingRight: Bool
        let mood: PetMood
    }

    private let maxEntries: Int
    private var cache = [Key: CGImage]()
    // O(n) access order — acceptable at 200 entries
    private var accessOrder = [Key]()

    #if DEBUG
    private var hits = 0
    private var misses = 0
    #endif

    init(maxEntries: Int = 200) {
        self.maxEntries = maxEntries
    }

    func get(_ key: Key) -> CGImage? {
        guard let image = cache[key] else {
            #if DEBUG
            misses += 1
            if (hits + misses) % 100 == 0 {
                print("[SpriteCache] hits: \(hits), misses: \(misses), rate: \(hits * 100 / max(hits + misses, 1))%")
            }
            #endif
            return nil
        }
        #if DEBUG
        hits += 1
        if (hits + misses) % 100 == 0 {
            print("[SpriteCache] hits: \(hits), misses: \(misses), rate: \(hits * 100 / max(hits + misses, 1))%")
        }
        #endif
        if let idx = accessOrder.firstIndex(of: key) {
            accessOrder.remove(at: idx)
            accessOrder.append(key)
        }
        return image
    }

    func set(_ image: CGImage, for key: Key) {
        if cache[key] != nil {
            if let idx = accessOrder.firstIndex(of: key) {
                accessOrder.remove(at: idx)
            }
        } else if cache.count >= maxEntries {
            let evicted = accessOrder.removeFirst()
            cache.removeValue(forKey: evicted)
        }
        cache[key] = image
        accessOrder.append(key)
    }

    func clear() {
        cache.removeAll()
        accessOrder.removeAll()
    }
}
