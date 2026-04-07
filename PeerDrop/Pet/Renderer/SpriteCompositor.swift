import Foundation

enum SpriteCompositor {

    /// Composite layers into a single 2D index array.
    /// Layer order: body (base) → pattern (overwrites body where mask allows) → eyes (on top)
    static func composite(
        body: [[UInt8]],
        eyes: [[UInt8]]?,
        eyeAnchor: (x: Int, y: Int)?,
        pattern: [[UInt8]]?,
        patternMask: [[Bool]]?
    ) -> [[UInt8]] {
        var result = body
        let h = body.count
        guard h > 0 else { return result }
        let w = body[0].count

        // Apply pattern (only where mask is true and body pixel is primary/secondary)
        if let pattern, let mask = patternMask {
            for py in 0..<min(pattern.count, h) {
                for px in 0..<min(pattern[0].count, w) {
                    let idx = pattern[py][px]
                    guard idx != 0, py < mask.count, px < mask[0].count, mask[py][px] else { continue }
                    let bodyVal = result[py][px]
                    if bodyVal == 2 || bodyVal == 3 { // only overwrite primary/secondary body
                        result[py][px] = idx
                    }
                }
            }
        }

        // Overlay eyes at anchor
        if let eyes, let anchor = eyeAnchor {
            for ey in 0..<eyes.count {
                for ex in 0..<eyes[ey].count {
                    let idx = eyes[ey][ex]
                    guard idx != 0 else { continue } // 0 = transparent, skip
                    let gx = anchor.x + ex
                    let gy = anchor.y + ey
                    guard gx >= 0, gx < w, gy >= 0, gy < h else { continue }
                    result[gy][gx] = idx
                }
            }
        }

        return result
    }

    /// Flip a 2D index array horizontally (for left-facing direction).
    static func flipHorizontal(_ indices: [[UInt8]]) -> [[UInt8]] {
        indices.map { Array($0.reversed()) }
    }
}
