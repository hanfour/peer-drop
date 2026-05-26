import Foundation
import PeerDropProtocol
import PeerDropPlatform
import WebRTC
import os

private let logger = Logger(subsystem: "com.hanfour.peerdrop", category: "VoiceCallManager")

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
            try await self?.host?.sendMessage(message, to: peerID)
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
            host?.voiceCallDidEnd()
        }
        sessions.removeValue(forKey: peerID)
    }

    // MARK: - Legacy Single-Connection State

    private let webRTCClient = WebRTCClient()
    private let callProvider: any CallProvider
    private let audioSession: AudioSessionConfiguring
    private weak var host: TransportHost?
    private lazy var signaling: SDPSignaling? = {
        guard let host = host else {
            logger.error("host is nil when creating signaling")
            return nil
        }
        return SDPSignaling(host: host, senderID: "local")
    }()

    init(host: TransportHost,
         callProvider: any CallProvider,
         audioSession: AudioSessionConfiguring = PlatformDependencies.shared.audioSession()) {
        self.host = host
        self.callProvider = callProvider
        self.audioSession = audioSession
        setupCallbacks()
    }

    private func setupCallbacks() {
        callProvider.onAnswerCall = { [weak self] in
            Task { @MainActor in
                await self?.answerIncomingCall()
            }
        }

        callProvider.onEndCall = { [weak self] in
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
        guard let host = host else { return }
        guard let peerID = host.focusedPeerID else { return }
        guard let peerName = host.connectedPeerDisplayName else { return }

        // Use session-based calling for multi-connection
        let session = session(for: peerID)
        await session.startCall()
        activePeerID = peerID

        isInCall = true
        host.voiceCallDidStart()

        // Send call request over TCP
        let request = PeerMessage(type: .callRequest, senderID: host.localPeerID)
        do {
            try await host.sendMessage(request, to: peerID)
        } catch {
            logger.warning("Failed to send call request: \(error.localizedDescription)")
        }

        callProvider.startOutgoingCall(to: peerName)
    }

    /// Start a call to a specific peer.
    func startCall(to peerID: String) async {
        guard let host = host else { return }
        guard let peerChannel = host.messageChannel(for: peerID) else { return }

        let session = session(for: peerID)
        await session.startCall()
        activePeerID = peerID

        isInCall = true
        host.voiceCallDidStart()

        let request = PeerMessage(type: .callRequest, senderID: host.localPeerID)
        do {
            try await host.sendMessage(request, to: peerID)
        } catch {
            logger.warning("Failed to send call request to peer: \(error.localizedDescription)")
        }

        callProvider.startOutgoingCall(to: peerChannel.peerDisplayName)
    }

    // MARK: - Incoming Call

    func handleCallRequest(from senderID: String) {
        // Determine peer name
        let peerName: String
        if let peerChannel = host?.messageChannel(for: senderID) {
            peerName = peerChannel.peerDisplayName
        } else if let connectedName = host?.connectedPeerDisplayName {
            peerName = connectedName
        } else {
            peerName = "Unknown"
        }

        // Prepare session
        _ = session(for: senderID)
        activePeerID = senderID

        Task {
            do {
                try await callProvider.reportIncomingCall(from: peerName)
            } catch {
                logger.error("Failed to report incoming call: \(error.localizedDescription)")
                let reject = PeerMessage(type: .callReject, senderID: host?.localPeerID ?? "local")
                do {
                    try await host?.sendMessage(reject, to: senderID)
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
            host?.voiceCallDidStart()

            let accept = PeerMessage(type: .callAccept, senderID: host?.localPeerID ?? "local")
            do {
                try await host?.sendMessage(accept)
            } catch {
                logger.warning("Failed to send call accept: \(error.localizedDescription)")
            }
            return
        }

        let session = session(for: peerID)
        await session.answerCall()

        isInCall = true
        host?.voiceCallDidStart()

        let accept = PeerMessage(type: .callAccept, senderID: host?.localPeerID ?? "local")
        do {
            try await host?.sendMessage(accept, to: peerID)
        } catch {
            logger.warning("Failed to send call accept to peer: \(error.localizedDescription)")
        }
    }

    func handleCallAccept() {
        callProvider.reportOutgoingCallConnected()

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
                logger.error("Failed to create offer: \(error.localizedDescription)")
            }
        }
    }

    func handleCallReject(reason: String? = nil) {
        callProvider.reportCallEnded(reason: .declinedElsewhere)
        endCallLocally()
    }

    func handleCallEnd() {
        callProvider.reportCallEnded(reason: .remoteEnded)
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
                logger.error("Signaling error: \(error.localizedDescription)")
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
                let end = PeerMessage(type: .callEnd, senderID: host?.localPeerID ?? "local")
                do {
                    try await host?.sendMessage(end)
                } catch {
                    logger.warning("Failed to send call end: \(error.localizedDescription)")
                }
            }
        }
        callProvider.endCall()
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
        host?.voiceCallDidEnd()
    }

    // MARK: - Audio

    private func updateAudioOutput() {
        do {
            try audioSession.overrideOutputToSpeaker(isSpeakerOn)
        } catch {
            logger.error("Audio output error: \(error.localizedDescription)")
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
