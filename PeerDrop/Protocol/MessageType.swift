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

    // Local-TCP E2E secure channel (v5.0.3+, audit-#13 Phase 2).
    // - .secureHandshake: peer exchanges LocalSecureChannel.HandshakeBundle
    //   in plaintext to bootstrap the Double Ratchet session.
    // - .secureEnvelope: encrypted wrapper around a PeerMessage. Once both
    //   peers have completed the handshake, all non-control messages flow
    //   through this envelope automatically.
    case secureHandshake
    case secureEnvelope
}
