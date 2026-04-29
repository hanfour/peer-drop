import CoreGraphics

enum PetSnapshotRenderer {
    static func render(body: BodyGene, level: PetLevel, mood: PetMood,
                       eyes: EyeGene, pattern: PatternGene,
                       paletteIndex: Int, scale: Int = 8) -> CGImage? {
        let palette: ColorPalette = level == .egg ? PetPalettes.egg : PetPalettes.all[paletteIndex]
        let indices: [[UInt8]]

        switch level {
        case .egg:
            indices = EggSpriteData.idle[0]
        case .baby, .adult, .elder:
            guard let bodyFrames = SpriteDataRegistry.sprites(for: body, stage: level)?[.idle],
                  !bodyFrames.isEmpty else { return nil }
            let meta = SpriteDataRegistry.meta(for: body)
            let eyeData: [[UInt8]]? = EyeSpriteData.moods[mood] ?? EyeSpriteData.sprites[eyes]
            let patternData = pattern != .none ? PatternSpriteData.sprites[pattern] : nil
            indices = SpriteCompositor.composite(
                body: bodyFrames[0], eyes: eyeData, eyeAnchor: meta.eyeAnchor,
                pattern: patternData, patternMask: meta.patternMask)
        }

        return PaletteSwapRenderer.render(indices: indices, palette: palette, scale: scale)
    }
}
