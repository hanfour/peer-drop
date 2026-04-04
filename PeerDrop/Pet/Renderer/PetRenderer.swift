import Foundation

class PetRenderer {

    func render(genome: PetGenome, level: PetLevel, mood: PetMood, animationFrame: Int) -> PixelGrid {
        switch level {
        case .egg:
            return renderEgg(genome: genome, frame: animationFrame)
        case .baby:
            return renderBaby(genome: genome, mood: mood, frame: animationFrame)
        }
    }

    // MARK: - Egg

    private func renderEgg(genome: PetGenome, frame: Int) -> PixelGrid {
        var grid = PixelGrid.empty()
        let breathOffset = frame % 2
        let rx = 12
        let ry = 16 + breathOffset
        grid.drawEllipse(center: (32, 32), rx: rx, ry: ry)

        // Crack lines based on personality gene — drawn outside the egg shell
        let pg = genome.personalityGene
        if pg > 0.3 {
            // First crack: extends beyond the egg on the left
            grid.drawLine(from: (18, 30), to: (22, 34))
        }
        if pg > 0.6 {
            // Second crack: extends beyond the egg on the right
            grid.drawLine(from: (46, 28), to: (43, 32))
        }

        return grid
    }

    // MARK: - Baby

    private func renderBaby(genome: PetGenome, mood: PetMood, frame: Int) -> PixelGrid {
        var grid = PixelGrid.empty()
        let bounce = frame % 2

        // Body
        drawBody(genome: genome, into: &grid, bounce: bounce)

        // Eyes
        drawEyes(genome: genome, mood: mood, into: &grid, bounce: bounce)

        // Limbs
        drawLimbs(genome: genome, into: &grid, frame: frame, bounce: bounce)

        // Pattern
        drawPattern(genome: genome, into: &grid, bounce: bounce)

        return grid
    }

    private func drawBody(genome: PetGenome, into grid: inout PixelGrid, bounce: Int) {
        let cy = 32 + bounce
        switch genome.body {
        case .round:
            grid.drawCircle(center: (32, cy), radius: 14)
        case .square:
            grid.drawRect(origin: (20, cy - 12), size: (24, 24))
        case .oval:
            grid.drawEllipse(center: (32, cy), rx: 10, ry: 14)
        }
    }

    private func drawEyes(genome: PetGenome, mood: PetMood, into grid: inout PixelGrid, bounce: Int) {
        let leftEye = (26, 28 + bounce)
        let rightEye = (38, 28 + bounce)

        // Mood overrides
        switch mood {
        case .happy:
            // Happy eyes: horizontal line (squinting)
            grid.drawLine(from: (leftEye.0 - 1, leftEye.1), to: (leftEye.0 + 1, leftEye.1))
            grid.drawLine(from: (rightEye.0 - 1, rightEye.1), to: (rightEye.0 + 1, rightEye.1))
            return
        case .sleepy:
            // Sleepy eyes: horizontal line + ZZZ above
            grid.drawLine(from: (leftEye.0 - 1, leftEye.1), to: (leftEye.0 + 1, leftEye.1))
            grid.drawLine(from: (rightEye.0 - 1, rightEye.1), to: (rightEye.0 + 1, rightEye.1))
            // ZZZ: small pixels above right eye
            grid.setPixel(x: 42, y: 22 + bounce)
            grid.setPixel(x: 44, y: 20 + bounce)
            grid.setPixel(x: 46, y: 18 + bounce)
            return
        case .startled:
            // Big circle eyes
            grid.drawCircle(center: leftEye, radius: 3)
            grid.drawCircle(center: rightEye, radius: 3)
            return
        default:
            break
        }

        // Gene-based eyes
        switch genome.eyes {
        case .dot:
            grid.setPixel(x: leftEye.0, y: leftEye.1)
            grid.setPixel(x: rightEye.0, y: rightEye.1)
        case .round:
            grid.drawCircle(center: leftEye, radius: 2)
            grid.drawCircle(center: rightEye, radius: 2)
        case .line:
            grid.drawLine(from: (leftEye.0 - 1, leftEye.1), to: (leftEye.0 + 1, leftEye.1))
            grid.drawLine(from: (rightEye.0 - 1, rightEye.1), to: (rightEye.0 + 1, rightEye.1))
        case .dizzy:
            // X shape for each eye
            grid.drawLine(from: (leftEye.0 - 1, leftEye.1 - 1), to: (leftEye.0 + 1, leftEye.1 + 1))
            grid.drawLine(from: (leftEye.0 - 1, leftEye.1 + 1), to: (leftEye.0 + 1, leftEye.1 - 1))
            grid.drawLine(from: (rightEye.0 - 1, rightEye.1 - 1), to: (rightEye.0 + 1, rightEye.1 + 1))
            grid.drawLine(from: (rightEye.0 - 1, rightEye.1 + 1), to: (rightEye.0 + 1, rightEye.1 - 1))
        }
    }

    private func drawLimbs(genome: PetGenome, into grid: inout PixelGrid, frame: Int, bounce: Int) {
        let alternation = frame % 2
        let cy = 32 + bounce

        switch genome.limbs {
        case .short:
            // Short: 3x4 rects on left and right sides
            let leftX = 16
            let rightX = 45
            let leftY = cy - 2 + (alternation == 0 ? 0 : 2)
            let rightY = cy - 2 + (alternation == 0 ? 2 : 0)
            grid.drawRect(origin: (leftX, leftY), size: (3, 4))
            grid.drawRect(origin: (rightX, rightY), size: (3, 4))
        case .long:
            // Long: diagonal lines from body
            let offset = alternation == 0 ? 0 : 2
            grid.drawLine(from: (18, cy - 4 + offset), to: (12, cy + 6 + offset))
            grid.drawLine(from: (46, cy - 4 + (2 - offset)), to: (52, cy + 6 + (2 - offset)))
        case .none:
            break
        }
    }

    private func drawPattern(genome: PetGenome, into grid: inout PixelGrid, bounce: Int) {
        let cy = 32 + bounce

        switch genome.pattern {
        case .none:
            break
        case .stripe:
            // Horizontal lines every 4 pixels across body area
            for y in stride(from: cy - 10, through: cy + 10, by: 4) {
                for x in 24...40 {
                    if y >= 0, y < 64, grid.pixels[y][x] {
                        // Only draw stripe on existing body pixels — toggle off for stripe effect
                        grid.setPixel(x: x, y: y, value: false)
                    }
                }
            }
        case .spot:
            // 3 single pixels as spots on the body
            grid.setPixel(x: 30, y: cy - 4)
            grid.setPixel(x: 35, y: cy - 2)
            grid.setPixel(x: 28, y: cy + 3)
        }
    }
}
