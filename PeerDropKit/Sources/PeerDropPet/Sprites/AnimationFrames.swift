import CoreGraphics
import Foundation

public struct AnimationFrames {
    public let images: [CGImage]
    public let fps: Int
    public let loops: Bool
    public init(images: [CGImage], fps: Int, loops: Bool) {
        self.images = images; self.fps = fps; self.loops = loops
    }
}

public struct AnimationRequest: Hashable {
    public let species: SpeciesID
    public let stage: PetLevel
    public let direction: SpriteDirection
    public let action: PetAction
    public init(species: SpeciesID, stage: PetLevel, direction: SpriteDirection, action: PetAction) {
        self.species = species; self.stage = stage; self.direction = direction; self.action = action
    }

    public var spriteRequest: SpriteRequest {
        SpriteRequest(species: species, stage: stage, direction: direction)
    }
}
