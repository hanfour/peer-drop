import Foundation

// MARK: - PetGreeting

/// Data exchanged between two devices when their pets meet.
struct PetGreeting: Codable {
    let petID: UUID
    let name: String?
    let level: PetLevel
    let mood: PetMood
    let genome: PetGenome
    /// Sender's pet-protocol version. v3.x peers don't include this field, so
    /// it decodes as nil — receivers should treat nil as v1. v4.0 senders set
    /// it to 2 (default). Receivers use this to clamp v4.0-only PetLevel
    /// values (.elder) before forwarding back to v1 peers.
    var protocolVersion: Int? = 2
}

extension PetGreeting {
    /// Effective protocol version of the sender. Defaults to 1 for v3.x peers
    /// whose JSON lacks the field.
    var effectiveProtocolVersion: Int { protocolVersion ?? 1 }

    /// Returns a copy of this greeting safe to wire-encode for a peer running
    /// the given protocol version. The only v4.0 → v1 incompatibility is
    /// PetLevel.elder (rawValue 4) — v3.x's enum has no case for it and would
    /// fail decoding. Clamp to .adult (rawValue 3) which v3.x reads as
    /// .child — same visual stage in both worlds.
    ///
    /// PetGenome's optional subVariety/seed fields don't need clamping;
    /// v3.x's permissive Codable ignores unknown nested keys.
    func clamped(forPeerProtocolVersion peerVersion: Int) -> PetGreeting {
        guard peerVersion < 2, level == .elder else { return self }
        return PetGreeting(
            petID: petID,
            name: name,
            level: .adult,
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
