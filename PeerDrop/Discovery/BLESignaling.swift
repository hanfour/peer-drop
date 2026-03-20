import Foundation
import CoreBluetooth
import os

private let logger = Logger(subsystem: "com.hanfour.peerdrop", category: "BLESignaling")

/// BLE GATT-based signaling for SDP/ICE exchange between nearby devices.
final class BLESignaling: NSObject {

    // MARK: - GATT Characteristic UUIDs

    /// SDP Offer characteristic
    static let sdpOfferUUID = CBUUID(string: "A1B2C3D4-E5F6-7890-ABCD-EF1234567892")
    /// SDP Answer characteristic
    static let sdpAnswerUUID = CBUUID(string: "A1B2C3D4-E5F6-7890-ABCD-EF1234567893")
    /// ICE Candidate characteristic
    static let iceCandidateUUID = CBUUID(string: "A1B2C3D4-E5F6-7890-ABCD-EF1234567894")
    /// Signaling Control characteristic
    static let controlUUID = CBUUID(string: "A1B2C3D4-E5F6-7890-ABCD-EF1234567895")

    /// Maximum BLE payload per write (MTU-safe)
    static let maxChunkPayload = 480
    /// Flag bits: bit0=first, bit1=last
    private static let flagFirst: UInt8 = 0x01
    private static let flagLast: UInt8 = 0x02

    // MARK: - Properties

    private weak var peripheralManager: CBPeripheralManager?
    private weak var centralManager: CBCentralManager?
    private var connectedPeripheral: CBPeripheral?

    // GATT characteristics (peripheral side)
    private var sdpOfferCharacteristic: CBMutableCharacteristic?
    private var sdpAnswerCharacteristic: CBMutableCharacteristic?
    private var iceCandidateCharacteristic: CBMutableCharacteristic?
    private var controlCharacteristic: CBMutableCharacteristic?

    // Discovered characteristics (central side)
    private var remoteSdpOfferChar: CBCharacteristic?
    private var remoteSdpAnswerChar: CBCharacteristic?
    private var remoteICECandidateChar: CBCharacteristic?
    private var remoteControlChar: CBCharacteristic?

    // Reassembly buffers
    private var receiveBuffers: [CBUUID: Data] = [:]

    // MARK: - Callbacks

    var onRelayRequest: ((String) -> Void)?  // peer ID
    var onRelayAccept: (() -> Void)?
    var onRelayReject: (() -> Void)?
    var onSDPOffer: ((String) -> Void)?    // SDP string
    var onSDPAnswer: ((String) -> Void)?   // SDP string
    var onICECandidate: ((String) -> Void)? // JSON-encoded candidate

    // MARK: - Signaling Characteristics for GATT Service

    /// Returns the 4 signaling characteristics to add to the BLE service.
    func createSignalingCharacteristics() -> [CBMutableCharacteristic] {
        let sdpOffer = CBMutableCharacteristic(
            type: Self.sdpOfferUUID,
            properties: [.write, .notify],
            value: nil,
            permissions: [.writeable]
        )
        let sdpAnswer = CBMutableCharacteristic(
            type: Self.sdpAnswerUUID,
            properties: [.write, .notify],
            value: nil,
            permissions: [.writeable]
        )
        let iceCandidate = CBMutableCharacteristic(
            type: Self.iceCandidateUUID,
            properties: [.write, .notify],
            value: nil,
            permissions: [.writeable]
        )
        let control = CBMutableCharacteristic(
            type: Self.controlUUID,
            properties: [.write, .notify],
            value: nil,
            permissions: [.writeable]
        )

        sdpOfferCharacteristic = sdpOffer
        sdpAnswerCharacteristic = sdpAnswer
        iceCandidateCharacteristic = iceCandidate
        controlCharacteristic = control

        return [sdpOffer, sdpAnswer, iceCandidate, control]
    }

    func setManagers(peripheral: CBPeripheralManager?, central: CBCentralManager?) {
        self.peripheralManager = peripheral
        self.centralManager = central
    }

    // MARK: - Central Side (Offerer)

    func connectToPeripheral(_ peripheral: CBPeripheral) {
        connectedPeripheral = peripheral
        peripheral.delegate = self
        centralManager?.connect(peripheral, options: nil)
    }

    /// Send a relay request to the peripheral via Control characteristic.
    func sendRelayRequest(peerID: String) {
        guard let char = remoteControlChar, let peripheral = connectedPeripheral else {
            logger.warning("Cannot send relay request: no control characteristic")
            return
        }
        let message = "relay-request:\(peerID)"
        peripheral.writeValue(Data(message.utf8), for: char, type: .withResponse)
        logger.info("Sent relay request")
    }

    /// Send SDP offer via BLE (chunked).
    func sendSDPOffer(_ sdp: String) {
        guard let char = remoteSdpOfferChar, let peripheral = connectedPeripheral else {
            logger.warning("Cannot send SDP offer: no characteristic")
            return
        }
        sendChunked(data: Data(sdp.utf8), to: char, via: peripheral)
    }

    /// Send ICE candidate via BLE.
    func sendICECandidate(_ candidateJSON: String) {
        guard let char = remoteICECandidateChar, let peripheral = connectedPeripheral else {
            logger.warning("Cannot send ICE candidate: no characteristic")
            return
        }
        sendChunked(data: Data(candidateJSON.utf8), to: char, via: peripheral)
    }

    // MARK: - Peripheral Side (Answerer)

    /// Notify SDP answer to subscribed central.
    func notifySDPAnswer(_ sdp: String) {
        guard let char = sdpAnswerCharacteristic, let pm = peripheralManager else {
            logger.warning("Cannot notify SDP answer: no characteristic")
            return
        }
        notifyChunked(data: Data(sdp.utf8), on: char, via: pm)
    }

