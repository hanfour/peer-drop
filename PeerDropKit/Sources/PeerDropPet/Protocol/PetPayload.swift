import Foundation

public enum PetPayloadType: String, Codable {
    case greeting
    case socialChat
    case reaction
}

public struct PetPayload: Codable {
    public let type: PetPayloadType
    public let data: Data

    public init(type: PetPayloadType, data: Data) { self.type = type; self.data = data }

    /// Wraps a PetGreeting for an in-network peer (no version negotiation
    /// performed). Use only when the peer is known to be at
    /// PetGreeting.currentProtocolVersion or higher — typically when
    /// echoing/forwarding a greeting whose origin already passed compat
    /// checks. For brand-new outbound greetings, prefer the explicit
    /// `greeting(_:forPeerProtocolVersion:)` form below so the call site
    /// names the peer version it's targeting.
    public static func greeting(_ greeting: PetGreeting) throws -> PetPayload {
        PetPayload(type: .greeting, data: try JSONEncoder().encode(greeting))
    }

    /// Wraps a PetGreeting for a peer at a known protocol version,
    /// downgrading any forward-incompatible fields before encoding. This is
    /// the safe default for outbound greetings to peers whose version is
    /// known from a prior exchange — a v4.0 .elder pet would otherwise fail
    /// a v1 peer's decode silently.
    public static func greeting(
        _ greeting: PetGreeting,
        forPeerProtocolVersion peerProtocolVersion: Int
    ) throws -> PetPayload {
        let safe = greeting.downgraded(toProtocolVersion: peerProtocolVersion)
        return PetPayload(type: .greeting, data: try JSONEncoder().encode(safe))
    }

    public static func socialChat(_ dialogue: [DialogueLine]) throws -> PetPayload {
        PetPayload(type: .socialChat, data: try JSONEncoder().encode(dialogue))
    }

    public static func reaction(_ action: PetAction) throws -> PetPayload {
        PetPayload(type: .reaction, data: try JSONEncoder().encode(action))
    }

    public func decodeGreeting() throws -> PetGreeting {
        try JSONDecoder().decode(PetGreeting.self, from: data)
    }

    public func decodeDialogue() throws -> [DialogueLine] {
        try JSONDecoder().decode([DialogueLine].self, from: data)
    }

    public func decodeReaction() throws -> PetAction {
        try JSONDecoder().decode(PetAction.self, from: data)
    }
}
