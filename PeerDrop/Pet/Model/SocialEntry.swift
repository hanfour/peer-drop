import Foundation

enum SocialInteraction: String, Codable {
    case greet
    case chat
    case play
}

struct DialogueLine: Codable, Equatable {
    let speaker: String
    let text: String
}

struct SocialEntry: Codable, Identifiable {
    let id: UUID
    let partnerPetID: UUID
    let partnerName: String?
    let partnerGenome: PetGenome?
    let date: Date
    let interaction: SocialInteraction
    var dialogue: [DialogueLine]
    var isRevealed: Bool

    init(
        id: UUID = UUID(),
        partnerPetID: UUID,
        partnerName: String? = nil,
        partnerGenome: PetGenome? = nil,
        date: Date = Date(),
        interaction: SocialInteraction,
        dialogue: [DialogueLine] = [],
        isRevealed: Bool = false
    ) {
        self.id = id
        self.partnerPetID = partnerPetID
        self.partnerName = partnerName
        self.partnerGenome = partnerGenome
        self.date = date
        self.interaction = interaction
        self.dialogue = dialogue
        self.isRevealed = isRevealed
    }
}
