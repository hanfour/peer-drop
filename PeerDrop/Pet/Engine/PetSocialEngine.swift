import Foundation

// MARK: - PetGreeting

/// Data exchanged between two devices when their pets meet.
struct PetGreeting: Codable {
    let petID: UUID
    let name: String?
    let level: PetLevel
    let mood: PetMood
    let genome: PetGenome
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
