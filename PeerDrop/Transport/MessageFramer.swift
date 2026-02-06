import Foundation
import Network

/// Length-prefixed message framer using NWProtocolFramer.
/// Wire format: [4-byte big-endian length][JSON payload]
final class PeerDropFramer: NWProtocolFramerImplementation {
    static let label = "PeerDrop"
    /// Maximum allowed message size (100 MB).
    static let maxMessageSize: UInt32 = 100 * 1024 * 1024

    static let definition = NWProtocolFramer.Definition(implementation: PeerDropFramer.self)

    required init(framer: NWProtocolFramer.Instance) {}

    func start(framer: NWProtocolFramer.Instance) -> NWProtocolFramer.StartResult {
        .ready
    }

    func stop(framer: NWProtocolFramer.Instance) -> Bool {
        true
    }

    func wakeup(framer: NWProtocolFramer.Instance) {}

    func cleanup(framer: NWProtocolFramer.Instance) {}

    func handleInput(framer: NWProtocolFramer.Instance) -> Int {
        while true {
            var tempHeader = Data()
            let headerParsed = framer.parseInput(minimumIncompleteLength: 4, maximumLength: 4) { buffer, isComplete in
                guard let buffer, buffer.count >= 4 else {
                    return 0
                }
                tempHeader = Data(buffer)
                return 4
            }

            guard headerParsed, tempHeader.count == 4 else {
                return 4
            }

            let length = tempHeader.withUnsafeBytes { bytes in
                bytes.load(as: UInt32.self).bigEndian
            }

            guard length > 0, length <= Self.maxMessageSize else {
                print("[PeerDropFramer] Rejecting message with invalid size: \(length) bytes")
                return 0
            }

            let message = NWProtocolFramer.Message(peerDropMessageLength: length)

            guard framer.deliverInputNoCopy(length: Int(length), message: message, isComplete: true) else {
                return 0
            }
        }
    }

    func handleOutput(
        framer: NWProtocolFramer.Instance,
        message: NWProtocolFramer.Message,
        messageLength: Int,
        isComplete: Bool
    ) {
        var header = UInt32(messageLength).bigEndian
        framer.writeOutput(data: Data(bytes: &header, count: 4))
        do {
            try framer.writeOutputNoCopy(length: messageLength)
        } catch {
            // Frame write failed — connection will error
        }
    }
}

// MARK: - Message metadata

extension NWProtocolFramer.Message {
    convenience init(peerDropMessageLength: UInt32) {
        self.init(definition: PeerDropFramer.definition)
        self["MessageLength"] = peerDropMessageLength
    }

    var peerDropMessageLength: UInt32 {
        (self["MessageLength"] as? UInt32) ?? 0
    }
}

// MARK: - NWParameters helper

extension NWParameters {
    static func peerDrop(tls: NWProtocolTLS.Options? = nil) -> NWParameters {
        let params: NWParameters
        if let tls {
            params = NWParameters(tls: tls)
        } else {
            params = NWParameters(tls: nil)
        }

        // Enable TCP keepalive to prevent idle timeout
        if let tcpOptions = params.defaultProtocolStack.transportProtocol as? NWProtocolTCP.Options {
            tcpOptions.enableKeepalive = true
            tcpOptions.keepaliveIdle = 10 // Start keepalive after 10 seconds idle
            tcpOptions.keepaliveInterval = 10 // Send keepalive every 10 seconds
            tcpOptions.keepaliveCount = 3 // Give up after 3 failed keepalives
        }

        let framerOptions = NWProtocolFramer.Options(definition: PeerDropFramer.definition)
        params.defaultProtocolStack.applicationProtocols.insert(framerOptions, at: 0)
        return params
    }
}
