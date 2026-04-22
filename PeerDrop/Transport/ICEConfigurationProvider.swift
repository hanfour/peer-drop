import Foundation
@preconcurrency import WebRTC

/// Temporary TURN credentials from the signaling server.
struct ICECredentials: Codable {
    let username: String
    let credential: String
    let urls: [String]
    let ttl: Int
}

/// Provides ICE server configuration for WebRTC connections.
enum ICEConfigurationProvider {
    static let stunServers: [RTCIceServer] = [
        RTCIceServer(urlStrings: ["stun:stun.cloudflare.com:3478"]),
        RTCIceServer(urlStrings: ["stun:stun.l.google.com:19302"])
    ]

    static func iceServers(from credentials: ICECredentials) -> [RTCIceServer] {
        var servers = stunServers
        let turnServer = RTCIceServer(
            urlStrings: credentials.urls,
            username: credentials.username,
            credential: credentials.credential
        )
        servers.append(turnServer)
        return servers
    }

    static func defaultConfiguration() -> RTCConfiguration {
        let config = RTCConfiguration()
        config.iceServers = stunServers
        config.sdpSemantics = .unifiedPlan
        config.iceTransportPolicy = .all
        config.bundlePolicy = .maxBundle
        config.rtcpMuxPolicy = .require
        config.continualGatheringPolicy = .gatherContinually
        config.iceCandidatePoolSize = 2
        return config
    }

    static func configuration(with credentials: ICECredentials) -> RTCConfiguration {
        let config = defaultConfiguration()
        config.iceServers = iceServers(from: credentials)
        return config
    }
}
