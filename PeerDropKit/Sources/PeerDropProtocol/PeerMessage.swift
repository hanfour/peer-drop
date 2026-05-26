import Foundation

public struct PeerMessage: Codable {
    public let version: ProtocolVersion
    public let type: MessageType
    public let payload: Data?
    public let senderID: String

    public init(type: MessageType, payload: Data? = nil, senderID: String) {
        self.version = .current
        self.type = type
        self.payload = payload
        self.senderID = senderID
    }

    // MARK: - Convenience encoders for typed payloads

    public static func deviceIdExchange(deviceId: String, senderID: String) throws -> PeerMessage {
        let data = try JSONEncoder().encode(DeviceIdExchangePayload(deviceId: deviceId))
        return PeerMessage(type: .deviceIdExchange, payload: data, senderID: senderID)
    }

    /// Wrap an already-encrypted secure-channel frame for transport. Caller
    /// is responsible for having an active LocalSecureChannel and produced
    /// the `frame` via `channel.encrypt(...)`.
    public static func secureEnvelope(frame: Data, senderID: String) -> PeerMessage {
        PeerMessage(type: .secureEnvelope, payload: frame, senderID: senderID)
    }

    public static func connectionRequest(senderID: String) -> PeerMessage {
        PeerMessage(type: .connectionRequest, senderID: senderID)
    }

    public static func connectionAccept(senderID: String) -> PeerMessage {
        PeerMessage(type: .connectionAccept, senderID: senderID)
    }

    public static func connectionReject(senderID: String) -> PeerMessage {
        PeerMessage(type: .connectionReject, senderID: senderID)
    }

    public static func connectionCancel(senderID: String) -> PeerMessage {
        PeerMessage(type: .connectionCancel, senderID: senderID)
    }

    public static func fileAccept(senderID: String) -> PeerMessage {
        PeerMessage(type: .fileAccept, senderID: senderID)
    }

    public static func fileReject(senderID: String, reason: String? = nil) -> PeerMessage {
        if let reason {
            let data = try? JSONEncoder().encode(RejectionPayload(reason: reason))
            return PeerMessage(type: .fileReject, payload: data, senderID: senderID)
        }
        return PeerMessage(type: .fileReject, senderID: senderID)
    }

    public static func callReject(senderID: String, reason: String? = nil) -> PeerMessage {
        if let reason {
            let data = try? JSONEncoder().encode(RejectionPayload(reason: reason))
            return PeerMessage(type: .callReject, payload: data, senderID: senderID)
        }
        return PeerMessage(type: .callReject, senderID: senderID)
    }

    public static func chatReject(senderID: String, reason: String? = nil) -> PeerMessage {
        if let reason {
            let data = try? JSONEncoder().encode(RejectionPayload(reason: reason))
            return PeerMessage(type: .chatReject, payload: data, senderID: senderID)
        }
        return PeerMessage(type: .chatReject, senderID: senderID)
    }

    public static func fileChunk(_ data: Data, senderID: String) -> PeerMessage {
        PeerMessage(type: .fileChunk, payload: data, senderID: senderID)
    }

    public static func fileComplete(hash: String, senderID: String) throws -> PeerMessage {
        let data = try JSONEncoder().encode(["hash": hash])
        return PeerMessage(type: .fileComplete, payload: data, senderID: senderID)
    }

    public static func batchComplete(batchID: String, senderID: String) throws -> PeerMessage {
        let data = try JSONEncoder().encode(["batchID": batchID])
        return PeerMessage(type: .batchComplete, payload: data, senderID: senderID)
    }

    public static func textMessage(_ payload: TextMessagePayload, senderID: String) throws -> PeerMessage {
        let data = try JSONEncoder().encode(payload)
        return PeerMessage(type: .textMessage, payload: data, senderID: senderID)
    }

    public static func mediaMessage(_ payload: MediaMessagePayload, senderID: String) throws -> PeerMessage {
        let data = try JSONEncoder().encode(payload)
        return PeerMessage(type: .mediaMessage, payload: data, senderID: senderID)
    }

    public static func disconnect(senderID: String) -> PeerMessage {
        PeerMessage(type: .disconnect, senderID: senderID)
    }

    public static func ping(senderID: String) -> PeerMessage {
        PeerMessage(type: .ping, senderID: senderID)
    }

    public static func pong(senderID: String) -> PeerMessage {
        PeerMessage(type: .pong, senderID: senderID)
    }

    public static func messageReceipt(_ payload: MessageReceiptPayload, senderID: String) throws -> PeerMessage {
        let data = try JSONEncoder().encode(payload)
        return PeerMessage(type: .messageReceipt, payload: data, senderID: senderID)
    }

    public static func typingIndicator(_ payload: TypingIndicatorPayload, senderID: String) throws -> PeerMessage {
        let data = try JSONEncoder().encode(payload)
        return PeerMessage(type: .typingIndicator, payload: data, senderID: senderID)
    }

    public static func reaction(_ payload: ReactionPayload, senderID: String) throws -> PeerMessage {
        let data = try JSONEncoder().encode(payload)
        return PeerMessage(type: .reaction, payload: data, senderID: senderID)
    }

    public static func messageEdit(_ payload: MessageEditPayload, senderID: String) throws -> PeerMessage {
        let data = try JSONEncoder().encode(payload)
        return PeerMessage(type: .messageEdit, payload: data, senderID: senderID)
    }

    public static func messageDelete(_ payload: MessageDeletePayload, senderID: String) throws -> PeerMessage {
        let data = try JSONEncoder().encode(payload)
        return PeerMessage(type: .messageDelete, payload: data, senderID: senderID)
    }

    public static func clipboardSync(_ payload: ClipboardSyncPayload, senderID: String) throws -> PeerMessage {
        let data = try JSONEncoder().encode(payload)
        return PeerMessage(type: .clipboardSync, payload: data, senderID: senderID)
    }

    public static func fileResume(_ payload: FileResumePayload, senderID: String) throws -> PeerMessage {
        let data = try JSONEncoder().encode(payload)
        return PeerMessage(type: .fileResume, payload: data, senderID: senderID)
    }

    public static func fileResumeAck(_ payload: FileResumeAckPayload, senderID: String) throws -> PeerMessage {
        let data = try JSONEncoder().encode(payload)
        return PeerMessage(type: .fileResumeAck, payload: data, senderID: senderID)
    }

    // MARK: - Serialization

    public func encoded() throws -> Data {
        try JSONEncoder().encode(self)
    }

    public static func decoded(from data: Data) throws -> PeerMessage {
        try JSONDecoder().decode(PeerMessage.self, from: data)
    }

    // MARK: - Payload decoding

    public func decodePayload<T: Decodable>(_ type: T.Type) throws -> T {
        guard let payload else {
            throw PeerMessageError.missingPayload
        }
        return try JSONDecoder().decode(type, from: payload)
    }
}

public struct RejectionPayload: Codable {
    public let reason: String

    public init(reason: String) {
        self.reason = reason
    }
}

public struct DeviceIdExchangePayload: Codable {
    public let deviceId: String

    public init(deviceId: String) {
        self.deviceId = deviceId
    }
}

public enum PeerMessageError: Error {
    case missingPayload
    case invalidPayload
}
