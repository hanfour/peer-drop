import Foundation
import AVFoundation
import WebRTC
import os

private let logger = Logger(subsystem: "com.peerdrop.app", category: "VoiceCallManager")

/// Coordinates WebRTC + CallKit for voice call lifecycle.
/// Supports both legacy single-connection mode and multi-connection session pool.
@MainActor
final class VoiceCallManager: ObservableObject {
    @Published private(set) var isInCall = false
    @Published var isMuted = false {
        didSet {
            webRTCClient.isMuted = isMuted
            // Also update active session
            if let peerID = activePeerID, let session = sessions[peerID] {
                session.isMuted = isMuted
            }
        }
    }
    @Published var isSpeakerOn = false {
        didSet {
            updateAudioOutput()
            // Also update active session
            if let peerID = activePeerID, let session = sessions[peerID] {
                session.isSpeakerOn = isSpeakerOn
            }
        }
    }

    // MARK: - Session Pool (Multi-Connection Support)

    /// Active voice call sessions, keyed by peerID.
    private var sessions: [String: VoiceCallSession] = [:]

    /// The peer ID of the currently active call (only one call at a time).
    private(set) var activePeerID: String?

    /// Get or create a voice call session for a peer.
    func session(for peerID: String) -> VoiceCallSession {
        if let existing = sessions[peerID] {
            return existing
        }
        let session = VoiceCallSession(peerID: peerID)
        session.sendMessage = { [weak self] message in
            try await self?.connectionManager?.sendMessage(message, to: peerID)
        }
        session.onCallEnded = { [weak self] in
            self?.handleSessionEnded(peerID: peerID)
        }
        sessions[peerID] = session
        return session
    }

    /// Remove a session when peer disconnects.
    func removeSession(for peerID: String) {
        if let session = sessions[peerID] {
            session.endCallLocally()
        }
        sessions.removeValue(forKey: peerID)
        if activePeerID == peerID {
            activePeerID = nil
        }
    }

    private func handleSessionEnded(peerID: String) {
        if activePeerID == peerID {
            activePeerID = nil
            isInCall = false
            isMuted = false
            isSpeakerOn = false
            connectionManager?.showVoiceCall = false
            connectionManager?.transition(to: .connected)
        }
        sessions.removeValue(forKey: peerID)
    }

    // MARK: - Legacy Single-Connection State

    private let webRTCClient = WebRTCClient()
    private let callKitManager: CallKitManager
    private weak var connectionManager: ConnectionManager?
    private lazy var signaling: SDPSignaling? = {
        guard let manager = connectionManager else {
            print("[VoiceCallManager] connectionManager is nil when creating signaling")
            return nil
        }
        return SDPSignaling(connectionManager: manager, senderID: "local")
    }()

    init(connectionManager: ConnectionManager, callKitManager: CallKitManager) {
        self.connectionManager = connectionManager
        self.callKitManager = callKitManager
        setupCallbacks()
    }

    private func setupCallbacks() {
        callKitManager.onAnswerCall = { [weak self] in
            Task { @MainActor in
                await self?.answerIncomingCall()
            }
        }

        callKitManager.onEndCall = { [weak self] in
            Task { @MainActor in
                self?.endCallLocally()
            }
        }

        webRTCClient.onICECandidate = { [weak self] candidate in
            Task { @MainActor in
                do {
                    try await self?.signaling?.sendICECandidate(candidate)
                } catch {
                    logger.warning("Failed to send ICE candidate: \(error.localizedDescription)")
                }
            }
        }

        webRTCClient.onConnectionStateChange = { [weak self] state in
            Task { @MainActor in
                self?.handleWebRTCStateChange(state)
            }
        }
    }

    // MARK: - Outgoing Call

