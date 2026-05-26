import Foundation

public struct MediaMessagePayload: Codable, Identifiable {
    public enum MediaType: String, Codable {
        case image
        case video
        case file
        case voice
    }

    public let id: String
    public let mediaType: MediaType
    public let fileName: String
    public let fileSize: Int64
    public let mimeType: String
    public let duration: Double?
    public let thumbnailData: Data?
    public let timestamp: Date

    public init(mediaType: MediaType, fileName: String, fileSize: Int64, mimeType: String, duration: Double?, thumbnailData: Data?) {
        self.id = UUID().uuidString
        self.mediaType = mediaType
        self.fileName = fileName
        self.fileSize = fileSize
        self.mimeType = mimeType
        self.duration = duration
        self.thumbnailData = thumbnailData
        self.timestamp = Date()
    }
}
