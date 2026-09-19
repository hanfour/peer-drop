import Foundation

/// One-shot X3DH envelope for a passing note (spec §2.1). `ephemeralKey`
/// plays the initiator's *identity* key in X3DH and `ephemeralKey2` the
/// ephemeral one, so the recipient never needs to know who sent it —
/// anonymous and signed notes decrypt through the same path.
public struct NoteEnvelope: Codable, Equatable, Sendable {
    public static let currentVersion: UInt8 = 1

    public var v: UInt8
    public var ephemeralKey: Data      // EK_A (32 B)
    public var ephemeralKey2: Data     // EK_A2 (32 B)
    public var spkId: UInt32
    public var opkId: UInt32?
    public var nonce: Data             // 12 B AES-GCM nonce
    public var ciphertext: Data        // AES-GCM ciphertext ‖ 16 B tag

    public init(v: UInt8, ephemeralKey: Data, ephemeralKey2: Data, spkId: UInt32, opkId: UInt32?, nonce: Data, ciphertext: Data) {
        self.v = v; self.ephemeralKey = ephemeralKey; self.ephemeralKey2 = ephemeralKey2
        self.spkId = spkId; self.opkId = opkId; self.nonce = nonce; self.ciphertext = ciphertext
    }

    /// Canonical bytes sent to the worker (base64'd) and hashed into the
    /// proof of work: sorted-key JSON, Data as base64. Optional `opkId` is
    /// omitted when nil (the worker's `parseEnvelope` accepts both).
    public func wireBytes() throws -> Data {
        let enc = JSONEncoder()
        enc.outputFormatting = [.sortedKeys]
        return try enc.encode(self)
    }

    public static func fromWire(_ data: Data) throws -> NoteEnvelope {
        try JSONDecoder().decode(NoteEnvelope.self, from: data)
    }
}
