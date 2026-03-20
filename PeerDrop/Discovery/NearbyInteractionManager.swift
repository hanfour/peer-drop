import Foundation
import NearbyInteraction
import Combine
import os

private let logger = Logger(subsystem: "com.hanfour.peerdrop", category: "NearbyInteraction")

/// Manages Nearby Interaction sessions for distance/direction between connected peers.
/// This is NOT a DiscoveryBackend — it enhances already-connected peers with proximity data.
final class NearbyInteractionManager: NSObject, ObservableObject {

    /// Published proximity data keyed by peer ID.
    @Published private(set) var peerProximity: [String: ProximityInfo] = [:]

    struct ProximityInfo {
        var distance: Float?      // metres
        var direction: SIMD3<Float>?
    }

    // MARK: - Properties

    private var sessions: [String: NISession] = [:]
    private var tokenSendCallbacks: [String: (Data) -> Void] = [:]

    /// Whether Nearby Interaction is supported on this device.
    static var isSupported: Bool {
        if #available(iOS 16.0, *) {
            return NISession.deviceCapabilities.supportsPreciseDistanceMeasurement
        } else {
            return NISession.isSupported
        }
    }

    // MARK: - Session Lifecycle

    /// Start an NI session for a connected peer.
    /// - Parameters:
    ///   - peerID: The peer's identifier.
    ///   - sendToken: Closure to send the local discovery token to the peer via existing NWConnection.
    func startSession(for peerID: String, sendToken: @escaping (Data) -> Void) {
        guard Self.isSupported else {
            logger.info("Nearby Interaction not supported on this device")
            return
        }

        // Don't create duplicate sessions
        guard sessions[peerID] == nil else {
            logger.info("NI session already exists for \(peerID)")
            return
        }

        let session = NISession()
        session.delegate = self
        sessions[peerID] = session

        // Get the local discovery token and send it to the peer
        guard let token = session.discoveryToken else {
            logger.warning("Failed to get NI discovery token")
            sessions.removeValue(forKey: peerID)
            return
        }

        do {
            let tokenData = try NSKeyedArchiver.archivedData(withRootObject: token, requiringSecureCoding: true)
            tokenSendCallbacks[peerID] = sendToken
            sendToken(tokenData)
            logger.info("Sent NI token offer to \(peerID)")
        } catch {
            logger.error("Failed to archive NI token: \(error.localizedDescription)")
            sessions.removeValue(forKey: peerID)
        }
    }

    /// Handle an incoming NI token offer from a peer.
    func handleTokenOffer(_ tokenData: Data, from peerID: String, respond: @escaping (Data) -> Void) {
        guard Self.isSupported else { return }

        guard let peerToken = try? NSKeyedUnarchiver.unarchivedObject(ofClass: NIDiscoveryToken.self, from: tokenData) else {
            logger.warning("Failed to decode NI token from \(peerID)")
            return
        }

        // Create a session if we don't have one
        if sessions[peerID] == nil {
            let session = NISession()
            session.delegate = self
            sessions[peerID] = session
        }

        guard let session = sessions[peerID] else { return }

        // Send our token back
        if let localToken = session.discoveryToken {
            do {
                let localTokenData = try NSKeyedArchiver.archivedData(withRootObject: localToken, requiringSecureCoding: true)
                respond(localTokenData)
                logger.info("Sent NI token response to \(peerID)")
            } catch {
                logger.error("Failed to archive local NI token: \(error.localizedDescription)")
            }
        }

        // Start the session with the peer's token
        let config = NINearbyPeerConfiguration(peerToken: peerToken)
        session.run(config)
        logger.info("NI session started with \(peerID)")
    }

    /// Handle an incoming NI token response from a peer.
    func handleTokenResponse(_ tokenData: Data, from peerID: String) {
        guard let peerToken = try? NSKeyedUnarchiver.unarchivedObject(ofClass: NIDiscoveryToken.self, from: tokenData) else {
            logger.warning("Failed to decode NI token response from \(peerID)")
            return
        }

        guard let session = sessions[peerID] else {
            logger.warning("No NI session for \(peerID)")
            return
        }

        let config = NINearbyPeerConfiguration(peerToken: peerToken)
        session.run(config)
        logger.info("NI session running with \(peerID)")
    }

    /// Stop the NI session for a specific peer.
    func stopSession(for peerID: String) {
        sessions[peerID]?.invalidate()
        sessions.removeValue(forKey: peerID)
        tokenSendCallbacks.removeValue(forKey: peerID)
        peerProximity.removeValue(forKey: peerID)
        logger.info("Stopped NI session for \(peerID)")
    }

    /// Stop all NI sessions.
    func stopAllSessions() {
        for (_, session) in sessions {
            session.invalidate()
        }
        sessions.removeAll()
        tokenSendCallbacks.removeAll()
        peerProximity.removeAll()
        logger.info("Stopped all NI sessions")
    }

    // MARK: - Helpers

    /// Find the peer ID associated with a given NI session.
    private func peerID(for session: NISession) -> String? {
        sessions.first(where: { $0.value === session })?.key
    }
}

// MARK: - NISessionDelegate

extension NearbyInteractionManager: NISessionDelegate {
    func session(_ session: NISession, didUpdate nearbyObjects: [NINearbyObject]) {
        guard let peerID = peerID(for: session),
              let object = nearbyObjects.first else { return }

        let info = ProximityInfo(
            distance: object.distance,
            direction: object.direction
        )
        DispatchQueue.main.async { [weak self] in
            self?.peerProximity[peerID] = info
        }
    }

    func session(_ session: NISession, didRemove nearbyObjects: [NINearbyObject], reason: NINearbyObject.RemovalReason) {
        guard let peerID = peerID(for: session) else { return }

        switch reason {
        case .peerEnded:
            logger.info("NI peer ended: \(peerID)")
            stopSession(for: peerID)
        case .timeout:
            logger.info("NI session timed out: \(peerID)")
            stopSession(for: peerID)
        @unknown default:
            break
        }
    }

    func sessionWasSuspended(_ session: NISession) {
        guard let peerID = peerID(for: session) else { return }
        logger.info("NI session suspended for \(peerID)")
    }

    func sessionSuspensionEnded(_ session: NISession) {
        guard let peerID = peerID(for: session) else { return }
        logger.info("NI session suspension ended for \(peerID)")
        // Session will automatically resume
    }

    func session(_ session: NISession, didInvalidateWith error: Error) {
        guard let peerID = peerID(for: session) else { return }
        logger.error("NI session invalidated for \(peerID): \(error.localizedDescription)")
        sessions.removeValue(forKey: peerID)
        tokenSendCallbacks.removeValue(forKey: peerID)
        DispatchQueue.main.async { [weak self] in
            self?.peerProximity.removeValue(forKey: peerID)
        }
    }
}
