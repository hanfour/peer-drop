import Foundation
import PeerDropSecurity

// MARK: - RelayAuthDeviceStore conformance

/// Makes `DeviceRecordStore` satisfy `RelayAuthenticator`'s minimal store
/// protocol without pulling Core/UI types into `PeerDropSecurity`.
extension DeviceRecordStore: RelayAuthDeviceStore {

    public func deviceRecord(for peerID: String) -> (id: String, certificateFingerprint: String?)? {
        guard let record = records.first(where: { $0.id == peerID }) else { return nil }
        return (id: record.id, certificateFingerprint: record.certificateFingerprint)
    }

    public func setFingerprint(_ fingerprint: String, for peerID: String) {
        guard let index = records.firstIndex(where: { $0.id == peerID }) else { return }
        records[index].certificateFingerprint = fingerprint
    }

    public func addNewDevice(_ device: RelayAuthNewDevice) {
        var record = DeviceRecord(
            id: device.id,
            displayName: device.displayName,
            sourceType: device.sourceType,
            host: device.host,
            port: device.port,
            lastConnected: device.lastConnected,
            connectionCount: device.connectionCount,
            connectionHistory: device.connectionHistory
        )
        record.certificateFingerprint = device.certificateFingerprint
        records.append(record)
    }
}
