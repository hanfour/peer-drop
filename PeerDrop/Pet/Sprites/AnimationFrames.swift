import CoreGraphics
import Foundation

struct AnimationFrames {
    let images: [CGImage]
    let fps: Int
    let loops: Bool
}

struct AnimationRequest: Hashable {
    let species: SpeciesID
    let stage: PetLevel
    let direction: SpriteDirection
    let action: PetAction

    var spriteRequest: SpriteRequest {
        SpriteRequest(species: species, stage: stage, direction: direction)
    }
}