    func startCall() async {
        guard let manager = connectionManager else { return }
        guard let peerID = manager.focusedPeerID else { return }
        guard let peer = manager.connectedPeer else { return }

        // Use session-based calling for multi-connection
        let session = session(for: peerID)
        await session.startCall()
        activePeerID = peerID

        isInCall = true
        manager.transition(to: .voiceCall)
        manager.showVoiceCall = true

        // Send call request over TCP
        let request = PeerMessage(type: .callRequest, senderID: manager.localIdentity.id)
        do {
            try await manager.sendMessage(request, to: peerID)
        } catch {
            logger.warning("Failed to send call request: \(error.localizedDescription)")
        }

        callKitManager.startOutgoingCall(to: peer.displayName)
    }

    /// Start a call to a specific peer.
    func startCall(to peerID: String) async {
        guard let manager = connectionManager else { return }
        guard let peerConn = manager.connection(for: peerID) else { return }

        let session = session(for: peerID)
        await session.startCall()
        activePeerID = peerID

        isInCall = true
        manager.transition(to: .voiceCall)
        manager.showVoiceCall = true

        let request = PeerMessage(type: .callRequest, senderID: manager.localIdentity.id)
        do {
            try await manager.sendMessage(request, to: peerID)
        } catch {
            logger.warning("Failed to send call request to peer: \(error.localizedDescription)")
        }

        callKitManager.startOutgoingCall(to: peerConn.peerIdentity.displayName)
    }

    // MARK: - Incoming Call

    func handleCallRequest(from senderID: String) {
        // Determine peer name
        let peerName: String
        if let peerConn = connectionManager?.connection(for: senderID) {
            peerName = peerConn.peerIdentity.displayName
        } else if let peer = connectionManager?.connectedPeer {
            peerName = peer.displayName
        } else {
            peerName = "Unknown"
        }

        // Prepare session
        _ = session(for: senderID)
        activePeerID = senderID

        Task {
            do {
                try await callKitManager.reportIncomingCall(from: peerName)
            } catch {
                print("[VoiceCallManager] Failed to report incoming call: \(error)")
                let reject = PeerMessage(type: .callReject, senderID: connectionManager?.localIdentity.id ?? "local")
                do {
                    try await connectionManager?.sendMessage(reject, to: senderID)
                } catch {
                    logger.warning("Failed to send call reject: \(error.localizedDescription)")
                }
                removeSession(for: senderID)
            }
        }
    }

    private func answerIncomingCall() async {
        guard let peerID = activePeerID else {
            // Fallback to legacy behavior
            webRTCClient.setup()
            isInCall = true
            connectionManager?.transition(to: .voiceCall)
            connectionManager?.showVoiceCall = true

            let accept = PeerMessage(type: .callAccept, senderID: connectionManager?.localIdentity.id ?? "local")
            do {
                try await connectionManager?.sendMessage(accept)
            } catch {
                logger.warning("Failed to send call accept: \(error.localizedDescription)")
            }
            return
        }

        let session = session(for: peerID)
        await session.answerCall()

        isInCall = true
        connectionManager?.transition(to: .voiceCall)
        connectionManager?.showVoiceCall = true

        let accept = PeerMessage(type: .callAccept, senderID: connectionManager?.localIdentity.id ?? "local")
        do {
            try await connectionManager?.sendMessage(accept, to: peerID)
        } catch {
            logger.warning("Failed to send call accept to peer: \(error.localizedDescription)")
        }
    }

    func handleCallAccept() {
        callKitManager.reportOutgoingCallConnected()

        // Initiator creates SDP offer
        Task {
            do {
                if let peerID = activePeerID, let session = sessions[peerID] {
                    let offer = try await session.createOffer()
                    try await session.sendOffer(offer)
                } else {
                    // Legacy fallback
                    let offer = try await webRTCClient.createOffer()
                    try await signaling?.sendOffer(offer)
                }
            } catch {
                print("[VoiceCallManager] Failed to create offer: \(error)")
            }
        }
    }

