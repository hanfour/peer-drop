import Foundation

public enum MessageStatus: String, Codable {
    case sending
    case sent
    case delivered
    case read
    case failed
}

/// Tracks delivery and read status for each group member.
public struct GroupReadStatus: Codable, Equatable {
    public var deliveredTo: Set<String> = []  // Peer IDs that received the message
    public var readBy: Set<String> = []       // Peer IDs that read the message
}

public struct ChatMessage: Identifiable, Codable {
    public let id: String
    public let text: String?
    public let isMedia: Bool
    public let mediaType: String?
    public let fileName: String?
    public let fileSize: Int64?
    public let mimeType: String?
    public let duration: Double?
    public let thumbnailData: Data?
    public var localFileURL: String?
    public let isOutgoing: Bool
    public let peerName: String
    public var status: MessageStatus
    public let timestamp: Date

    // Group messaging support
    public let groupID: String?       // nil = 1-to-1 message
    public let senderID: String?      // Identifies sender in group context
    public let senderName: String?    // Display name for group messages

    // Reply support
    public let replyToMessageID: String?    // ID of the message being replied to
    public let replyToText: String?         // Preview text of replied message
    public let replyToSenderName: String?   // Sender name of replied message

    // Edit / Delete support
    public var editedAt: Date?
    public var isDeleted: Bool

    // Reactions (emoji -> set of senderIDs)
    public var reactions: [String: Set<String>]?

    // Group read status (for outgoing group messages)
    public var groupReadStatus: GroupReadStatus?

    public init(
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
        senderName: String? = nil,
        replyToMessageID: String? = nil,
        replyToText: String? = nil,
        replyToSenderName: String? = nil,
        editedAt: Date? = nil,
        isDeleted: Bool = false,
        reactions: [String: Set<String>]? = nil,
        groupReadStatus: GroupReadStatus? = nil
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
        self.replyToMessageID = replyToMessageID
        self.replyToText = replyToText
        self.replyToSenderName = replyToSenderName
        self.editedAt = editedAt
        self.isDeleted = isDeleted
        self.reactions = reactions
        self.groupReadStatus = groupReadStatus
    }

    // Custom decoding to handle backward compatibility with old messages
    public init(from decoder: Decoder) throws {
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
        // Reply fields with backward compatibility
        replyToMessageID = try container.decodeIfPresent(String.self, forKey: .replyToMessageID)
        replyToText = try container.decodeIfPresent(String.self, forKey: .replyToText)
        replyToSenderName = try container.decodeIfPresent(String.self, forKey: .replyToSenderName)
        // Edit/Delete with backward compatibility
        editedAt = try container.decodeIfPresent(Date.self, forKey: .editedAt)
        isDeleted = try container.decodeIfPresent(Bool.self, forKey: .isDeleted) ?? false
        // Reactions with backward compatibility
        reactions = try container.decodeIfPresent([String: Set<String>].self, forKey: .reactions)
        // Group read status with backward compatibility
        groupReadStatus = try container.decodeIfPresent(GroupReadStatus.self, forKey: .groupReadStatus)
    }

    public static func text(text: String, isOutgoing: Bool, peerName: String, groupID: String? = nil, senderID: String? = nil, senderName: String? = nil, replyTo: ChatMessage? = nil) -> ChatMessage {
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
            senderName: senderName,
            replyToMessageID: replyTo?.id,
            replyToText: replyTo?.text ?? replyTo?.fileName,
            replyToSenderName: replyTo?.isOutgoing == true ? nil : (replyTo?.senderName ?? replyTo?.peerName)
        )
    }

    public static func media(mediaType: String, fileName: String, fileSize: Int64, mimeType: String, duration: Double?, localFileURL: String?, thumbnailData: Data?, isOutgoing: Bool, peerName: String, groupID: String? = nil, senderID: String? = nil, senderName: String? = nil, replyTo: ChatMessage? = nil) -> ChatMessage {
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
            senderName: senderName,
            replyToMessageID: replyTo?.id,
            replyToText: replyTo?.text ?? replyTo?.fileName,
            replyToSenderName: replyTo?.isOutgoing == true ? nil : (replyTo?.senderName ?? replyTo?.peerName)
        )
    }

    /// Whether this message is a group message.
    public var isGroupMessage: Bool {
        groupID != nil
    }

    /// Whether this message is a reply to another message.
    public var isReply: Bool {
        replyToMessageID != nil
    }

    /// Whether this message can still be edited or deleted (within 5 minutes).
    public var canEditOrDelete: Bool {
        isOutgoing && !isDeleted && !isMedia && Date().timeIntervalSince(timestamp) < 300
    }
}
