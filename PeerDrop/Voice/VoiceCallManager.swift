import Foundation
import WebRTC

/// Coordinates WebRTC + CallKit for voice call lifecycle.
@MainActor
final class VoiceCallManager: ObservableObject {
    @Published private(set) var isInCall = false
    @Published var isMuted = false {
        didSet { webRTCClient.isMuted = isMuted }
    }
    @Published var isSpeakerOn = false {
        didSet { updateAudioOutput() }
    }

    private let webRTCClient = WebRTCClient()
    private let callKitManager: CallKitManager
    private weak var connectionManager: ConnectionManager?
    private lazy var signaling: SDPSignaling = {
        SDPSignaling(connectionManager: connectionManager!, senderID: "local")
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
                try? await self?.signaling.sendICECandidate(candidate)
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
        guard let peer = connectionManager?.connectedPeer else { return }

        webRTCClient.setup()
        isInCall = true
        connectionManager?.transition(to: .voiceCall)

        // Send call request over TCP
        let request = PeerMessage(type: .callRequest, senderID: "local")
        try? await connectionManager?.sendMessage(request)

        callKitManager.startOutgoingCall(to: peer.displayName)
    }

    // MARK: - Incoming Call

    func handleCallRequest(from senderID: String) {
        guard let peer = connectionManager?.connectedPeer else { return }

        Task {
            do {
                try await callKitManager.reportIncomingCall(from: peer.displayName)
            } catch {
                print("[VoiceCallManager] Failed to report incoming call: \(error)")
                let reject = PeerMessage(type: .callReject, senderID: "local")
                try? await connectionManager?.sendMessage(reject)
            }
        }
    }

    private func answerIncomingCall() async {
        webRTCClient.setup()
        isInCall = true
        connectionManager?.transition(to: .voiceCall)
        connectionManager?.showVoiceCall = true

        let accept = PeerMessage(type: .callAccept, senderID: "local")
        try? await connectionManager?.sendMessage(accept)
    }

    func handleCallAccept() {
        callKitManager.reportOutgoingCallConnected()

        // Initiator creates SDP offer
        Task {
            do {
                let offer = try await webRTCClient.createOffer()
                try await signaling.sendOffer(offer)
            } catch {
                print("[VoiceCallManager] Failed to create offer: \(error)")
            }
        }
    }

    func handleCallReject() {
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
                switch message.type {
                case .sdpOffer:
                    let sdpMsg = try JSONDecoder().decode(SDPMessage.self, from: payload)
                    let sdp = sdpMsg.toRTCSessionDescription()
                    try await webRTCClient.setRemoteSDP(sdp)
                    let answer = try await webRTCClient.createAnswer()
                    try await signaling.sendAnswer(answer)

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
        Task {
            let end = PeerMessage(type: .callEnd, senderID: "local")
            try? await connectionManager?.sendMessage(end)
        }
        callKitManager.endCall()
        endCallLocally()
    }

    private func endCallLocally() {
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

import AVFoundation
