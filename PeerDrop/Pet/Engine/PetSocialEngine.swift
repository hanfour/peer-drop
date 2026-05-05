import Foundation

// MARK: - PetGreeting

/// Data exchanged between two devices when their pets meet.
struct PetGreeting: Codable {
    /// Bumped when the wire format gains a forward-incompatible field. v4.0
    /// is at 2 (PetLevel.elder is the v4.0-only addition). Single source of
    /// truth — production senders, tests, and `downgraded(toProtocolVersion:)`
    /// all read this constant.
    static let currentProtocolVersion = 2

    let petID: UUID
    let name: String?
    let level: PetLevel
    let mood: PetMood
    let genome: PetGenome
    /// Sender's pet-protocol version. v3.x peers don't include this field, so
    /// it decodes as nil — receivers should treat nil as v1. v4.0 senders set
    /// it to `currentProtocolVersion`.
    let protocolVersion: Int?

    /// Explicit init so all stored properties stay `let` (preserves PetGreeting's
    /// immutability across the wire) while still letting callers omit
    /// `protocolVersion` (defaults to currentProtocolVersion).
    init(
        petID: UUID,
        name: String?,
        level: PetLevel,
        mood: PetMood,
        genome: PetGenome,
        protocolVersion: Int? = PetGreeting.currentProtocolVersion
    ) {
        self.petID = petID
        self.name = name
        self.level = level
        self.mood = mood
        self.genome = genome
        self.protocolVersion = protocolVersion
    }

    /// Custom encode that omits a nil `protocolVersion` instead of emitting
    /// `"protocolVersion": null`. Keeps a re-encoded v3.x-decoded greeting
    /// byte-identical (modulo key ordering) to the original — useful for any
    /// downstream tooling that does decode-then-re-encode roundtrips.
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(petID, forKey: .petID)
        try c.encode(name, forKey: .name)
        try c.encode(level, forKey: .level)
        try c.encode(mood, forKey: .mood)
        try c.encode(genome, forKey: .genome)
        if let protocolVersion {
            try c.encode(protocolVersion, forKey: .protocolVersion)
        }
    }
}

extension PetGreeting {
    /// Effective protocol version of the sender. Defaults to 1 for v3.x peers
    /// whose JSON lacks the field.
    var effectiveProtocolVersion: Int { protocolVersion ?? 1 }

    /// Returns a copy of this greeting safe to wire-encode for a peer running
    /// `targetVersion`. Forward-incompatible v4.0 fields are downgraded:
    ///   • PetLevel.elder (rawValue 4) → .adult (rawValue 3); v3.x reads
    ///     rawValue 3 as its `.child` case — same visual stage in both worlds.
    ///
    /// PetGenome's optional subVariety/seed fields don't need downgrading;
    /// v3.x's permissive Codable ignores unknown nested keys.
    ///
    /// Future v4.x cases that add forward-incompat fields (new PetMood case,
    /// new BodyGene case) extend this method with their own downgrade clauses.
    func downgraded(toProtocolVersion targetVersion: Int) -> PetGreeting {
        guard targetVersion < Self.currentProtocolVersion else { return self }
        var newLevel = level
        if targetVersion < 2 && level == .elder {
            newLevel = .adult
        }
        return PetGreeting(
            petID: petID,
            name: name,
            level: newLevel,
            mood: mood,
            genome: genome,
            protocolVersion: protocolVersion
        )
    }
}

// MARK: - PetSocialEngine

final class PetSocialEngine {

    private let dialogEngine = PetDialogEngine()

    /// Generate a social entry when two pets meet.
    /// The dialogue is produced by `PetDialogEngine` and the entry starts unrevealed.
    func onPetMeeting(myPet: PetState, partnerGreeting: PetGreeting) -> SocialEntry {
        let dialogue = dialogEngine.generatePrivateChat(
            myLevel: myPet.level,
            partnerLevel: partnerGreeting.level,
            myMood: myPet.mood,
            partnerMood: partnerGreeting.mood
        )

        return SocialEntry(
            partnerPetID: partnerGreeting.petID,
            partnerName: partnerGreeting.name,
            partnerGenome: partnerGreeting.genome,
            interaction: .chat,
            dialogue: dialogue,
            isRevealed: false
        )
    }

    /// Attempt to reveal the first unrevealed social entry.
    ///
    /// Returns `nil` unless:
    /// 1. The pet's mood is `.happy`
    /// 2. There is at least one unrevealed entry in the social log
    ///
    /// When both conditions are met, there is a **30 %** chance of returning the
    /// first unrevealed entry (with `isRevealed` set to `true`).
    func tryReveal(pet: PetState) -> SocialEntry? {
        guard pet.mood == .happy else { return nil }

        guard var entry = pet.socialLog.first(where: { !$0.isRevealed }) else {
            return nil
        }

        // 30 % chance
        guard Double.random(in: 0..<1) < 0.3 else { return nil }

        entry.isRevealed = true
        return entry
    }
}
