import Foundation

public enum SocialInteraction: String, Codable {
    case greet
    case chat
    case play
}

public struct DialogueLine: Codable, Equatable {
    public let speaker: String
    public let text: String
    public init(speaker: String, text: String) { self.speaker = speaker; self.text = text }
}

public struct SocialEntry: Codable, Identifiable {
    public let id: UUID
    public let partnerPetID: UUID
    public let partnerName: String?
    public let partnerGenome: PetGenome?
    public let date: Date
    public let interaction: SocialInteraction
    public var dialogue: [DialogueLine]
    public var isRevealed: Bool

    public init(
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
