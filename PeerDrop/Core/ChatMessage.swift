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

    static func text(text: String, isOutgoing: Bool, peerName: String) -> ChatMessage {
        ChatMessage(id: UUID().uuidString, text: text, isMedia: false, mediaType: nil, fileName: nil, fileSize: nil, mimeType: nil, duration: nil, thumbnailData: nil, localFileURL: nil, isOutgoing: isOutgoing, peerName: peerName, status: isOutgoing ? .sending : .delivered, timestamp: Date())
    }

    static func media(mediaType: String, fileName: String, fileSize: Int64, mimeType: String, duration: Double?, localFileURL: String?, thumbnailData: Data?, isOutgoing: Bool, peerName: String) -> ChatMessage {
        ChatMessage(id: UUID().uuidString, text: nil, isMedia: true, mediaType: mediaType, fileName: fileName, fileSize: fileSize, mimeType: mimeType, duration: duration, thumbnailData: thumbnailData, localFileURL: localFileURL, isOutgoing: isOutgoing, peerName: peerName, status: isOutgoing ? .sending : .delivered, timestamp: Date())
    }
}
