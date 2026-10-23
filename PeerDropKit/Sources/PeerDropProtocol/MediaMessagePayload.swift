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
    /// The media bytes, inline. Optional on the wire: a peer older than this
    /// field sends none and a receiver that doesn't know it ignores it, so both
    /// directions degrade to the old thumbnail-only behaviour.
    public let fileData: Data?
    public let timestamp: Date

    /// Largest file sent inline. The payload is JSON (base64, +33%) inside a
    /// ratchet envelope that is JSON again (+33%), so ~1.8x on the wire against
    /// `MessageFramer.maxMessageSize` (100 MB); 32 MB keeps clear margin.
    public static let maxInlineFileSize = 32 * 1024 * 1024

    public init(mediaType: MediaType, fileName: String, fileSize: Int64, mimeType: String, duration: Double?, thumbnailData: Data?, fileData: Data? = nil, id: String? = nil) {
        self.id = id ?? UUID().uuidString
        self.mediaType = mediaType
        self.fileName = fileName
        self.fileSize = fileSize
        self.mimeType = mimeType
        self.duration = duration
        self.thumbnailData = thumbnailData
        self.fileData = fileData
        self.timestamp = Date()
    }

    /// `fileData` if it is trustworthy to store, else nil. `fileSize` is the
    /// peer's claim, so bytes that don't match it (or exceed the cap) are dropped.
    public var validatedFileData: Data? {
        guard let fileData, fileData.count <= Self.maxInlineFileSize,
              Int64(fileData.count) == fileSize else { return nil }
        return fileData
    }
}
