import Foundation

enum MessageStatus: String, Codable {
    case sending
    case sent
    case delivered
    case failed
}

struct ChatMessage: Identifiable, Codable {
    let id: String
    let text: String?
    let isMedia: Bool
    let mediaType: String?
    let fileName: String?
    let fileSize: Int64?
    let mimeType: String?
    let duration: Double?
    let thumbnailData: Data?
    var localFileURL: String?
    let isOutgoing: Bool
    let peerName: String
    var status: MessageStatus
    let timestamp: Date

    // Group messaging support
    let groupID: String?       // nil = 1-to-1 message
    let senderID: String?      // Identifies sender in group context
    let senderName: String?    // Display name for group messages

    init(
        id: String,
        text: String?,
        isMedia: Bool,
        mediaType: String?,
        fileName: String?,
        fileSize: Int64?,
        mimeType: String?,
        duration: Double?,
        thumbnailData: Data?,
        localFileURL: String?,
        isOutgoing: Bool,
        peerName: String,
        status: MessageStatus,
        timestamp: Date,
        groupID: String? = nil,
        senderID: String? = nil,
        senderName: String? = nil
    ) {
        self.id = id
        self.text = text
        self.isMedia = isMedia
        self.mediaType = mediaType
        self.fileName = fileName
        self.fileSize = fileSize
        self.mimeType = mimeType
        self.duration = duration
        self.thumbnailData = thumbnailData
        self.localFileURL = localFileURL
        self.isOutgoing = isOutgoing
        self.peerName = peerName
        self.status = status
        self.timestamp = timestamp
        self.groupID = groupID
        self.senderID = senderID
        self.senderName = senderName
    }

    // Custom decoding to handle backward compatibility with old messages
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        text = try container.decodeIfPresent(String.self, forKey: .text)
        isMedia = try container.decode(Bool.self, forKey: .isMedia)
        mediaType = try container.decodeIfPresent(String.self, forKey: .mediaType)
        fileName = try container.decodeIfPresent(String.self, forKey: .fileName)
        fileSize = try container.decodeIfPresent(Int64.self, forKey: .fileSize)
        mimeType = try container.decodeIfPresent(String.self, forKey: .mimeType)
        duration = try container.decodeIfPresent(Double.self, forKey: .duration)
        thumbnailData = try container.decodeIfPresent(Data.self, forKey: .thumbnailData)
        localFileURL = try container.decodeIfPresent(String.self, forKey: .localFileURL)
        isOutgoing = try container.decode(Bool.self, forKey: .isOutgoing)
        peerName = try container.decode(String.self, forKey: .peerName)
        status = try container.decode(MessageStatus.self, forKey: .status)
        timestamp = try container.decode(Date.self, forKey: .timestamp)
        // New fields with backward compatibility
        groupID = try container.decodeIfPresent(String.self, forKey: .groupID)
        senderID = try container.decodeIfPresent(String.self, forKey: .senderID)
        senderName = try container.decodeIfPresent(String.self, forKey: .senderName)
    }

    static func text(text: String, isOutgoing: Bool, peerName: String, groupID: String? = nil, senderID: String? = nil, senderName: String? = nil) -> ChatMessage {
        ChatMessage(
            id: UUID().uuidString,
            text: text,
            isMedia: false,
            mediaType: nil,
            fileName: nil,
            fileSize: nil,
            mimeType: nil,
            duration: nil,
            thumbnailData: nil,
            localFileURL: nil,
            isOutgoing: isOutgoing,
            peerName: peerName,
            status: isOutgoing ? .sending : .delivered,
            timestamp: Date(),
            groupID: groupID,
            senderID: senderID,
            senderName: senderName
        )
    }

    static func media(mediaType: String, fileName: String, fileSize: Int64, mimeType: String, duration: Double?, localFileURL: String?, thumbnailData: Data?, isOutgoing: Bool, peerName: String, groupID: String? = nil, senderID: String? = nil, senderName: String? = nil) -> ChatMessage {
        ChatMessage(
            id: UUID().uuidString,
            text: nil,
            isMedia: true,
            mediaType: mediaType,
            fileName: fileName,
            fileSize: fileSize,
            mimeType: mimeType,
            duration: duration,
            thumbnailData: thumbnailData,
            localFileURL: localFileURL,
            isOutgoing: isOutgoing,
            peerName: peerName,
            status: isOutgoing ? .sending : .delivered,
            timestamp: Date(),
            groupID: groupID,
            senderID: senderID,
            senderName: senderName
        )
    }

    /// Whether this message is a group message.
    var isGroupMessage: Bool {
        groupID != nil
    }
}
