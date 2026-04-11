import CoreGraphics

final class SpriteCache {

    struct Key: Hashable {
        let body: BodyGene
        let stage: PetLevel
        let action: PetAction
        let frame: Int
        let paletteIndex: Int
    }

    private let maxEntries: Int
    private var cache = [Key: CGImage]()
    private var accessOrder = [Key]()

    init(maxEntries: Int = 200) {
        self.maxEntries = maxEntries
    }

    func get(_ key: Key) -> CGImage? {
        guard let image = cache[key] else { return nil }
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
