import Foundation
import CoreBluetooth
import Combine
import os

private let logger = Logger(subsystem: "com.hanfour.peerdrop", category: "BLEDiscovery")

/// BLE-based discovery backend for finding nearby PeerDrop devices without WiFi.
final class BLEDiscovery: NSObject, DiscoveryBackend {

    let source: DiscoverySource = .bluetooth

    // MARK: - Constants

    /// Custom PeerDrop BLE service UUID.
    static let serviceUUID = CBUUID(string: "A1B2C3D4-E5F6-7890-ABCD-EF1234567890")
    /// Characteristic containing the full display name + peer ID.
    static let nameCharacteristicUUID = CBUUID(string: "A1B2C3D4-E5F6-7890-ABCD-EF1234567891")

    /// How long before a BLE peer is considered stale and removed.
    private static let peerTimeout: TimeInterval = 30
    /// Cleanup interval for stale peers.
    private static let cleanupInterval: TimeInterval = 10

    // MARK: - Properties

    private let localPeerID: String
    private let localDisplayName: String
    private let localIDHash: Data

    private var centralManager: CBCentralManager?
    private var peripheralManager: CBPeripheralManager?

    private let peersSubject = CurrentValueSubject<[DiscoveredPeer], Never>([])
    var peersPublisher: AnyPublisher<[DiscoveredPeer], Never> {
        peersSubject.eraseToAnyPublisher()
    }

    /// Tracks discovered BLE peripherals with last-seen timestamps.
    private var discoveredPeripherals: [UUID: BLEPeerInfo] = [:]
    private var cleanupTimer: Timer?
    /// Debounce work item for batching publishPeers calls.
    private var publishWorkItem: DispatchWorkItem?

    /// BLE signaling for relay connections.
    private(set) var signaling = BLESignaling()

    private let queue = DispatchQueue(label: "com.peerdrop.ble", qos: .userInitiated)

    // MARK: - Types

    private struct BLEPeerInfo {
        let peripheralID: UUID
        var displayName: String
        var rssi: Int
        var lastSeen: Date
    }

    // MARK: - Init

    init(localPeerID: String, localDisplayName: String) {
        self.localPeerID = localPeerID
        self.localDisplayName = localDisplayName
        // Create a hash of the local peer ID for self-filtering
        self.localIDHash = Data(localPeerID.utf8).prefix(8)
        super.init()
    }

    // MARK: - DiscoveryBackend

    func startDiscovery() {
        logger.info("Starting BLE discovery")
        centralManager = CBCentralManager(delegate: self, queue: queue)
        peripheralManager = CBPeripheralManager(delegate: self, queue: queue)
        signaling.setManagers(peripheral: peripheralManager, central: centralManager)
        startCleanupTimer()
    }

    func stopDiscovery() {
        logger.info("Stopping BLE discovery")
        centralManager?.stopScan()
        centralManager = nil

        if peripheralManager?.isAdvertising == true {
            peripheralManager?.stopAdvertising()
        }
        peripheralManager?.removeAllServices()
        peripheralManager = nil

        cleanupTimer?.invalidate()
        cleanupTimer = nil
        queue.async { [weak self] in
            self?.discoveredPeripherals.removeAll()
            self?.peersSubject.send([])
        }
    }

    // MARK: - Advertising

    private func startAdvertising() {
        guard let peripheralManager, peripheralManager.state == .poweredOn else { return }

        // Create GATT service with name characteristic
        let nameCharacteristic = CBMutableCharacteristic(
            type: Self.nameCharacteristicUUID,
            properties: [.read],
            value: makeNameCharacteristicValue(),
            permissions: [.readable]
        )

        let service = CBMutableService(type: Self.serviceUUID, primary: true)
        var characteristics: [CBMutableCharacteristic] = [nameCharacteristic]
        // Add signaling characteristics for relay support
        if FeatureSettings.isRelayEnabled {
            characteristics.append(contentsOf: signaling.createSignalingCharacteristics())
        }
        service.characteristics = characteristics
        peripheralManager.add(service)

        // Advertise with service UUID and truncated local name
        let advertisementData: [String: Any] = [
            CBAdvertisementDataServiceUUIDsKey: [Self.serviceUUID],
            CBAdvertisementDataLocalNameKey: String(localDisplayName.prefix(8))
        ]
        peripheralManager.startAdvertising(advertisementData)
        logger.info("BLE advertising started")
    }

    private func makeNameCharacteristicValue() -> Data {
        // Format: [8 bytes ID hash][displayName UTF-8]
        var data = localIDHash
        data.append(Data(localDisplayName.utf8))
        return data
    }

    // MARK: - Scanning

    private func startScanning() {
        guard let centralManager, centralManager.state == .poweredOn else { return }

        centralManager.scanForPeripherals(
            withServices: [Self.serviceUUID],
            options: [CBCentralManagerScanOptionAllowDuplicatesKey: true]
        )
        logger.info("BLE scanning started")
    }

    // MARK: - Cleanup

