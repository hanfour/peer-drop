import Foundation

enum MessageType: String, Codable {
    // Handshake
    case hello
    case connectionRequest
    case connectionAccept
    case connectionReject
    case connectionCancel

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
    case chatReject
    case messageReceipt
    case typingIndicator
    case reaction
    case messageEdit
    case messageDelete

    // Clipboard sync
    case clipboardSync

    // File transfer resume
    case fileResume
    case fileResumeAck

    // Connection lifecycle
    case disconnect

    // Nearby Interaction token exchange
    case niTokenOffer
    case niTokenResponse

    // Heartbeat keepalive
    case ping
    case pong

    // Stable device identity (for invite routing)
    case deviceIdExchange
}
