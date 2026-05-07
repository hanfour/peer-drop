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
    var foodInventory: FoodInventory = FoodInventory()
    var lifeState: PetLifeState = .idle
    var lastFedAt: Date?
    var digestEndTime: Date?
    var stats: PetStats = PetStats()
    var lastLoginDate: Date?
    /// Set once the v4.0 first-launch promotion sweep has run for this pet (M7.2 wires
    /// the actual sweep). Optional + new in v4.0 → legacy v3.x JSON decodes as nil.
    var migrationDoneAt: Date?

    var ageInDays: Int {
        Int(Date().timeIntervalSince(birthDate) / 86400)
    }

    /// Creates a new pet at the baby stage with a random genome and zero experience.
    /// (v4.0.1 dropped the egg stage; pets start as baby.)
    static func newEgg() -> PetState {
        PetState(
            id: UUID(),
            name: nil,
            birthDate: Date(),
            level: .baby,
            experience: 0,
            genome: .random(),
            mood: .curious,
            socialLog: [],
            lastInteraction: Date()
        )
    }
}
