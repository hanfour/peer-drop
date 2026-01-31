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

    // Voice call signaling
    case sdpOffer
    case sdpAnswer
    case iceCandidate
    case callRequest
    case callAccept
    case callReject
    case callEnd

    // Connection lifecycle
    case disconnect
}
