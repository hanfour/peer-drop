import Foundation

public struct ClipboardSyncPayload: Codable {
    public enum ContentType: String, Codable {
        case text
        case image
        case url
    }

    public let contentType: ContentType
    public let textContent: String?
    public let imageData: Data?
    public let timestamp: Date

    public init(contentType: ContentType, textContent: String? = nil, imageData: Data? = nil) {
        self.contentType = contentType
        self.textContent = textContent
        self.imageData = imageData
        self.timestamp = Date()
    }
}
