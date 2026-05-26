import Foundation
@preconcurrency import WebRTC

/// Temporary TURN credentials from the signaling server.
public struct ICECredentials: Codable {
    public let username: String
    public let credential: String
    public let urls: [String]
    public let ttl: Int

    public init(username: String, credential: String, urls: [String], ttl: Int) {
        self.username = username
        self.credential = credential
        self.urls = urls
        self.ttl = ttl
    }
}

/// Provides ICE server configuration for WebRTC connections.
public enum ICEConfigurationProvider {
    public static let stunServers: [RTCIceServer] = [
        RTCIceServer(urlStrings: ["stun:stun.cloudflare.com:3478"]),
        RTCIceServer(urlStrings: ["stun:stun.l.google.com:19302"])
    ]

    public static func iceServers(from credentials: ICECredentials) -> [RTCIceServer] {
        var servers = stunServers
        let turnServer = RTCIceServer(
            urlStrings: credentials.urls,
            username: credentials.username,
            credential: credentials.credential
        )
        servers.append(turnServer)
        return servers
    }

    public static func defaultConfiguration() -> RTCConfiguration {
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

    public static func configuration(with credentials: ICECredentials) -> RTCConfiguration {
        let config = defaultConfiguration()
        config.iceServers = iceServers(from: credentials)
        return config
    }
}
