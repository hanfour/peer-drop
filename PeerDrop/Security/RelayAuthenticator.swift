import Foundation
import CryptoKit
import os

private let logger = Logger(subsystem: "com.hanfour.peerdrop", category: "RelayAuthenticator")

/// Handles authentication for relay connections.
/// - Known devices: auto-authenticated via stored certificate fingerprint.
/// - New devices: 4-digit PIN derived from DTLS fingerprints.
enum RelayAuthenticator {

    /// Derive a 4-digit PIN from the local and remote DTLS fingerprints.
    /// The PIN is deterministic — both sides compute the same value.
    static func derivePIN(localFingerprint: String, remoteFingerprint: String) -> String {
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
    static func isKnownDevice(peerID: String, remoteFingerprint: String, store: DeviceRecordStore) -> Bool {
        guard let record = store.records.first(where: { $0.id == peerID }),
              let storedFingerprint = record.certificateFingerprint else {
            return false
        }
        return storedFingerprint == remoteFingerprint
    }

    /// Store the certificate fingerprint for a peer after successful authentication.
    /// Creates the device record if it doesn't already exist (e.g. relay peers).
    @MainActor
    static func storeFingerprint(_ fingerprint: String, for peerID: String, store: DeviceRecordStore) {
        if let index = store.records.firstIndex(where: { $0.id == peerID }) {
            store.records[index].certificateFingerprint = fingerprint
        } else {
            var record = DeviceRecord(
                id: peerID,
                displayName: peerID,
                sourceType: "relay",
                host: nil,
                port: nil,
                lastConnected: Date(),
                connectionCount: 1,
                connectionHistory: [Date()]
            )
            record.certificateFingerprint = fingerprint
            store.records.append(record)
        }
        store.save()
        logger.info("Stored certificate fingerprint for peer \(peerID.prefix(8))")
    }
}
