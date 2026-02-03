import Foundation

struct MediaMessagePayload: Codable, Identifiable {
    enum MediaType: String, Codable {
        case image
        case video
        case file
        case voice
    }

    let id: String
    let mediaType: MediaType
    let fileName: String
    let fileSize: Int64
    let mimeType: String
    let duration: Double?
    let thumbnailData: Data?
    let timestamp: Date

    init(mediaType: MediaType, fileName: String, fileSize: Int64, mimeType: String, duration: Double?, thumbnailData: Data?) {
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
