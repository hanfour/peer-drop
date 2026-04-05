import Foundation

struct ClipboardSyncPayload: Codable {
    enum ContentType: String, Codable {
        case text
        case image
        case url
    }

    let contentType: ContentType
    let textContent: String?
    let imageData: Data?
    let timestamp: Date

    init(contentType: ContentType, textContent: String? = nil, imageData: Data? = nil) {
        self.contentType = contentType
        self.textContent = textContent
        self.imageData = imageData
        self.timestamp = Date()
    }
}
