import Foundation
import PeerDropTransport

// MARK: - MessageSendingPeer conformance

/// Adapts `PeerConnection` (Core) to `MessageSendingPeer` (Transport) so
/// Transport types can hold a channel reference without importing Core.
extension PeerConnection: MessageSendingPeer {
    public var peerDisplayName: String { peerIdentity.displayName }
    // `sendMessage(_:)` async throws is already declared on PeerConnection.
}

// MARK: - TransportHost conformance

/// Adapts `ConnectionManager` to `TransportHost` so Transport types
/// (FileTransfer, VoiceCallManager, SDPSignaling, etc.) can drive UI
/// transitions and message dispatch without importing Core.
extension ConnectionManager: TransportHost {
    public var localPeerID: String { localIdentity.id }

    public var connectedPeerDisplayName: String? { connectedPeer?.displayName }

    public func messageChannel(for peerID: String) -> MessageSendingPeer? {
        connection(for: peerID)
    }

    // `sendMessage(_:)` and `sendMessage(_:to:)` async throws already exist.
    // `focusedPeerID` and `isPeerTrustedForUserActions(peerID:)` already exist.

    public func transferDidStart() {
        showTransferProgress = true
    }

    public func transferDidEnd() {
        showTransferProgress = false
        transition(to: .connected)
    }

    public func recordTransfer(_ record: TransferRecord) {
        transferHistory.insert(record, at: 0)
        latestToast = record
    }

    public func voiceCallDidStart() {
        transition(to: .voiceCall)
        showVoiceCall = true
    }

    public func voiceCallDidEnd() {
        showVoiceCall = false
        transition(to: .connected)
    }
}
