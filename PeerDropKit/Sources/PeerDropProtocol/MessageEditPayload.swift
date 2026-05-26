import Foundation

public struct MessageEditPayload: Codable {
    public let messageID: String
    public let newText: String
    public let editedAt: Date
    public let groupID: String?

    public init(messageID: String, newText: String, groupID: String? = nil) {
        self.messageID = messageID
        self.newText = newText
        self.editedAt = Date()
        self.groupID = groupID
    }
}

public struct MessageDeletePayload: Codable {
    public let messageID: String
    public let groupID: String?

    public init(messageID: String, groupID: String? = nil) {
        self.messageID = messageID
        self.groupID = groupID
    }
}
