import Foundation

struct PetState: Codable {
    let id: UUID
    var name: String?
    var birthDate: Date
    var level: PetLevel
    var experience: Int
    var genome: PetGenome
    var mood: PetMood
    var socialLog: [SocialEntry]
    var lastInteraction: Date

    /// Creates a new egg with random genome and zero experience.
    static func newEgg() -> PetState {
        PetState(
            id: UUID(),
            name: nil,
            birthDate: Date(),
            level: .egg,
            experience: 0,
            genome: .random(),
            mood: .curious,
            socialLog: [],
            lastInteraction: Date()
        )
    }
}