    /// Notify relay accept to subscribed central.
    func notifyRelayAccept() {
        guard let char = controlCharacteristic, let pm = peripheralManager else { return }
        pm.updateValue(Data("relay-accept".utf8), for: char, onSubscribedCentrals: nil)
    }

    /// Notify relay reject to subscribed central.
    func notifyRelayReject() {
        guard let char = controlCharacteristic, let pm = peripheralManager else { return }
        pm.updateValue(Data("relay-reject".utf8), for: char, onSubscribedCentrals: nil)
    }

    /// Notify ICE candidate to subscribed central.
    func notifyICECandidate(_ candidateJSON: String) {
        guard let char = iceCandidateCharacteristic, let pm = peripheralManager else { return }
        notifyChunked(data: Data(candidateJSON.utf8), on: char, via: pm)
    }

    // MARK: - Chunking

    /// Write chunked data to a characteristic (central → peripheral).
    private func sendChunked(data: Data, to characteristic: CBCharacteristic, via peripheral: CBPeripheral) {
        let chunks = Self.chunkData(data)
        for chunk in chunks {
            peripheral.writeValue(chunk, for: characteristic, type: .withResponse)
        }
    }

    /// Notify chunked data on a characteristic (peripheral → central).
    private func notifyChunked(data: Data, on characteristic: CBMutableCharacteristic, via pm: CBPeripheralManager) {
        let chunks = Self.chunkData(data)
        for chunk in chunks {
            pm.updateValue(chunk, for: characteristic, onSubscribedCentrals: nil)
        }
    }

    /// Split data into BLE-safe chunks with first/last flags.
    /// Format per chunk: [1B flags][payload ≤480B]
    static func chunkData(_ data: Data) -> [Data] {
        var chunks: [Data] = []
        let totalSize = data.count
        var offset = 0

        while offset < totalSize {
            let end = min(offset + maxChunkPayload, totalSize)
            var flags: UInt8 = 0
            if offset == 0 { flags |= flagFirst }
            if end == totalSize { flags |= flagLast }

            var chunk = Data([flags])
            chunk.append(data[offset..<end])
            chunks.append(chunk)
            offset = end
        }

        // Empty data edge case
        if chunks.isEmpty {
            chunks.append(Data([flagFirst | flagLast]))
        }

        return chunks
    }

    /// Process a received chunk and return reassembled data if complete.
    func processChunk(_ data: Data, for characteristicUUID: CBUUID) -> Data? {
        guard !data.isEmpty else { return nil }
        let flags = data[0]
        let payload = data.count > 1 ? data[1...] : Data()

        let isFirst = (flags & Self.flagFirst) != 0
        let isLast = (flags & Self.flagLast) != 0

        if isFirst {
            receiveBuffers[characteristicUUID] = Data(payload)
        } else {
            receiveBuffers[characteristicUUID]?.append(contentsOf: payload)
        }

        if isLast {
            let assembled = receiveBuffers.removeValue(forKey: characteristicUUID)
            return assembled
        }

        return nil
    }

    // MARK: - Peripheral Delegate Handling

    /// Called by BLEDiscovery when a write request is received on signaling characteristics.
    func handleWriteRequest(characteristicUUID: CBUUID, value: Data) {
        if characteristicUUID == Self.controlUUID {
            // Control messages are short, no chunking
            if let message = String(data: value, encoding: .utf8) {
                if message.hasPrefix("relay-request:") {
                    let peerID = String(message.dropFirst("relay-request:".count))
                    onRelayRequest?(peerID)
                } else if message == "relay-accept" {
                    onRelayAccept?()
                } else if message == "relay-reject" {
                    onRelayReject?()
                }
            }
            return
        }

        guard let assembled = processChunk(value, for: characteristicUUID) else { return }

        guard let text = String(data: assembled, encoding: .utf8) else {
            logger.warning("Failed to decode assembled data as UTF-8")
            return
        }

        switch characteristicUUID {
        case Self.sdpOfferUUID:
            onSDPOffer?(text)
        case Self.sdpAnswerUUID:
            onSDPAnswer?(text)
        case Self.iceCandidateUUID:
            onICECandidate?(text)
        default:
            break
        }
    }

    func disconnect() {
        if let peripheral = connectedPeripheral {
            centralManager?.cancelPeripheralConnection(peripheral)
        }
        connectedPeripheral = nil
        receiveBuffers.removeAll()
    }
}

// MARK: - CBPeripheralDelegate

extension BLESignaling: CBPeripheralDelegate {
    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard let services = peripheral.services else { return }
        for service in services {
            if service.uuid == BLEDiscovery.serviceUUID {
                peripheral.discoverCharacteristics([
                    Self.sdpOfferUUID, Self.sdpAnswerUUID,
                    Self.iceCandidateUUID, Self.controlUUID
                ], for: service)
            }
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        guard let characteristics = service.characteristics else { return }
        for char in characteristics {
            switch char.uuid {
            case Self.sdpOfferUUID:
                remoteSdpOfferChar = char
                peripheral.setNotifyValue(true, for: char)
            case Self.sdpAnswerUUID:
                remoteSdpAnswerChar = char
                peripheral.setNotifyValue(true, for: char)
            case Self.iceCandidateUUID:
                remoteICECandidateChar = char
                peripheral.setNotifyValue(true, for: char)
            case Self.controlUUID:
                remoteControlChar = char
                peripheral.setNotifyValue(true, for: char)
            default:
                break
            }
        }
        logger.info("Discovered signaling characteristics")
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        guard let value = characteristic.value else { return }
        handleWriteRequest(characteristicUUID: characteristic.uuid, value: value)
    }
}
