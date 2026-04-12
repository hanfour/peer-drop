import Foundation
@preconcurrency import WebRTC
import os

private let logger = Logger(subsystem: "com.hanfour.peerdrop", category: "DataChannelClient")

/// Thread-safe one-time RTCInitializeSSL wrapper.
enum RTCSSLInitializer {
    private static let once: Void = {
        RTCInitializeSSL()
    }()

    static func initialize() {
        _ = once
    }
}

/// Manages a WebRTC PeerConnection for Data Channel communication (non-audio).
final class DataChannelClient: NSObject {
    private let peerConnectionFactory: RTCPeerConnectionFactory
    private var peerConnection: RTCPeerConnection?
    private var dataChannel: RTCDataChannel?

    // MARK: - Callbacks

    var onLocalSDP: ((RTCSessionDescription) -> Void)?
    var onICECandidate: ((RTCIceCandidate) -> Void)?
    var onConnectionStateChange: ((RTCIceConnectionState) -> Void)?
    var onDataChannelOpen: (() -> Void)?
    var onDataChannelClose: (() -> Void)?
    var onDataReceived: ((Data) -> Void)?
    var onRemoteDataChannel: ((RTCDataChannel) -> Void)?

    override init() {
        RTCSSLInitializer.initialize()
        // Data-only — no video encoder/decoder needed
        peerConnectionFactory = RTCPeerConnectionFactory()
        super.init()
    }

    deinit {
        close()
    }

    // MARK: - Setup

    func setup(iceServers: [RTCIceServer]) {
        let config = RTCConfiguration()
        config.iceServers = iceServers
        config.sdpSemantics = .unifiedPlan
        config.iceTransportPolicy = .all
        config.bundlePolicy = .maxBundle
        config.rtcpMuxPolicy = .require
        config.continualGatheringPolicy = .gatherContinually

        let constraints = RTCMediaConstraints(
            mandatoryConstraints: nil,
            optionalConstraints: nil
        )

        peerConnection = peerConnectionFactory.peerConnection(
            with: config,
            constraints: constraints,
            delegate: self
        )
        logger.info("DataChannelClient setup complete")
    }

    func setup(with configuration: RTCConfiguration) {
        let constraints = RTCMediaConstraints(
            mandatoryConstraints: nil,
            optionalConstraints: nil
        )

        peerConnection = peerConnectionFactory.peerConnection(
            with: configuration,
            constraints: constraints,
            delegate: self
        )
        logger.info("DataChannelClient setup complete")
    }

    // MARK: - Data Channel

    func createDataChannel() -> RTCDataChannel? {
        guard let pc = peerConnection else {
            logger.error("Cannot create data channel: no peer connection")
            return nil
        }

        let config = RTCDataChannelConfiguration()
        config.isOrdered = true
        config.channelId = 0

        guard let channel = pc.dataChannel(forLabel: "peerdrop", configuration: config) else {
            logger.error("Failed to create data channel")
            return nil
        }

        channel.delegate = self
        dataChannel = channel
        logger.info("Data channel created: \(channel.label)")
        return channel
    }

    // MARK: - SDP Negotiation

