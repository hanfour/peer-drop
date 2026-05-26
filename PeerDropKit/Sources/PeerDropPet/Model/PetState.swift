import Foundation

public struct PetState: Codable {

    // MARK: - Schema versioning

    /// Most recent schema version. Bump when a field's semantics change in
    /// a way that requires migration logic (not just additive fields, which
    /// Codable already handles via missing-key tolerance).
    ///
    /// History:
    ///   1 — implicit, pre-v5 (no schemaVersion field in JSON)
    ///   2 — v5 era (this file). No semantic field change yet, but we
    ///       persist the marker so future migrations have a known anchor.
    public static let currentSchemaVersion: Int = 2

    /// Schema version this PetState was written at. Decoded from JSON
    /// when present (v5+ pets); missing in legacy JSON (decodes to 1
    /// via the custom decoder below). Encoder always writes the
    /// current value.
    public var schemaVersion: Int = PetState.currentSchemaVersion

    // MARK: - Stored fields

    public let id: UUID
    public var name: String?
    public var birthDate: Date
    public var level: PetLevel
    public var experience: Int
    public var genome: PetGenome
    public var mood: PetMood
    public var socialLog: [SocialEntry]
    public var lastInteraction: Date
    public var foodInventory: FoodInventory = FoodInventory()
    public var lifeState: PetLifeState = .idle
    public var lastFedAt: Date?
    public var digestEndTime: Date?
    public var stats: PetStats = PetStats()
    public var lastLoginDate: Date?
    /// Set once the v4.0 first-launch promotion sweep has run for this pet (M7.2 wires
    /// the actual sweep). Optional + new in v4.0 → legacy v3.x JSON decodes as nil.
    public var migrationDoneAt: Date?

    // MARK: - Computed

    public var ageInDays: Int {
        Int(Date().timeIntervalSince(birthDate) / 86400)
    }

    // MARK: - Init

    public init(
        schemaVersion: Int = PetState.currentSchemaVersion,
        id: UUID,
        name: String? = nil,
        birthDate: Date,
        level: PetLevel,
        experience: Int,
        genome: PetGenome,
        mood: PetMood,
        socialLog: [SocialEntry],
        lastInteraction: Date,
        foodInventory: FoodInventory = FoodInventory(),
        lifeState: PetLifeState = .idle,
        lastFedAt: Date? = nil,
        digestEndTime: Date? = nil,
        stats: PetStats = PetStats(),
        lastLoginDate: Date? = nil,
        migrationDoneAt: Date? = nil
    ) {
        self.schemaVersion = schemaVersion
        self.id = id
        self.name = name
        self.birthDate = birthDate
        self.level = level
        self.experience = experience
        self.genome = genome
        self.mood = mood
        self.socialLog = socialLog
        self.lastInteraction = lastInteraction
        self.foodInventory = foodInventory
        self.lifeState = lifeState
        self.lastFedAt = lastFedAt
        self.digestEndTime = digestEndTime
        self.stats = stats
        self.lastLoginDate = lastLoginDate
        self.migrationDoneAt = migrationDoneAt
    }

    // MARK: - Codable (custom decoder for legacy JSON without schemaVersion)

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        // Missing schemaVersion = legacy (pre-v5) JSON → treat as v1
        self.schemaVersion = (try? c.decode(Int.self, forKey: .schemaVersion)) ?? 1
        self.id = try c.decode(UUID.self, forKey: .id)
        self.name = try c.decodeIfPresent(String.self, forKey: .name)
        self.birthDate = try c.decode(Date.self, forKey: .birthDate)
        self.level = try c.decode(PetLevel.self, forKey: .level)
        self.experience = try c.decode(Int.self, forKey: .experience)
        self.genome = try c.decode(PetGenome.self, forKey: .genome)
        self.mood = try c.decode(PetMood.self, forKey: .mood)
        self.socialLog = try c.decode([SocialEntry].self, forKey: .socialLog)
        self.lastInteraction = try c.decode(Date.self, forKey: .lastInteraction)
        self.foodInventory = (try? c.decode(FoodInventory.self, forKey: .foodInventory)) ?? FoodInventory()
        self.lifeState = (try? c.decode(PetLifeState.self, forKey: .lifeState)) ?? .idle
        self.lastFedAt = try c.decodeIfPresent(Date.self, forKey: .lastFedAt)
        self.digestEndTime = try c.decodeIfPresent(Date.self, forKey: .digestEndTime)
        self.stats = (try? c.decode(PetStats.self, forKey: .stats)) ?? PetStats()
        self.lastLoginDate = try c.decodeIfPresent(Date.self, forKey: .lastLoginDate)
        self.migrationDoneAt = try c.decodeIfPresent(Date.self, forKey: .migrationDoneAt)
    }

    // MARK: - Factories

    /// Creates a new pet at the baby stage with a random genome and zero experience.
    /// (v4.0.1 dropped the egg stage; pets start as baby.)
    public static func newEgg() -> PetState {
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
