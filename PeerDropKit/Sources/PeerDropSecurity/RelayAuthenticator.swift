import Foundation
import CryptoKit
import os

private let logger = Logger(subsystem: "com.hanfour.peerdrop", category: "RelayAuthenticator")

/// Handles authentication for relay connections.
/// - Known devices: auto-authenticated via stored certificate fingerprint.
/// - New devices: 4-digit PIN derived from DTLS fingerprints.
public enum RelayAuthenticator {

    /// Derive a 4-digit PIN from the local and remote DTLS fingerprints.
    /// The PIN is deterministic — both sides compute the same value.
    public static func derivePIN(localFingerprint: String, remoteFingerprint: String) -> String {
        let sorted = [localFingerprint, remoteFingerprint].sorted()
        let combined = sorted.joined(separator: ":")
        let hash = SHA256.hash(data: Data(combined.utf8))
        let bytes = Array(hash.prefix(4))
        let value = bytes.withUnsafeBufferPointer { ptr -> UInt32 in
            ptr.baseAddress!.withMemoryRebound(to: UInt32.self, capacity: 1) { $0.pointee }
        }
        return String(format: "%04d", value % 10000)
    }

    /// Check if a peer is already known (has a stored certificate fingerprint).
    @MainActor
    public static func isKnownDevice(peerID: String, remoteFingerprint: String, store: any RelayAuthDeviceStore) -> Bool {
        guard let record = store.deviceRecord(for: peerID),
              let storedFingerprint = record.certificateFingerprint else {
            return false
        }
        return storedFingerprint == remoteFingerprint
    }

    /// Store the certificate fingerprint for a peer after successful authentication.
    /// Creates the device record if it doesn't already exist (e.g. relay peers).
    @MainActor
    public static func storeFingerprint(_ fingerprint: String, for peerID: String, store: any RelayAuthDeviceStore) {
        if store.deviceRecord(for: peerID) != nil {
            store.setFingerprint(fingerprint, for: peerID)
        } else {
            var device = RelayAuthNewDevice(
                id: peerID,
                displayName: peerID,
                sourceType: "relay",
                host: nil,
                port: nil,
                lastConnected: Date(),
                connectionCount: 1,
                connectionHistory: [Date()]
            )
            device.certificateFingerprint = fingerprint
            store.addNewDevice(device)
        }
        store.save()
        logger.info("Stored certificate fingerprint for peer \(peerID.prefix(8))")
    }
}
