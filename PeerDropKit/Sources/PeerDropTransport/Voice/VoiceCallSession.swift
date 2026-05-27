import Foundation
import PeerDropProtocol
import PeerDropPlatform
import WebRTC
import os

private let logger = Logger(subsystem: "com.hanfour.peerdrop", category: "VoiceCallSession")

/// Per-peer voice call session that manages WebRTC state for a single connection.
@MainActor
public final class VoiceCallSession: ObservableObject {
    public let peerID: String

    @Published public private(set) var isInCall = false
    @Published public var isMuted = false {
        didSet { webRTCClient.isMuted = isMuted }
    }
    @Published public var isSpeakerOn = false {
        didSet { updateAudioOutput() }
    }

    private let webRTCClient = WebRTCClient()
    private let audioSession: AudioSessionConfiguring

    /// Callback to send messages through the connection.
    public var sendMessage: ((PeerMessage) async throws -> Void)?

    /// Callback when the call ends.
    public var onCallEnded: (() -> Void)?

    public init(peerID: String,
         audioSession: AudioSessionConfiguring = PlatformDependencies.shared.audioSession()) {
        self.peerID = peerID
        self.audioSession = audioSession
        setupCallbacks()
    }

    private func setupCallbacks() {
        webRTCClient.onICECandidate = { [weak self] candidate in
            Task { @MainActor in
                guard let self else { return }
                do {
                    try await self.sendICECandidate(candidate)
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

    // MARK: - Call Lifecycle

    public func startCall() async {
        webRTCClient.setup()
        isInCall = true
    }

    public func answerCall() async {
        webRTCClient.setup()
        isInCall = true
    }

    public func endCall() async {
        if isInCall {
            let end = PeerMessage(type: .callEnd, senderID: peerID)
            do {
                try await sendMessage?(end)
            } catch {
                logger.warning("Failed to send call end: \(error.localizedDescription)")
            }
        }
        endCallLocally()
    }

    public func endCallLocally() {
        webRTCClient.close()
        isInCall = false
        isMuted = false
        isSpeakerOn = false
        onCallEnded?()
    }

    // MARK: - Signaling

    public func createOffer() async throws -> RTCSessionDescription {
        try await webRTCClient.createOffer()
    }

    public func createAnswer() async throws -> RTCSessionDescription {
        try await webRTCClient.createAnswer()
    }

    public func setRemoteSDP(_ sdp: RTCSessionDescription) async throws {
        try await webRTCClient.setRemoteSDP(sdp)
    }

    public func addICECandidate(_ candidate: RTCIceCandidate) async throws {
        try await webRTCClient.addICECandidate(candidate)
    }

    public func sendOffer(_ sdp: RTCSessionDescription) async throws {
        let sdpMessage = SDPMessage(from: sdp)
        let payload = try JSONEncoder().encode(sdpMessage)
        let msg = PeerMessage(type: .sdpOffer, payload: payload, senderID: peerID)
        try await sendMessage?(msg)
    }

    public func sendAnswer(_ sdp: RTCSessionDescription) async throws {
        let sdpMessage = SDPMessage(from: sdp)
        let payload = try JSONEncoder().encode(sdpMessage)
        let msg = PeerMessage(type: .sdpAnswer, payload: payload, senderID: peerID)
        try await sendMessage?(msg)
    }

    public func sendICECandidate(_ candidate: RTCIceCandidate) async throws {
        let iceMessage = ICECandidateMessage(from: candidate)
        let payload = try JSONEncoder().encode(iceMessage)
        let msg = PeerMessage(type: .iceCandidate, payload: payload, senderID: peerID)
        try await sendMessage?(msg)
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
            endCallLocally()
        default:
            break
        }
    }
}
