import Foundation
@preconcurrency import WebRTC

/// Wrapper around RTCPeerConnection for voice calls.
final class WebRTCClient: NSObject {
    private let peerConnectionFactory: RTCPeerConnectionFactory
    private var peerConnection: RTCPeerConnection?
    private var localAudioTrack: RTCAudioTrack?

    var onLocalSDP: ((RTCSessionDescription) -> Void)?
    var onICECandidate: ((RTCIceCandidate) -> Void)?
    var onConnectionStateChange: ((RTCIceConnectionState) -> Void)?

    override init() {
        RTCInitializeSSL()
        let encoderFactory = RTCDefaultVideoEncoderFactory()
        let decoderFactory = RTCDefaultVideoDecoderFactory()
        peerConnectionFactory = RTCPeerConnectionFactory(
            encoderFactory: encoderFactory,
            decoderFactory: decoderFactory
        )
        super.init()
    }

    deinit {
        RTCCleanupSSL()
    }

    // MARK: - Setup

    func setup() {
        let config = RTCConfiguration()
        // No ICE servers — direct P2P only
        config.iceServers = []
        config.sdpSemantics = .unifiedPlan

        let constraints = RTCMediaConstraints(
            mandatoryConstraints: nil,
            optionalConstraints: nil
        )

        peerConnection = peerConnectionFactory.peerConnection(
            with: config,
            constraints: constraints,
            delegate: self
        )

        addAudioTrack()
    }

    private func addAudioTrack() {
        let audioConstraints = RTCMediaConstraints(
            mandatoryConstraints: nil,
            optionalConstraints: nil
        )
        let audioSource = peerConnectionFactory.audioSource(with: audioConstraints)
        let audioTrack = peerConnectionFactory.audioTrack(with: audioSource, trackId: "audio0")
        localAudioTrack = audioTrack

        peerConnection?.add(audioTrack, streamIds: ["stream0"])
    }

    // MARK: - Offer / Answer

    func createOffer() async throws -> RTCSessionDescription {
        guard let pc = peerConnection else {
            throw WebRTCError.notInitialized
        }

        let constraints = RTCMediaConstraints(
            mandatoryConstraints: [
                "OfferToReceiveAudio": "true",
                "OfferToReceiveVideo": "false"
            ],
            optionalConstraints: nil
        )

        return try await withCheckedThrowingContinuation { continuation in
            pc.offer(for: constraints) { sdp, error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }
                guard let sdp else {
                    continuation.resume(throwing: WebRTCError.noSDP)
                    return
                }
                pc.setLocalDescription(sdp) { error in
                    if let error {
                        continuation.resume(throwing: error)
                    } else {
                        continuation.resume(returning: sdp)
                    }
                }
            }
        }
    }

    func createAnswer() async throws -> RTCSessionDescription {
        guard let pc = peerConnection else {
            throw WebRTCError.notInitialized
        }

        let constraints = RTCMediaConstraints(
            mandatoryConstraints: [
                "OfferToReceiveAudio": "true",
                "OfferToReceiveVideo": "false"
            ],
            optionalConstraints: nil
        )

        return try await withCheckedThrowingContinuation { continuation in
            pc.answer(for: constraints) { sdp, error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }
                guard let sdp else {
                    continuation.resume(throwing: WebRTCError.noSDP)
                    return
                }
                pc.setLocalDescription(sdp) { error in
                    if let error {
                        continuation.resume(throwing: error)
                    } else {
                        continuation.resume(returning: sdp)
                    }
                }
            }
        }
    }

    func setRemoteSDP(_ sdp: RTCSessionDescription) async throws {
        guard let pc = peerConnection else {
            throw WebRTCError.notInitialized
        }

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            pc.setRemoteDescription(sdp) { error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume()
                }
            }
        }
    }

    func addICECandidate(_ candidate: RTCIceCandidate) async throws {
        guard let pc = peerConnection else {
            throw WebRTCError.notInitialized
        }

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            pc.add(candidate) { error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume()
                }
            }
        }
    }

    // MARK: - Controls

    var isMuted: Bool {
        get { !(localAudioTrack?.isEnabled ?? false) }
        set { localAudioTrack?.isEnabled = !newValue }
    }

    func close() {
        peerConnection?.close()
        peerConnection = nil
        localAudioTrack = nil
    }
}

// MARK: - RTCPeerConnectionDelegate

extension WebRTCClient: RTCPeerConnectionDelegate {
    func peerConnection(_ peerConnection: RTCPeerConnection, didChange state: RTCSignalingState) {}

    func peerConnection(_ peerConnection: RTCPeerConnection, didAdd stream: RTCMediaStream) {}

    func peerConnection(_ peerConnection: RTCPeerConnection, didRemove stream: RTCMediaStream) {}

    func peerConnectionShouldNegotiate(_ peerConnection: RTCPeerConnection) {}

    func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCIceConnectionState) {
        onConnectionStateChange?(newState)
    }

    func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCIceGatheringState) {}

    func peerConnection(_ peerConnection: RTCPeerConnection, didGenerate candidate: RTCIceCandidate) {
        onICECandidate?(candidate)
    }

    func peerConnection(_ peerConnection: RTCPeerConnection, didRemove candidates: [RTCIceCandidate]) {}

    func peerConnection(_ peerConnection: RTCPeerConnection, didOpen dataChannel: RTCDataChannel) {}
}

enum WebRTCError: Error {
    case notInitialized
    case noSDP
}
