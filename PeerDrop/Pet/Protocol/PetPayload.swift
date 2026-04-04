import Foundation

enum PetPayloadType: String, Codable {
    case greeting
    case socialChat
    case reaction
}

struct PetPayload: Codable {
    let type: PetPayloadType
    let data: Data

    static func greeting(_ greeting: PetGreeting) throws -> PetPayload {
        PetPayload(type: .greeting, data: try JSONEncoder().encode(greeting))
    }

    static func socialChat(_ dialogue: [DialogueLine]) throws -> PetPayload {
        PetPayload(type: .socialChat, data: try JSONEncoder().encode(dialogue))
    }

    static func reaction(_ action: PetAction) throws -> PetPayload {
        PetPayload(type: .reaction, data: try JSONEncoder().encode(action))
    }

    func decodeGreeting() throws -> PetGreeting {
        try JSONDecoder().decode(PetGreeting.self, from: data)
    }

    func decodeDialogue() throws -> [DialogueLine] {
        try JSONDecoder().decode([DialogueLine].self, from: data)
    }

    func decodeReaction() throws -> PetAction {
        try JSONDecoder().decode(PetAction.self, from: data)
    }
}
