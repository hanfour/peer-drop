import Foundation
import CoreGraphics

/// v4.0 PNG-pipeline pet renderer. Replaces the legacy `PetRendererV2` (which
/// composites palette-swapped UInt8 sprites with eye/pattern overlays).
///
/// Renders flow: PetGenome → SpriteRequest → SpriteService.image → CGImage.
/// Mood is rendered as a runtime SF Symbol overlay by M4b.2 — composited on
/// top of the base PNG. M4.1 just plumbs the mood parameter through.
@MainActor
final class PetRendererV3 {

    private let service: SpriteService

    init(service: SpriteService = .shared) {
        self.service = service
    }

    func render(
        genome: PetGenome,
        level: PetLevel,
        mood: PetMood,
        direction: SpriteDirection
    ) async throws -> CGImage {
        let request = SpriteRequest(
            species: genome.resolvedSpeciesID,
            stage: level,
            direction: direction
        )
        return try await service.image(for: request)
    }
}
