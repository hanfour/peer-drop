import Foundation

struct PeerMessage: Codable {
    let version: ProtocolVersion
    let type: MessageType
    let payload: Data?
    let senderID: String

    init(type: MessageType, payload: Data? = nil, senderID: String) {
        self.version = .current
        self.type = type
        self.payload = payload
        self.senderID = senderID
    }

    // MARK: - Convenience encoders for typed payloads

    static func hello(identity: PeerIdentity) throws -> PeerMessage {
        let data = try JSONEncoder().encode(identity)
        return PeerMessage(type: .hello, payload: data, senderID: identity.id)
    }

    static func connectionRequest(senderID: String) -> PeerMessage {
        PeerMessage(type: .connectionRequest, senderID: senderID)
    }

    static func connectionAccept(senderID: String) -> PeerMessage {
        PeerMessage(type: .connectionAccept, senderID: senderID)
    }

    static func connectionReject(senderID: String) -> PeerMessage {
        PeerMessage(type: .connectionReject, senderID: senderID)
    }

    static func fileOffer(metadata: TransferMetadata, senderID: String) throws -> PeerMessage {
        let data = try JSONEncoder().encode(metadata)
        return PeerMessage(type: .fileOffer, payload: data, senderID: senderID)
    }

    static func fileAccept(senderID: String) -> PeerMessage {
        PeerMessage(type: .fileAccept, senderID: senderID)
    }

    static func fileReject(senderID: String) -> PeerMessage {
        PeerMessage(type: .fileReject, senderID: senderID)
    }

    static func fileChunk(_ data: Data, senderID: String) -> PeerMessage {
        PeerMessage(type: .fileChunk, payload: data, senderID: senderID)
    }

    static func fileComplete(hash: String, senderID: String) throws -> PeerMessage {
        let data = try JSONEncoder().encode(["hash": hash])
        return PeerMessage(type: .fileComplete, payload: data, senderID: senderID)
    }

    static func batchStart(metadata: BatchMetadata, senderID: String) throws -> PeerMessage {
        let data = try JSONEncoder().encode(metadata)
        return PeerMessage(type: .batchStart, payload: data, senderID: senderID)
    }

    static func batchComplete(batchID: String, senderID: String) throws -> PeerMessage {
        let data = try JSONEncoder().encode(["batchID": batchID])
        return PeerMessage(type: .batchComplete, payload: data, senderID: senderID)
    }

    static func disconnect(senderID: String) -> PeerMessage {
        PeerMessage(type: .disconnect, senderID: senderID)
    }

    // MARK: - Serialization

    func encoded() throws -> Data {
        try JSONEncoder().encode(self)
    }

    static func decoded(from data: Data) throws -> PeerMessage {
        try JSONDecoder().decode(PeerMessage.self, from: data)
    }

    // MARK: - Payload decoding

    func decodePayload<T: Decodable>(_ type: T.Type) throws -> T {
        guard let payload else {
            throw PeerMessageError.missingPayload
        }
        return try JSONDecoder().decode(type, from: payload)
    }
}

enum PeerMessageError: Error {
    case missingPayload
    case invalidPayload
}
