import Foundation

enum PetPayloadType: String, Codable {
    case greeting
    case socialChat
    case reaction
}

struct PetPayload: Codable {
    let type: PetPayloadType
    let data: Data

    /// Wraps a PetGreeting for an in-network peer (no version negotiation
    /// performed). Use only when the peer is known to be at
    /// PetGreeting.currentProtocolVersion or higher — typically when
    /// echoing/forwarding a greeting whose origin already passed compat
    /// checks. For brand-new outbound greetings, prefer the explicit
    /// `greeting(_:forPeerProtocolVersion:)` form below so the call site
    /// names the peer version it's targeting.
    static func greeting(_ greeting: PetGreeting) throws -> PetPayload {
        PetPayload(type: .greeting, data: try JSONEncoder().encode(greeting))
    }

    /// Wraps a PetGreeting for a peer at a known protocol version,
    /// downgrading any forward-incompatible fields before encoding. This is
    /// the safe default for outbound greetings to peers whose version is
    /// known from a prior exchange — a v4.0 .elder pet would otherwise fail
    /// a v1 peer's decode silently.
    static func greeting(
        _ greeting: PetGreeting,
        forPeerProtocolVersion peerProtocolVersion: Int
    ) throws -> PetPayload {
        let safe = greeting.downgraded(toProtocolVersion: peerProtocolVersion)
        return PetPayload(type: .greeting, data: try JSONEncoder().encode(safe))
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
