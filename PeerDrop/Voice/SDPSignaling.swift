import Foundation
import WebRTC

/// Codable wrappers for SDP and ICE candidate exchange over TCP.
struct SDPMessage: Codable {
    let type: String  // "offer" or "answer"
    let sdp: String

    init(from description: RTCSessionDescription) {
        switch description.type {
        case .offer: self.type = "offer"
        case .answer: self.type = "answer"
        case .prAnswer: self.type = "pranswer"
        case .rollback: self.type = "rollback"
        @unknown default: self.type = "offer"
        }
        self.sdp = description.sdp
    }

    func toRTCSessionDescription() -> RTCSessionDescription {
        let rtcType: RTCSdpType
        switch type {
        case "offer": rtcType = .offer
        case "answer": rtcType = .answer
        case "pranswer": rtcType = .prAnswer
        case "rollback": rtcType = .rollback
        default: rtcType = .offer
        }
        return RTCSessionDescription(type: rtcType, sdp: sdp)
    }
}

struct ICECandidateMessage: Codable {
    let sdpMid: String?
    let sdpMLineIndex: Int32
    let candidate: String

    init(from candidate: RTCIceCandidate) {
        self.sdpMid = candidate.sdpMid
        self.sdpMLineIndex = candidate.sdpMLineIndex
        self.candidate = candidate.sdp
    }

    func toRTCIceCandidate() -> RTCIceCandidate {
        RTCIceCandidate(
            sdp: candidate,
            sdpMLineIndex: sdpMLineIndex,
            sdpMid: sdpMid
        )
    }
}

/// Sends SDP/ICE messages as PeerMessages over the existing TCP connection.
@MainActor
struct SDPSignaling {
    private let connectionManager: ConnectionManager
    private let senderID: String

    init(connectionManager: ConnectionManager, senderID: String) {
        self.connectionManager = connectionManager
        self.senderID = senderID
    }

    func sendOffer(_ sdp: RTCSessionDescription) async throws {
        let sdpMessage = SDPMessage(from: sdp)
        let payload = try JSONEncoder().encode(sdpMessage)
        let message = PeerMessage(type: .sdpOffer, payload: payload, senderID: senderID)
        try await connectionManager.sendMessage(message)
    }

    func sendAnswer(_ sdp: RTCSessionDescription) async throws {
        let sdpMessage = SDPMessage(from: sdp)
        let payload = try JSONEncoder().encode(sdpMessage)
        let message = PeerMessage(type: .sdpAnswer, payload: payload, senderID: senderID)
        try await connectionManager.sendMessage(message)
    }

    func sendICECandidate(_ candidate: RTCIceCandidate) async throws {
        let iceMessage = ICECandidateMessage(from: candidate)
        let payload = try JSONEncoder().encode(iceMessage)
        let message = PeerMessage(type: .iceCandidate, payload: payload, senderID: senderID)
        try await connectionManager.sendMessage(message)
    }
}
