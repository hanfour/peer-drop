import Foundation

enum MessageType: String, Codable {
    // Handshake
    case hello
    case connectionRequest
    case connectionAccept
    case connectionReject

    // File transfer
    case fileOffer
    case fileAccept
    case fileReject
    case fileChunk
    case fileComplete

    // Multi-file batch transfer
    case batchStart
    case batchComplete

    // Voice call signaling
    case sdpOffer
    case sdpAnswer
    case iceCandidate
    case callRequest
    case callAccept
    case callReject
    case callEnd

    // Chat messaging
    case textMessage
    case mediaMessage

    // Connection lifecycle
    case disconnect
}
