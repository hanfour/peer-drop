import Foundation
import AVFoundation
import WebRTC
import os

private let logger = Logger(subsystem: "com.hanfour.peerdrop", category: "VoiceCallSession")

/// Per-peer voice call session that manages WebRTC state for a single connection.
@MainActor
final class VoiceCallSession: ObservableObject {
    let peerID: String

    @Published private(set) var isInCall = false
    @Published var isMuted = false {
        didSet { webRTCClient.isMuted = isMuted }
    }
    @Published var isSpeakerOn = false {
        didSet { updateAudioOutput() }
    }

    private let webRTCClient = WebRTCClient()

    /// Callback to send messages through the connection.
    var sendMessage: ((PeerMessage) async throws -> Void)?

    /// Callback when the call ends.
    var onCallEnded: (() -> Void)?

    init(peerID: String) {
        self.peerID = peerID
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

    func startCall() async {
        webRTCClient.setup()
        isInCall = true
    }

    func answerCall() async {
        webRTCClient.setup()
        isInCall = true
    }

    func endCall() async {
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

    func endCallLocally() {
        webRTCClient.close()
        isInCall = false
        isMuted = false
        isSpeakerOn = false
        onCallEnded?()
    }

    // MARK: - Signaling

    func createOffer() async throws -> RTCSessionDescription {
        try await webRTCClient.createOffer()
    }

    func createAnswer() async throws -> RTCSessionDescription {
        try await webRTCClient.createAnswer()
    }

    func setRemoteSDP(_ sdp: RTCSessionDescription) async throws {
        try await webRTCClient.setRemoteSDP(sdp)
    }

    func addICECandidate(_ candidate: RTCIceCandidate) async throws {
        try await webRTCClient.addICECandidate(candidate)
    }

    func sendOffer(_ sdp: RTCSessionDescription) async throws {
        let sdpMessage = SDPMessage(from: sdp)
        let payload = try JSONEncoder().encode(sdpMessage)
        let msg = PeerMessage(type: .sdpOffer, payload: payload, senderID: peerID)
        try await sendMessage?(msg)
    }

    func sendAnswer(_ sdp: RTCSessionDescription) async throws {
        let sdpMessage = SDPMessage(from: sdp)
        let payload = try JSONEncoder().encode(sdpMessage)
        let msg = PeerMessage(type: .sdpAnswer, payload: payload, senderID: peerID)
        try await sendMessage?(msg)
    }

    func sendICECandidate(_ candidate: RTCIceCandidate) async throws {
        let iceMessage = ICECandidateMessage(from: candidate)
        let payload = try JSONEncoder().encode(iceMessage)
        let msg = PeerMessage(type: .iceCandidate, payload: payload, senderID: peerID)
        try await sendMessage?(msg)
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