    func createOffer() async throws -> RTCSessionDescription {
        guard let pc = peerConnection else {
            throw DataChannelError.notInitialized
        }

        let constraints = RTCMediaConstraints(
            mandatoryConstraints: [
                "OfferToReceiveAudio": "false",
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
                    continuation.resume(throwing: DataChannelError.noSDP)
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
            throw DataChannelError.notInitialized
        }

        let constraints = RTCMediaConstraints(
            mandatoryConstraints: [
                "OfferToReceiveAudio": "false",
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
                    continuation.resume(throwing: DataChannelError.noSDP)
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
            throw DataChannelError.notInitialized
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
            throw DataChannelError.notInitialized
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

    // MARK: - Send Data

    func send(_ data: Data) -> Bool {
        guard let channel = dataChannel, channel.readyState == .open else {
            logger.warning("Cannot send: data channel not open")
            return false
        }
        let buffer = RTCDataBuffer(data: data, isBinary: true)
        return channel.sendData(buffer)
    }

    // MARK: - DTLS Fingerprint

    var localDTLSFingerprint: String? {
        peerConnection?.localDescription?.sdp
            .components(separatedBy: "\n")
            .first { $0.hasPrefix("a=fingerprint:") }?
            .replacingOccurrences(of: "a=fingerprint:", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var remoteDTLSFingerprint: String? {
        peerConnection?.remoteDescription?.sdp
            .components(separatedBy: "\n")
            .first { $0.hasPrefix("a=fingerprint:") }?
            .replacingOccurrences(of: "a=fingerprint:", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Cleanup

    func close() {
        dataChannel?.close()
        dataChannel = nil
        peerConnection?.close()
        peerConnection = nil
        // Break retain cycles by clearing all callbacks
        onLocalSDP = nil
        onICECandidate = nil
        onConnectionStateChange = nil
        onDataChannelOpen = nil
        onDataChannelClose = nil
        onDataReceived = nil
        onRemoteDataChannel = nil
    }
}

// MARK: - RTCPeerConnectionDelegate

extension DataChannelClient: RTCPeerConnectionDelegate {
    func peerConnection(_ peerConnection: RTCPeerConnection, didChange state: RTCSignalingState) {
        logger.debug("Signaling state: \(String(describing: state.rawValue))")
    }

    func peerConnection(_ peerConnection: RTCPeerConnection, didAdd stream: RTCMediaStream) {}

    func peerConnection(_ peerConnection: RTCPeerConnection, didRemove stream: RTCMediaStream) {}

    func peerConnectionShouldNegotiate(_ peerConnection: RTCPeerConnection) {}

    func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCIceConnectionState) {
        logger.info("ICE connection state: \(String(describing: newState.rawValue))")
        onConnectionStateChange?(newState)
    }

    func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCIceGatheringState) {
        logger.debug("ICE gathering state: \(String(describing: newState.rawValue))")
    }

    func peerConnection(_ peerConnection: RTCPeerConnection, didGenerate candidate: RTCIceCandidate) {
        logger.debug("Generated ICE candidate: \(candidate.sdpMid ?? "nil")")
        onICECandidate?(candidate)
    }

    func peerConnection(_ peerConnection: RTCPeerConnection, didRemove candidates: [RTCIceCandidate]) {}

    func peerConnection(_ peerConnection: RTCPeerConnection, didOpen dataChannel: RTCDataChannel) {
        logger.info("Remote data channel opened: \(dataChannel.label)")
        dataChannel.delegate = self
        self.dataChannel = dataChannel
        onRemoteDataChannel?(dataChannel)
        // If the channel is already open when we set the delegate, the
        // dataChannelDidChangeState callback won't fire for the .open
        // transition. Trigger it manually so the joiner side doesn't hang.
        if dataChannel.readyState == .open {
            onDataChannelOpen?()
        }
    }
}

// MARK: - RTCDataChannelDelegate

extension DataChannelClient: RTCDataChannelDelegate {
    func dataChannelDidChangeState(_ dataChannel: RTCDataChannel) {
        logger.info("Data channel state: \(String(describing: dataChannel.readyState.rawValue))")
        switch dataChannel.readyState {
        case .open:
            onDataChannelOpen?()
        case .closed:
            onDataChannelClose?()
        default:
            break
        }
    }

    func dataChannel(_ dataChannel: RTCDataChannel, didReceiveMessageWith buffer: RTCDataBuffer) {
        onDataReceived?(buffer.data)
    }
}

// MARK: - Errors

enum DataChannelError: LocalizedError {
    case notInitialized
    case noSDP
    case dataChannelClosed
    case sendFailed
    case timeout

    var errorDescription: String? {
        switch self {
        case .notInitialized: return "DataChannel client not initialized"
        case .noSDP: return "Failed to generate SDP"
        case .dataChannelClosed: return "Data channel is closed"
        case .sendFailed: return "Failed to send data"
        case .timeout: return "DataChannel operation timed out"
        }
    }
}
