import Foundation

/// Minimal interface required by `RelayAuthenticator` for certificate fingerprint
/// storage. The concrete implementation (`DeviceRecordStore` in the app target)
/// conforms via an extension declared in `PeerDrop/Core/`.
///
/// Only the fields and methods accessed by `RelayAuthenticator` are declared
/// here — keeping the security module free from Core/UI dependencies.

/// A device record that tracks certificate fingerprints for relay authentication.
public protocol RelayAuthDevice {
    var id: String { get }
    var certificateFingerprint: String? { get set }
}

/// Minimal device record construction info needed by `RelayAuthenticator`.
public struct RelayAuthNewDevice {
    public let id: String
    public let displayName: String
    public let sourceType: String
    public let host: String?
    public let port: UInt16?
    public let lastConnected: Date
    public let connectionCount: Int
    public let connectionHistory: [Date]
    public var certificateFingerprint: String?

    public init(id: String, displayName: String, sourceType: String, host: String?, port: UInt16?,
                lastConnected: Date, connectionCount: Int, connectionHistory: [Date]) {
        self.id = id
        self.displayName = displayName
        self.sourceType = sourceType
        self.host = host
        self.port = port
        self.lastConnected = lastConnected
        self.connectionCount = connectionCount
        self.connectionHistory = connectionHistory
    }
}

/// Minimal store interface used by `RelayAuthenticator`.
@MainActor
public protocol RelayAuthDeviceStore: AnyObject {
    func deviceRecord(for peerID: String) -> (id: String, certificateFingerprint: String?)?
    func setFingerprint(_ fingerprint: String, for peerID: String)
    func addNewDevice(_ device: RelayAuthNewDevice)
    func save()
}
