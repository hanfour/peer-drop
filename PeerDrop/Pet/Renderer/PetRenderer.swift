import Foundation

class PetRenderer {

    func render(genome: PetGenome, level: PetLevel, mood: PetMood, animationFrame: Int) -> PixelGrid {
        switch level {
        case .egg:
            return renderEgg(genome: genome, frame: animationFrame)
        case .baby, .child:
            return renderBaby(genome: genome, mood: mood, frame: animationFrame)
        }
    }

    // MARK: - Egg

    private func renderEgg(genome: PetGenome, frame: Int) -> PixelGrid {
        var grid = PixelGrid.empty()
        let eggTemplate = PetSpriteTemplates.egg[frame % PetSpriteTemplates.egg.count]

        // Center the egg template on the 32×32 grid
        let templateWidth = eggTemplate.pixels[0].count
        let templateHeight = eggTemplate.pixels.count
        let ox = (32 - templateWidth) / 2
        let oy = (32 - templateHeight) / 2

        grid.stamp(template: eggTemplate.pixels, at: (ox, oy))

        // Crack lines based on personality gene
        let pg = genome.personalityGene
        if pg > 0.3 {
            for p in eggTemplate.crackLeftPixels {
                grid.setPixel(x: ox + p.x, y: oy + p.y, value: 5)
            }
        }
        if pg > 0.6 {
            for p in eggTemplate.crackRightPixels {
                grid.setPixel(x: ox + p.x, y: oy + p.y, value: 5)
            }
        }

        return grid
    }

    // MARK: - Baby

    private func renderBaby(genome: PetGenome, mood: PetMood, frame: Int) -> PixelGrid {
        var grid = PixelGrid.empty()
        let bounce = frame % 2

        // 1. Body
        let bodyTemplates = PetSpriteTemplates.body(for: genome.body)
        let bodyTemplate = bodyTemplates[frame % bodyTemplates.count]
        let bodyWidth = bodyTemplate.pixels[0].count
        let bodyHeight = bodyTemplate.pixels.count
        let bodyX = (32 - bodyWidth) / 2
        let bodyY = (32 - bodyHeight) / 2 + bounce

        grid.stamp(template: bodyTemplate.pixels, at: (bodyX, bodyY))

        // 2. Eyes
        let eyeTemplate: [[Int]]
        if let moodOverride = PetSpriteTemplates.eyesMood(mood) {
            eyeTemplate = moodOverride
        } else {
            eyeTemplate = PetSpriteTemplates.eyes(for: genome.eyes)
        }
        let eyeX = bodyX + bodyTemplate.eyeAnchor.x
        let eyeY = bodyY + bodyTemplate.eyeAnchor.y
        grid.stamp(template: eyeTemplate, at: (eyeX, eyeY))

        // 3. Limbs
        if let limbs = genome.limbs, let limbTemplate = PetSpriteTemplates.limbs(for: limbs, frame: frame) {
            let leftX = bodyX + bodyTemplate.limbLeftAnchor.x + limbTemplate.leftOffset.x
            let leftY = bodyY + bodyTemplate.limbLeftAnchor.y + limbTemplate.leftOffset.y
            grid.stamp(template: limbTemplate.left, at: (leftX, leftY))

            let rightX = bodyX + bodyTemplate.limbRightAnchor.x + limbTemplate.rightOffset.x
            let rightY = bodyY + bodyTemplate.limbRightAnchor.y + limbTemplate.rightOffset.y
            grid.stamp(template: limbTemplate.right, at: (rightX, rightY))
        }

        // 4. Pattern (only overwrite existing non-zero pixels within pattern region)
        if let patternTemplate = PetSpriteTemplates.pattern(for: genome.pattern) {
            let px = bodyX + bodyTemplate.patternOrigin.x
            let py = bodyY + bodyTemplate.patternOrigin.y
            for (row, line) in patternTemplate.enumerated() {
                for (col, val) in line.enumerated() {
                    guard val != 0 else { continue }
                    let gx = px + col
                    let gy = py + row
                    guard gx >= 0, gx < 32, gy >= 0, gy < 32 else { continue }
                    // Only apply pattern on existing body pixels (not outline)
                    if grid.pixels[gy][gx] == 2 || grid.pixels[gy][gx] == 3 {
                        grid.setPixel(x: gx, y: gy, value: val)
                    }
                }
            }
        }

        return grid
    }
}
