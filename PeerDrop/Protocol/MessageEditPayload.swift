import Foundation

struct MessageEditPayload: Codable {
    let messageID: String
    let newText: String
    let editedAt: Date
    let groupID: String?

    init(messageID: String, newText: String, groupID: String? = nil) {
        self.messageID = messageID
        self.newText = newText
        self.editedAt = Date()
        self.groupID = groupID
    }
}

struct MessageDeletePayload: Codable {
    let messageID: String
    let groupID: String?

    init(messageID: String, groupID: String? = nil) {
        self.messageID = messageID
        self.groupID = groupID
    }
}