    func handleCallReject(reason: String? = nil) {
        callKitManager.reportCallEnded(reason: .declinedElsewhere)
        endCallLocally()
    }

    func handleCallEnd() {
        callKitManager.reportCallEnded(reason: .remoteEnded)
        endCallLocally()
    }

    // MARK: - Signaling

    func handleSignaling(_ message: PeerMessage) {
        guard let payload = message.payload else { return }

        Task {
            do {
                // Try session-based signaling first
                if let peerID = activePeerID, let session = sessions[peerID] {
                    switch message.type {
                    case .sdpOffer:
                        let sdpMsg = try JSONDecoder().decode(SDPMessage.self, from: payload)
                        let sdp = sdpMsg.toRTCSessionDescription()
                        try await session.setRemoteSDP(sdp)
                        let answer = try await session.createAnswer()
                        try await session.sendAnswer(answer)

                    case .sdpAnswer:
                        let sdpMsg = try JSONDecoder().decode(SDPMessage.self, from: payload)
                        let sdp = sdpMsg.toRTCSessionDescription()
                        try await session.setRemoteSDP(sdp)

                    case .iceCandidate:
                        let iceMsg = try JSONDecoder().decode(ICECandidateMessage.self, from: payload)
                        let candidate = iceMsg.toRTCIceCandidate()
                        try await session.addICECandidate(candidate)

                    default:
                        break
                    }
                    return
                }

                // Legacy fallback
                switch message.type {
                case .sdpOffer:
                    let sdpMsg = try JSONDecoder().decode(SDPMessage.self, from: payload)
                    let sdp = sdpMsg.toRTCSessionDescription()
                    try await webRTCClient.setRemoteSDP(sdp)
                    let answer = try await webRTCClient.createAnswer()
                    try await signaling?.sendAnswer(answer)

                case .sdpAnswer:
                    let sdpMsg = try JSONDecoder().decode(SDPMessage.self, from: payload)
                    let sdp = sdpMsg.toRTCSessionDescription()
                    try await webRTCClient.setRemoteSDP(sdp)

                case .iceCandidate:
                    let iceMsg = try JSONDecoder().decode(ICECandidateMessage.self, from: payload)
                    let candidate = iceMsg.toRTCIceCandidate()
                    try await webRTCClient.addICECandidate(candidate)

                default:
                    break
                }
            } catch {
                print("[VoiceCallManager] Signaling error: \(error)")
            }
        }
    }

    // MARK: - End Call

    func endCall() {
        if let peerID = activePeerID {
            // Session-based end
            Task {
                await sessions[peerID]?.endCall()
            }
        } else {
            // Legacy end
            Task {
                let end = PeerMessage(type: .callEnd, senderID: connectionManager?.localIdentity.id ?? "local")
                do {
                    try await connectionManager?.sendMessage(end)
                } catch {
                    logger.warning("Failed to send call end: \(error.localizedDescription)")
                }
            }
        }
        callKitManager.endCall()
        endCallLocally()
    }

    private func endCallLocally() {
        if let peerID = activePeerID {
            sessions[peerID]?.endCallLocally()
            sessions.removeValue(forKey: peerID)
            activePeerID = nil
        }

        webRTCClient.close()
        isInCall = false
        isMuted = false
        isSpeakerOn = false
        connectionManager?.showVoiceCall = false
        connectionManager?.transition(to: .connected)
    }

    // MARK: - Audio

    private func updateAudioOutput() {
        let session = AVAudioSession.sharedInstance()
        do {
            if isSpeakerOn {
                try session.overrideOutputAudioPort(.speaker)
            } else {
                try session.overrideOutputAudioPort(.none)
            }
        } catch {
            print("[VoiceCallManager] Audio output error: \(error)")
        }
    }

    private func handleWebRTCStateChange(_ state: RTCIceConnectionState) {
        switch state {
        case .disconnected, .failed, .closed:
            endCall()
        default:
            break
        }
    }
}
