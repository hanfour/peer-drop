import CoreGraphics

@MainActor
class PetRendererV2 {

    static let shared = PetRendererV2()
    private let cache = SpriteCache(maxEntries: 200)

    func render(genome: PetGenome, level: PetLevel, action: PetAction = .idle, mood: PetMood,
                frame: Int, palette: ColorPalette, scale: Int = 8,
                facingRight: Bool = true) -> CGImage? {

        let cacheKey = SpriteCache.Key(body: genome.body, stage: level,
                                        action: action, frame: frame,
                                        paletteIndex: genome.paletteIndex,
                                        facingRight: facingRight, mood: mood)

        if let cached = cache.get(cacheKey) { return cached }

        let indices: [[UInt8]]

        switch level {
        case .egg:
            let eggFrames = EggSpriteData.idle
            let f = frame % max(eggFrames.count, 1)
            indices = eggFrames[f]

        case .baby, .child:
            guard let bodyFrames = spriteData(for: genome.body, stage: level, action: action) else {
                return nil
            }
            let f = frame % max(bodyFrames.count, 1)
            let body = bodyFrames[f]
            let meta = bodyMeta(for: genome.body)

            // Eyes
            let eyes: [[UInt8]]?
            if let moodEyes = EyeSpriteData.moods[mood] {
                eyes = moodEyes
            } else {
                eyes = EyeSpriteData.sprites[genome.eyes]
            }

            // Pattern
            let pattern = genome.pattern != .none ? PatternSpriteData.sprites[genome.pattern] : nil

            var composite = SpriteCompositor.composite(
                body: body, eyes: eyes, eyeAnchor: meta.eyeAnchor,
                pattern: pattern, patternMask: meta.patternMask
            )

            if !facingRight {
                composite = SpriteCompositor.flipHorizontal(composite)
            }

            indices = composite
        }

        guard let image = PaletteSwapRenderer.render(indices: indices, palette: palette, scale: scale) else {
            return nil
        }

        cache.set(image, for: cacheKey)
        return image
    }

    func clearCache() {
        cache.clear()
    }

    private func spriteData(for body: BodyGene, stage: PetLevel, action: PetAction) -> [[[UInt8]]]? {
        SpriteDataRegistry.sprites(for: body, stage: stage)?[action]
    }

    private func bodyMeta(for body: BodyGene) -> BodyMeta {
        SpriteDataRegistry.meta(for: body)
    }
}