    private func startCleanupTimer() {
        DispatchQueue.main.async { [weak self] in
            self?.cleanupTimer?.invalidate()
            self?.cleanupTimer = Timer.scheduledTimer(
                withTimeInterval: Self.cleanupInterval,
                repeats: true
            ) { [weak self] _ in
                self?.queue.async {
                    self?.cleanupStalePeers()
                }
            }
        }
    }

    private func cleanupStalePeers() {
        // Must be called on `queue` to avoid race with BLE delegate callbacks
        let cutoff = Date().addingTimeInterval(-Self.peerTimeout)
        var changed = false
        for (id, info) in discoveredPeripherals {
            if info.lastSeen < cutoff {
                discoveredPeripherals.removeValue(forKey: id)
                changed = true
                logger.info("Removed stale BLE peer: \(info.displayName)")
            }
        }
        if changed {
            publishPeers()
        }
    }

    // MARK: - Publishing

    /// Debounced version of publishPeers to avoid excessive UI updates from AllowDuplicates scanning.
    private func debouncedPublishPeers() {
        publishWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            self?.publishPeers()
        }
        publishWorkItem = workItem
        queue.asyncAfter(deadline: .now() + 0.3, execute: workItem)
    }

    private func publishPeers() {
        let peers = discoveredPeripherals.values.map { info in
            DiscoveredPeer(
                id: "ble-\(info.peripheralID.uuidString)",
                displayName: info.displayName,
                endpoint: .bleOnly(peripheralIdentifier: info.peripheralID.uuidString),
                source: .bluetooth,
                lastSeen: info.lastSeen,
                rssi: info.rssi
            )
        }
        peersSubject.send(peers)
    }

    // MARK: - Self-Filtering

    private func isSelf(_ manufacturerData: Data?) -> Bool {
        guard let data = manufacturerData, data.count >= 8 else { return false }
        return data.prefix(8) == localIDHash
    }
}

// MARK: - CBCentralManagerDelegate

extension BLEDiscovery: CBCentralManagerDelegate {
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        logger.info("Central manager state: \(String(describing: central.state.rawValue))")
        switch central.state {
        case .poweredOn:
            startScanning()
        case .poweredOff:
            discoveredPeripherals.removeAll()
            peersSubject.send([])
        default:
            break
        }
    }

    func centralManager(
        _ central: CBCentralManager,
        didDiscover peripheral: CBPeripheral,
        advertisementData: [String: Any],
        rssi RSSI: NSNumber
    ) {
        // Extract display name from advertisement
        let advertisedName = advertisementData[CBAdvertisementDataLocalNameKey] as? String
            ?? peripheral.name
            ?? "Unknown Device"

        // Self-filtering: check manufacturer data for our ID hash
        if let manufacturerData = advertisementData[CBAdvertisementDataManufacturerDataKey] as? Data,
           isSelf(manufacturerData) {
            return
        }
        // Fallback: also filter by truncated name match (best-effort)
        if advertisedName == String(localDisplayName.prefix(8)) && advertisedName == localDisplayName {
            return
        }

        let rssiValue = RSSI.intValue
        // Ignore very weak signals (likely far away or noise)
        guard rssiValue > -90 else { return }

        let peripheralID = peripheral.identifier
        let existing = discoveredPeripherals[peripheralID]

        discoveredPeripherals[peripheralID] = BLEPeerInfo(
            peripheralID: peripheralID,
            displayName: existing?.displayName ?? advertisedName,
            rssi: rssiValue,
            lastSeen: Date()
        )

        debouncedPublishPeers()
    }
}

// MARK: - CBPeripheralManagerDelegate

extension BLEDiscovery: CBPeripheralManagerDelegate {
    func peripheralManagerDidUpdateState(_ peripheral: CBPeripheralManager) {
        logger.info("Peripheral manager state: \(String(describing: peripheral.state.rawValue))")
        switch peripheral.state {
        case .poweredOn:
            startAdvertising()
        default:
            break
        }
    }

    func peripheralManager(_ peripheral: CBPeripheralManager, didAdd service: CBService, error: Error?) {
        if let error {
            logger.error("Failed to add GATT service: \(error.localizedDescription)")
        } else {
            logger.info("GATT service added successfully")
        }
    }

    func peripheralManager(_ peripheral: CBPeripheralManager, didReceiveWrite requests: [CBATTRequest]) {
        for request in requests {
            let uuid = request.characteristic.uuid
            // Handle signaling characteristic writes
            let signalingUUIDs: [CBUUID] = [
                BLESignaling.sdpOfferUUID,
                BLESignaling.sdpAnswerUUID,
                BLESignaling.iceCandidateUUID,
                BLESignaling.controlUUID
            ]
            if signalingUUIDs.contains(uuid), let value = request.value {
                signaling.handleWriteRequest(characteristicUUID: uuid, value: value)
                peripheral.respond(to: request, withResult: .success)
            } else {
                peripheral.respond(to: request, withResult: .requestNotSupported)
            }
        }
    }
}
